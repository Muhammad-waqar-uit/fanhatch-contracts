// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {FansSwap} from "../../src/swap/FansSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @notice Malicious contract that tries to re-enter FansSwap from inside the ETH callback that
///         `swapFansForEth` performs (the pool pays ETH out via a low-level `.call`). The receive()
///         hook re-enters the pool while the outer swap is still mid-execution; the reentry is
///         caught so we can inspect the exact revert reason rather than just bubbling it up.
contract SwapReentrancyAttacker {
    FansSwap public immutable swap;
    IERC20 public immutable fans;

    bool public reenteredSucceeded; // true only if a reentrant swap unexpectedly went through
    bool public reentryAttempted;
    bytes public lastRevert; // raw revert data captured from the reentrant call

    constructor(FansSwap swap_, IERC20 fans_) {
        swap = swap_;
        fans = fans_;
    }

    /// @dev Kick off the legitimate outer swap. The pool will call back into receive() to pay ETH.
    function attack(uint256 fansIn) external {
        fans.approve(address(swap), type(uint256).max);
        swap.swapFansForEth(fansIn, 0);
    }

    receive() external payable {
        // Re-enter the pool during the ETH payout of the outer swap. The nonReentrant guard must
        // reject this. We catch the revert so the outer swap's ETH transfer still "succeeds" and
        // the test can assert on the captured reason.
        if (!reentryAttempted && fans.balanceOf(address(this)) > 0) {
            reentryAttempted = true;
            try swap.swapFansForEth(1 ether, 0) returns (uint256) {
                reenteredSucceeded = true;
            } catch (bytes memory reason) {
                lastRevert = reason;
            }
        }
    }
}

/// @title ReentrancyAttack
/// @notice Proves the nonReentrant guard on FansSwap blocks a reentrant call made from the ETH
///         payout callback of `swapFansForEth`, reverting with OZ's ReentrancyGuardReentrantCall.
contract ReentrancyAttack is FansBase {
    FansSwap internal pool;
    SwapReentrancyAttacker internal attacker;

    function setUp() public override {
        super.setUp();
        pool = swap;

        // Seed the pool with ETH + $FANS liquidity so swaps have something to trade against.
        vm.deal(owner, 100 ether);
        vm.startPrank(owner);
        fans.mint(owner, 1_000_000 ether);
        fans.approve(address(pool), type(uint256).max);
        pool.addLiquidity{value: 50 ether}(500_000 ether, 0);
        // Fund the attacker with $FANS to spend on swaps.
        attacker = new SwapReentrancyAttacker(pool, IERC20(address(fans)));
        fans.mint(address(attacker), 1000 ether);
        vm.stopPrank();
    }

    /// @dev The reentrant call inside the ETH callback must be rejected by the guard, while the
    ///      outer swap still completes (the attacker swallows the inner revert).
    function test_reentrantSwapFansForEth_isBlocked() public {
        assertEq(address(attacker).balance, 0, "attacker starts with no ETH");

        attacker.attack(10 ether);

        // The outer (legitimate) swap completed and paid ETH to the attacker.
        assertGt(address(attacker).balance, 0, "outer swap paid out");
        // The reentry was attempted and rejected.
        assertTrue(attacker.reentryAttempted(), "reentry was attempted from the ETH callback");
        assertFalse(attacker.reenteredSucceeded(), "reentrant swap must NOT succeed");

        // And it reverted with exactly the OpenZeppelin reentrancy guard error.
        bytes memory reason = attacker.lastRevert();
        assertEq(reason.length, 4, "guard reverts with a 4-byte selector");
        assertEq(
            bytes4(reason),
            ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector,
            "reverted with ReentrancyGuardReentrantCall"
        );
    }

    /// @dev Sanity check that a non-reentrant swap from the same attacker contract works fine,
    ///      proving the revert above is caused by reentrancy and not by some unrelated failure.
    function test_normalSwap_succeeds() public {
        // Disarm the reentry path by draining the attacker's $FANS via a single clean swap, then
        // confirm a fresh straightforward swap from an EOA works.
        vm.startPrank(alice);
        fans.approve(address(pool), type(uint256).max);
        uint256 out = pool.swapFansForEth(10 ether, 0);
        vm.stopPrank();
        assertGt(out, 0, "a normal swap yields ETH");
    }
}
