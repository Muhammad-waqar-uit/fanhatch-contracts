// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FansLPVault
/// @notice ERC-20 wrapper ("Fans LP" / FANS-LP) around a single **full-range** Uniswap v4 liquidity
///         position in the canonical Phase-1 $FANS/ETH pool (currency0 = native ETH, currency1 =
///         $FANS, fee 0, {FansHook}). The vault is the SOLE owner of that position; retail users
///         deposit ETH + $FANS, receive fungible FANS-LP shares, and can then stake those shares in
///         the LP {StakingManager} to earn the farm drip (see docs/03-lp/lp-spec.md).
///
/// @dev Because the pool `fee` is 0 and {FansHook} diverts every trade fee to the farm, this
///      position accrues **no** in-range LP fees — LPs earn purely via staking FANS-LP. The position
///      therefore only ever grows/shrinks by principal, so `positionLiquidity` (tracked here) equals
///      the pool's stored liquidity for our range at all times.
///
///      Share math (proportional to liquidity, ERC-4626-style over `L` rather than assets):
///        - first deposit:  shares = L                       (and positionLiquidity = L)
///        - later deposits: shares = L * totalSupply() / positionLiquidity   (pre-add liquidity)
///      Since no fees accrue to the position, totalSupply() == positionLiquidity holds for the life
///      of the vault, but the general formula is used so the vault stays correct even if that ever
///      changed.
///
///      v4 settlement: liquidity is added/removed inside `poolManager.unlock` -> `unlockCallback` ->
///      `poolManager.modifyLiquidity`. On deposit the returned `callerDelta` is negative (the vault
///      owes ETH + $FANS) and is paid via settle; on withdraw it is positive (the pool owes the
///      vault) and is pulled via take. Deposit dust (unused ETH/$FANS) is refunded to the depositor.
contract FansLPVault is ERC20, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IERC20 public immutable fans;
    Currency internal immutable currency0; // native ETH (address(0))
    Currency internal immutable currency1; // $FANS

    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    /// @notice Cached pool key (single full-range position).
    PoolKey internal poolKey;
    PoolId public immutable poolId;

    /// @notice Total liquidity of the vault's single position (source of truth for share math).
    uint128 public positionLiquidity;

    struct CallbackData {
        bool isDeposit;
        int256 liquidityDelta; // +L on deposit, -L on withdraw
    }

    event Deposit(address indexed user, uint256 ethIn, uint256 fansIn, uint128 liquidity, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint128 liquidity, uint256 ethOut, uint256 fansOut);

    error ZeroLiquidity();
    error ZeroShares();
    error OnlyPoolManager();
    error EthRefundFailed();
    error NotEthPool();

    /// @param _poolManager Uniswap v4 PoolManager.
    /// @param _poolKey     The initialized $FANS/ETH pool key (currency0 = ETH, currency1 = $FANS).
    constructor(IPoolManager _poolManager, PoolKey memory _poolKey) ERC20("Fans LP", "FANS-LP") {
        if (Currency.unwrap(_poolKey.currency0) != address(0)) revert NotEthPool();
        poolManager = _poolManager;
        poolKey = _poolKey;
        currency0 = _poolKey.currency0;
        currency1 = _poolKey.currency1;
        fans = IERC20(Currency.unwrap(_poolKey.currency1));
        poolId = _poolKey.toId();
        tickLower = TickMath.minUsableTick(_poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(_poolKey.tickSpacing);
    }

    // ─── Deposit / Withdraw ──────────────────────────────────────────────────────

    /// @notice Deposit ETH (`msg.value`) + $FANS (`fansIn`, pulled via transferFrom — approve first)
    ///         into the full-range position and mint FANS-LP shares. Unused dust is refunded.
    /// @param fansIn Amount of $FANS to deposit (caller must approve this vault).
    /// @return shares FANS-LP minted to the caller.
    function deposit(uint256 fansIn) external payable nonReentrant returns (uint256 shares) {
        // Pull the caller's $FANS; ETH arrives via msg.value.
        if (fansIn > 0) fans.safeTransferFrom(msg.sender, address(this), fansIn);

        uint128 liquidity = _liquidityForAmounts(msg.value, fansIn);
        if (liquidity == 0) revert ZeroLiquidity();

        uint256 supply = totalSupply();
        uint128 liqBefore = positionLiquidity;

        // Add liquidity + settle owed ETH/$FANS inside the unlock callback.
        poolManager.unlock(abi.encode(CallbackData({isDeposit: true, liquidityDelta: int256(uint256(liquidity))})));
        positionLiquidity = liqBefore + liquidity;

        // First deposit: shares == L. Later: proportional to pre-add liquidity.
        shares = supply == 0 ? uint256(liquidity) : (uint256(liquidity) * supply) / liqBefore;
        if (shares == 0) revert ZeroShares();
        _mint(msg.sender, shares);

        // Refund unused dust (both legs) to the depositor.
        _refundDust(msg.sender);

        emit Deposit(msg.sender, msg.value, fansIn, liquidity, shares);
    }

    /// @notice Burn FANS-LP shares and withdraw the proportional ETH + $FANS from the position.
    /// @param shares FANS-LP to burn.
    /// @return ethOut ETH returned to the caller.
    /// @return fansOut $FANS returned to the caller.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 ethOut, uint256 fansOut) {
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();

        uint128 liqRemove = uint128((uint256(positionLiquidity) * shares) / supply);
        if (liqRemove == 0) revert ZeroLiquidity();

        _burn(msg.sender, shares);
        positionLiquidity -= liqRemove;

        bytes memory res = poolManager.unlock(
            abi.encode(CallbackData({isDeposit: false, liquidityDelta: -int256(uint256(liqRemove))}))
        );
        (ethOut, fansOut) = abi.decode(res, (uint256, uint256));

        if (ethOut > 0) {
            (bool ok,) = msg.sender.call{value: ethOut}("");
            if (!ok) revert EthRefundFailed();
        }
        if (fansOut > 0) fans.safeTransfer(msg.sender, fansOut);

        emit Withdraw(msg.sender, shares, liqRemove, ethOut, fansOut);
    }

    // ─── PoolManager callback ────────────────────────────────────────────────────

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: d.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();

        if (d.isDeposit) {
            // Negative delta => the vault owes the pool; pay it.
            if (d0 < 0) _settle(currency0, uint256(uint128(-d0)));
            if (d1 < 0) _settle(currency1, uint256(uint128(-d1)));
            return "";
        }

        // Withdraw: positive delta => the pool owes the vault; pull it to the vault.
        uint256 ethOut = d0 > 0 ? uint256(uint128(d0)) : 0;
        uint256 fansOut = d1 > 0 ? uint256(uint128(d1)) : 0;
        if (ethOut > 0) poolManager.take(currency0, address(this), ethOut);
        if (fansOut > 0) poolManager.take(currency1, address(this), fansOut);
        return abi.encode(ethOut, fansOut);
    }

    // ─── Views ───────────────────────────────────────────────────────────────────

    /// @notice Current pool sqrt price (Q64.96).
    function sqrtPriceX96() public view returns (uint160 sqrtP) {
        (sqrtP,,,) = poolManager.getSlot0(poolId);
    }

    /// @notice The ETH + $FANS currently backing the vault's position at the current price.
    function getReserves() external view returns (uint256 ethReserve, uint256 fansReserve) {
        return _amountsForLiquidity(positionLiquidity);
    }

    /// @notice Estimate FANS-LP shares minted for a given ETH + $FANS deposit at the current price.
    function previewDeposit(uint256 ethIn, uint256 fansIn) external view returns (uint256 shares) {
        uint128 liquidity = _liquidityForAmounts(ethIn, fansIn);
        if (liquidity == 0) return 0;
        uint256 supply = totalSupply();
        return supply == 0 ? uint256(liquidity) : (uint256(liquidity) * supply) / positionLiquidity;
    }

    /// @notice The vault's pool key.
    function getPoolKey() external view returns (PoolKey memory) {
        return poolKey;
    }

    // ─── Internals ───────────────────────────────────────────────────────────────

    function _liquidityForAmounts(uint256 ethIn, uint256 fansIn) internal view returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96(),
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethIn,
            fansIn
        );
    }

    function _amountsForLiquidity(uint128 liquidity) internal view returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtP = sqrtPriceX96();
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        // Full range with an active pool => current price is strictly between the bounds.
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    /// @dev Pay `amount` of `currency` to the PoolManager (settle). ETH is paid with value.
    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        if (Currency.unwrap(currency) == address(0)) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @dev Refund leftover ETH + $FANS held by the vault after a deposit's settlement.
    function _refundDust(address to) internal {
        uint256 ethLeft = address(this).balance;
        if (ethLeft > 0) {
            (bool ok,) = to.call{value: ethLeft}("");
            if (!ok) revert EthRefundFailed();
        }
        uint256 fansLeft = fans.balanceOf(address(this));
        if (fansLeft > 0) fans.safeTransfer(to, fansLeft);
    }

    /// @notice Accept ETH from the PoolManager (`take`) and depositors.
    receive() external payable {}
}
