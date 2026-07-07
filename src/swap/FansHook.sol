// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from
    "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeDistributor} from "../interfaces/IFansInterfaces.sol";

/// @title FansHook
/// @notice Uniswap v4 hook for the canonical $FANS/ETH pool. Charges a configurable per-swap fee
///         (default 1.5% = 150 bps), always denominated in **$FANS** (currency1), captured with
///         `poolManager.take`, and forwarded per-swap into {FeeDistributor} which drips the farmer
///         share into {StakingManager}. Non-upgradeable: the implementation itself is CREATE2-mined
///         to an address whose low bits encode `getHookPermissions` (see DeployFansV4 / the test).
///
/// @dev Canonical pool shape (enforced in `_beforeInitialize`):
///        currency0 = address(0) (native ETH), currency1 = $FANS, fee = 0, hooks = this.
///      Pool `fee` is 0 — the protocol fee is entirely this hook's `feeBps`.
///
///      Fee currency choice: the fee is ALWAYS taken in $FANS so it can be forwarded straight into
///      the $FANS reward drip without an on-chain ETH->FANS conversion. $FANS is the swap's
///      "specified" currency for exact-in sells and exact-out buys (captured in `_beforeSwap` via
///      `beforeSwapReturnDelta`), and the "unspecified" currency for exact-in buys and exact-out
///      sells (captured in `_afterSwap` via `afterSwapReturnDelta`).
///
///      Fee forwarding: PER-SWAP. Every taxed swap immediately transfers the captured $FANS to the
///      FeeDistributor and calls `distribute` (which routes treasury share + notifies the staking
///      drip). Simple and deterministic; a threshold/batch variant is a later optimisation.
///
///      Phase-2 note (LP vault): this hook is stateless w.r.t. liquidity ownership — it neither
///      mints nor holds the position. An ERC-20 LP vault (FansLPVault) can own and manage the
///      single full-range position over this pool without any hook change; the hook only taxes
///      swaps and routes fees.
contract FansHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Basis-points denominator (100% = 10_000).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap on the configurable fee (10%). Guards `setFeeBps`.
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// @notice The $FANS token (pool currency1). Fees are always charged in this token.
    address public immutable fans;

    /// @notice Only this address may initialize a pool that uses this hook (anti-foreign-pool guard).
    address public authorizedInitializer;

    /// @notice Per-swap fee in basis points (default 150 = 1.5%).
    uint256 public feeBps;

    /// @notice Sink that receives captured $FANS fees and drips them to the staking farm.
    IFeeDistributor public feeDistributor;

    /// @notice Pool this hook was initialized for (set once, in `_beforeInitialize`).
    PoolId public poolId;
    bool public initialized;

    /// @notice Lifetime total $FANS captured and forwarded (handy for accounting/tests).
    uint256 public totalFeesForwarded;

    event FeeCharged(PoolId indexed poolId, uint256 amount, bool inBeforeSwap);
    event FeeBpsUpdated(uint256 feeBps);
    event FeeDistributorUpdated(address feeDistributor);
    event AuthorizedInitializerUpdated(address initializer);

    error NotAuthorizedInitializer();
    error UnexpectedPoolKey();
    error FeeTooHigh();
    error ZeroAddress();

    /// @param _poolManager  Uniswap v4 PoolManager.
    /// @param _owner        Owner (config + admin).
    /// @param _fans         $FANS token address (must equal pool currency1).
    /// @param _feeDistributor $FANS fee sink (FeeDistributor).
    /// @param _feeBps       Initial per-swap fee (bps); pass 150 for 1.5%.
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _fans,
        IFeeDistributor _feeDistributor,
        uint256 _feeBps
    ) BaseHook(_poolManager) Ownable(_owner) {
        if (_fans == address(0) || address(_feeDistributor) == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        fans = _fans;
        feeDistributor = _feeDistributor;
        feeBps = _feeBps;
        authorizedInitializer = _owner;
    }

    // ─── Hook permissions ──────────────────────────────────────────────────────

    /// @inheritdoc BaseHook
    /// @dev flags = beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Init guard ────────────────────────────────────────────────────────────

    /// @notice Reject pools not created by our authorized deployer, and enforce the canonical shape.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != authorizedInitializer) revert NotAuthorizedInitializer();
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != fans || key.fee != 0
                || address(key.hooks) != address(this)
        ) revert UnexpectedPoolKey();

        poolId = key.toId();
        initialized = true;
        return IHooks.beforeInitialize.selector;
    }

    // ─── Swap fee capture ───────────────────────────────────────────────────────

    /// @dev $FANS (currency1) is the swap's *specified* currency for exact-in sells and exact-out
    ///      buys. In those cases we take the fee here, on the known specified amount.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        bool fansIsSpecified = (exactIn == !params.zeroForOne);
        if (!fansIsSpecified || feeBps == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 specified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = (specified * feeBps) / BPS_DENOMINATOR;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Take the fee in $FANS (currency1) from the PoolManager; the returned positive specified
        // delta reconciles the swap accounting (the swapper covers the fee out of the specified amount).
        poolManager.take(key.currency1, address(this), fee);
        _forward(key.toId(), fee, true);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), int128(0)), 0);
    }

    /// @dev $FANS (currency1) is the swap's *unspecified* currency for exact-in buys and exact-out
    ///      sells. In those cases the $FANS amount is only known after the swap, so we take here.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool exactIn = params.amountSpecified < 0;
        bool fansIsSpecified = (exactIn == !params.zeroForOne);
        if (fansIsSpecified || feeBps == 0) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        int128 fansDelta = delta.amount1(); // currency1 == $FANS
        uint256 fansAmount = fansDelta >= 0 ? uint256(uint128(fansDelta)) : uint256(uint128(-fansDelta));
        uint256 fee = (fansAmount * feeBps) / BPS_DENOMINATOR;
        if (fee == 0) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        poolManager.take(key.currency1, address(this), fee);
        _forward(key.toId(), fee, false);

        // Positive unspecified delta: the hook is owed `fee` of $FANS (the unspecified currency).
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    // ─── Internals ───────────────────────────────────────────────────────────────

    /// @notice Forward captured $FANS into the FeeDistributor (per-swap) and start/extend the drip.
    function _forward(PoolId id, uint256 fee, bool inBeforeSwap) internal {
        totalFeesForwarded += fee;
        IERC20(fans).safeTransfer(address(feeDistributor), fee);
        feeDistributor.distribute(fee);
        emit FeeCharged(id, fee, inBeforeSwap);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────────

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = _feeBps;
        emit FeeBpsUpdated(_feeBps);
    }

    function setFeeDistributor(IFeeDistributor _feeDistributor) external onlyOwner {
        if (address(_feeDistributor) == address(0)) revert ZeroAddress();
        feeDistributor = _feeDistributor;
        emit FeeDistributorUpdated(address(_feeDistributor));
    }

    function setAuthorizedInitializer(address _initializer) external onlyOwner {
        authorizedInitializer = _initializer;
        emit AuthorizedInitializerUpdated(_initializer);
    }
}
