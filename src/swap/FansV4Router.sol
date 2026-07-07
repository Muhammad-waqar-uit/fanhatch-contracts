// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FansV4Router
/// @notice Thin single-pool router for the canonical $FANS/ETH v4 pool (currency0 = ETH,
///         currency1 = $FANS), for the frontend and tests. Exact-input only, both directions.
///         Swaps go through `poolManager.unlock` -> `unlockCallback` -> `poolManager.swap` ->
///         settle input / take output. The {FansHook} on the pool captures the fee (in $FANS)
///         transparently to this router — the router settles exactly the swapper's delta.
/// @dev Modeled on mvmnt-memecoin-launchpad-contracts/src/MemeTradeRouter.sol (swap path only).
contract FansV4Router is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public immutable fans;

    // Cached pool key (single pool).
    PoolKey internal poolKey;

    struct SwapData {
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
        address recipient;
    }

    error ZeroAmount();
    error OnlyPoolManager();
    error SlippageExceeded(uint256 received, uint256 minimum);
    error EthTransferFailed();

    event Swapped(address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, address recipient);

    constructor(IPoolManager _poolManager, PoolKey memory _poolKey) {
        poolManager = _poolManager;
        poolKey = _poolKey;
        fans = Currency.unwrap(_poolKey.currency1);
    }

    /// @notice Returns the cached pool key.
    function getPoolKey() external view returns (PoolKey memory) {
        return poolKey;
    }

    // ─── Swaps (exact-in) ──────────────────────────────────────────────────────

    /// @notice Swap an exact amount of ETH (msg.value) for $FANS.
    /// @param minOut Minimum $FANS out (slippage guard).
    /// @return amountOut $FANS received by msg.sender.
    function swapExactEthForFans(uint256 minOut) external payable nonReentrant returns (uint256 amountOut) {
        if (msg.value == 0) revert ZeroAmount();
        bytes memory res = poolManager.unlock(
            abi.encode(SwapData({zeroForOne: true, amountIn: msg.value, minOut: minOut, recipient: msg.sender}))
        );
        amountOut = abi.decode(res, (uint256));
        emit Swapped(msg.sender, true, msg.value, amountOut, msg.sender);
    }

    /// @notice Swap an exact amount of $FANS for ETH.
    /// @param amountIn $FANS to sell (pulled from msg.sender; approve this router first).
    /// @param minOut Minimum ETH out (slippage guard).
    /// @return amountOut ETH received by msg.sender.
    function swapExactFansForEth(uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        IERC20(fans).safeTransferFrom(msg.sender, address(this), amountIn);
        bytes memory res = poolManager.unlock(
            abi.encode(SwapData({zeroForOne: false, amountIn: amountIn, minOut: minOut, recipient: msg.sender}))
        );
        amountOut = abi.decode(res, (uint256));
        emit Swapped(msg.sender, false, amountIn, amountOut, msg.sender);
    }

    // ─── PoolManager callback ────────────────────────────────────────────────────

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        SwapData memory d = abi.decode(raw, (SwapData));

        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.amountIn),
                sqrtPriceLimitX96: d.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        (Currency inC, Currency outC) =
            d.zeroForOne ? (poolKey.currency0, poolKey.currency1) : (poolKey.currency1, poolKey.currency0);
        int128 inDelta = d.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = d.zeroForOne ? delta.amount1() : delta.amount0();

        // Pay what we owe (the full input, including any hook fee taken out of it).
        _settle(inC, uint256(uint128(-inDelta)));

        uint256 outAmount = uint256(uint128(outDelta));
        if (outAmount < d.minOut) revert SlippageExceeded(outAmount, d.minOut);

        // Send output straight to the recipient.
        poolManager.take(outC, d.recipient, outAmount);

        return abi.encode(outAmount);
    }

    // ─── Internals ────────────────────────────────────────────────────────────────

    function _settle(Currency currency, uint256 amount) internal {
        if (Currency.unwrap(currency) == address(0)) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    receive() external payable {}
}
