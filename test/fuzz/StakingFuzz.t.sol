// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";

/// @title StakingFuzz
/// @notice Property tests for the $FANS farm (`stakingFans`):
///         - sum of balances always equals totalStaked across stake/withdraw,
///         - earned rewards never exceed the total notified amount.
contract StakingFuzz is FansBase {
    uint256 internal duration;

    function setUp() public override {
        super.setUp();
        duration = stakingFans.rewardsDuration();
        vm.prank(alice);
        fans.approve(address(stakingFans), type(uint256).max);
        vm.prank(bob);
        fans.approve(address(stakingFans), type(uint256).max);
    }

    /// @dev Invariant: balanceOf(alice) + balanceOf(bob) == totalStaked, preserved by
    ///      stakes and a partial withdraw.
    function testFuzz_BalancesSumToTotalStaked(uint256 aStake, uint256 bStake, uint256 aWithdraw) public {
        aStake = bound(aStake, 1, SEED);
        bStake = bound(bStake, 1, SEED);

        vm.prank(alice);
        stakingFans.stake(aStake);
        vm.prank(bob);
        stakingFans.stake(bStake);

        assertEq(stakingFans.balanceOf(alice) + stakingFans.balanceOf(bob), stakingFans.totalStaked(), "sum == total");

        // Withdraw a bounded portion of alice's stake.
        aWithdraw = bound(aWithdraw, 1, aStake);
        vm.prank(alice);
        stakingFans.withdraw(aWithdraw);

        assertEq(
            stakingFans.balanceOf(alice) + stakingFans.balanceOf(bob),
            stakingFans.totalStaked(),
            "sum == total after withdraw"
        );
        assertEq(stakingFans.balanceOf(alice), aStake - aWithdraw, "alice balance");
        assertEq(stakingFans.balanceOf(bob), bStake, "bob balance");
    }

    /// @dev Invariant: the drip never lets total earned exceed the notified reward.
    function testFuzz_EarnedNeverExceedsNotified(uint256 aStake, uint256 bStake, uint256 reward, uint256 elapsed)
        public
    {
        aStake = bound(aStake, 1 ether, SEED);
        bStake = bound(bStake, 1 ether, SEED);
        // Keep reward modest so balance/duration comfortably covers the rate (no RewardTooHigh).
        reward = bound(reward, 1 ether, 100_000 ether);

        // Both stake before the drip begins.
        vm.prank(alice);
        stakingFans.stake(aStake);
        vm.prank(bob);
        stakingFans.stake(bStake);

        // Owner funds + notifies (mint transfers the reward $FANS in first).
        vm.startPrank(owner);
        fans.mint(address(stakingFans), reward);
        stakingFans.notifyRewardAmount(reward);
        vm.stopPrank();

        // Advance an arbitrary amount of time, possibly past period end.
        elapsed = bound(elapsed, 0, 2 * duration);
        vm.warp(block.timestamp + elapsed);

        uint256 total = stakingFans.earned(alice) + stakingFans.earned(bob);
        assertLe(total, reward, "earned never exceeds notified reward");
    }
}
