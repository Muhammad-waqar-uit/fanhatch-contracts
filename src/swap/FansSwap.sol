// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FansSwap
/// @notice Minimal constant-product (x·y=k) AMM for ETH ↔ $FANS with ERC-20 LP tokens (spec §1.8 / §2.5).
/// @dev Custom AMM option from the spec — avoids pulling the full Uniswap v4 stack.
///      LP positions are tokenized ("FANS-LP") so they can be staked in a StakingManager LP farm
///      (figma "Your LP ... rewards claimable as $FANS"). LPs also earn the 0.3% swap fee via reserve growth.
///      ponytail: single-pool x*y=k. Swap to a Uniswap v3/v4 pool if you need concentrated
///                liquidity, routing, or external price feeds.
contract FansSwap is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public fans;
    uint256 public reserveEth;
    uint256 public reserveFans;

    uint256 private constant FEE_BPS = 30; // 0.3% swap fee

    event LiquidityAdded(address indexed provider, uint256 ethIn, uint256 fansIn, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 ethOut, uint256 fansOut, uint256 shares);
    event Swapped(address indexed user, bool ethToFans, uint256 amountIn, uint256 amountOut);

    error ZeroAmount();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error InsufficientShares();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 fans_) external initializer {
        __ERC20_init("FansSwap LP", "FANS-LP");
        __ReentrancyGuard_init();
        fans = fans_;
    }

    /// @notice Provide ETH + $FANS liquidity, minting LP tokens. First provider sets the price.
    function addLiquidity(uint256 fansIn, uint256 minShares) external payable nonReentrant returns (uint256 shares) {
        if (msg.value == 0 || fansIn == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        if (supply == 0) {
            shares = _sqrt(msg.value * fansIn);
        } else {
            // Keep the ratio; mint shares proportional to the ETH contributed.
            shares = (msg.value * supply) / reserveEth;
            uint256 required = (msg.value * reserveFans) / reserveEth;
            if (fansIn < required) revert SlippageExceeded();
            fansIn = required; // only pull what's needed to preserve the ratio
        }
        if (shares < minShares || shares == 0) revert SlippageExceeded();

        fans.safeTransferFrom(msg.sender, address(this), fansIn);
        reserveEth += msg.value;
        reserveFans += fansIn;
        _mint(msg.sender, shares);
        emit LiquidityAdded(msg.sender, msg.value, fansIn, shares);
    }

    /// @notice Burn LP tokens to withdraw the underlying ETH + $FANS pro-rata.
    function removeLiquidity(uint256 shares, uint256 minEth, uint256 minFans)
        external
        nonReentrant
        returns (uint256 ethOut, uint256 fansOut)
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        uint256 supply = totalSupply();
        ethOut = (shares * reserveEth) / supply;
        fansOut = (shares * reserveFans) / supply;
        if (ethOut < minEth || fansOut < minFans) revert SlippageExceeded();

        _burn(msg.sender, shares);
        reserveEth -= ethOut;
        reserveFans -= fansOut;

        fans.safeTransfer(msg.sender, fansOut);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "ETH transfer failed");
        emit LiquidityRemoved(msg.sender, ethOut, fansOut, shares);
    }

    /// @notice Swap ETH for $FANS.
    function swapEthForFans(uint256 minFansOut) external payable nonReentrant returns (uint256 fansOut) {
        if (msg.value == 0) revert ZeroAmount();
        if (reserveEth == 0 || reserveFans == 0) revert InsufficientLiquidity();
        fansOut = _amountOut(msg.value, reserveEth, reserveFans);
        if (fansOut < minFansOut) revert SlippageExceeded();
        reserveEth += msg.value;
        reserveFans -= fansOut;
        fans.safeTransfer(msg.sender, fansOut);
        emit Swapped(msg.sender, true, msg.value, fansOut);
    }

    /// @notice Swap $FANS for ETH.
    function swapFansForEth(uint256 fansIn, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        if (fansIn == 0) revert ZeroAmount();
        if (reserveEth == 0 || reserveFans == 0) revert InsufficientLiquidity();
        ethOut = _amountOut(fansIn, reserveFans, reserveEth);
        if (ethOut < minEthOut) revert SlippageExceeded();
        fans.safeTransferFrom(msg.sender, address(this), fansIn);
        reserveFans += fansIn;
        reserveEth -= ethOut;
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "ETH transfer failed");
        emit Swapped(msg.sender, false, fansIn, ethOut);
    }

    /// @notice View: output amount for a given input, after the 0.3% fee.
    function getAmountOut(uint256 amountIn, bool ethToFans) external view returns (uint256) {
        return ethToFans ? _amountOut(amountIn, reserveEth, reserveFans) : _amountOut(amountIn, reserveFans, reserveEth);
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) private pure returns (uint256) {
        uint256 amountInWithFee = amountIn * (10_000 - FEE_BPS);
        return (amountInWithFee * reserveOut) / (reserveIn * 10_000 + amountInWithFee);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
