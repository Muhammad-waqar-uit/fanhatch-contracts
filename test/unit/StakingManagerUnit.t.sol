// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";

/// @title StakingManagerUnit
/// @notice Unit tests for the Synthetix-style $FANS farm (`stakingFans`):
///         stake/withdraw mechanics, the reward drip, and access control.
contract StakingManagerUnit is FansBase {
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    uint256 internal duration;

    function setUp() public override {
        super.setUp();
        duration = stakingFans.rewardsDuration();
        // Stakers approve $FANS to the farm.
        vm.prank(alice);
        fans.approve(address(stakingFans), type(uint256).max);
        vm.prank(bob);
        fans.approve(address(stakingFans), type(uint256).max);
    }

    /// @dev As owner: mint `reward` $FANS straight into the farm (the "transfer in" step),
    ///      then kick off the drip. Owner is an allowed distributor.
    function _fundAndNotify(uint256 reward) internal {
        vm.startPrank(owner);
        fans.mint(address(stakingFans), reward);
        stakingFans.notifyRewardAmount(reward);
        vm.stopPrank();
    }

    // --- stake ---

    function test_StakePullsTokensAndUpdatesAccounting() public {
        uint256 amount = 100 ether;
        uint256 aliceBefore = fans.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(stakingFans));
        emit Staked(alice, amount);

        vm.prank(alice);
        stakingFans.stake(amount);

        assertEq(stakingFans.balanceOf(alice), amount, "balanceOf");
        assertEq(stakingFans.totalStaked(), amount, "totalStaked");
        assertEq(fans.balanceOf(alice), aliceBefore - amount, "tokens pulled from alice");
        assertEq(fans.balanceOf(address(stakingFans)), amount, "tokens held by farm");
    }

    function test_StakeRevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(StakingManager.ZeroAmount.selector);
        stakingFans.stake(0);
    }

    // --- withdraw ---

    function test_WithdrawReturnsTokens() public {
        uint256 amount = 100 ether;
        vm.prank(alice);
        stakingFans.stake(amount);

        uint256 aliceBefore = fans.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(stakingFans));
        emit Withdrawn(alice, 40 ether);

        vm.prank(alice);
        stakingFans.withdraw(40 ether);

        assertEq(stakingFans.balanceOf(alice), 60 ether, "remaining stake");
        assertEq(stakingFans.totalStaked(), 60 ether, "totalStaked");
        assertEq(fans.balanceOf(alice), aliceBefore + 40 ether, "tokens returned");
    }

    function test_WithdrawRevertsInsufficientStake() public {
        vm.prank(alice);
        stakingFans.stake(100 ether);

        vm.prank(alice);
        vm.expectRevert(StakingManager.InsufficientStake.selector);
        stakingFans.withdraw(100 ether + 1);
    }

    // --- reward drip ---

    function test_RewardDripAccruesAndPays() public {
        uint256 reward = 1_000 ether;

        // Alice stakes BEFORE the drip starts so she captures the full stream.
        vm.prank(alice);
        stakingFans.stake(500 ether);

        _fundAndNotify(reward);

        // Halfway through the period -> ~half the reward.
        vm.warp(block.timestamp + duration / 2);
        assertApproxEqRel(stakingFans.earned(alice), reward / 2, 1e16, "earned ~ R/2 at halfway");

        // End of the period -> ~the full reward.
        vm.warp(block.timestamp + duration / 2 + 1);
        uint256 earnedFull = stakingFans.earned(alice);
        assertApproxEqRel(earnedFull, reward, 1e16, "earned ~ R at end");

        // getReward pays it out and resets accrual to zero.
        uint256 balBefore = fans.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(stakingFans));
        emit RewardPaid(alice, earnedFull);

        vm.prank(alice);
        stakingFans.getReward();

        assertEq(fans.balanceOf(alice) - balBefore, earnedFull, "reward paid");
        assertEq(stakingFans.earned(alice), 0, "earned reset");
    }

    // --- notifyRewardAmount access control / guards ---

    function test_NotifyRevertsNotDistributor() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(StakingManager.NotDistributor.selector);
        stakingFans.notifyRewardAmount(1 ether);
    }

    function test_NotifyRevertsRewardTooHigh() public {
        // No tokens transferred in -> contract balance is 0, so any positive rate
        // exceeds balance/duration and the Synthetix guard trips.
        vm.prank(owner);
        vm.expectRevert(StakingManager.RewardTooHigh.selector);
        stakingFans.notifyRewardAmount(1_000 ether);
    }

    // --- proportional split ---

    function test_TwoStakersSplitProportionalToStake() public {
        // Alice 100, Bob 300 -> 1:3 split.
        vm.prank(alice);
        stakingFans.stake(100 ether);
        vm.prank(bob);
        stakingFans.stake(300 ether);

        uint256 reward = 1_000 ether;
        _fundAndNotify(reward);

        vm.warp(block.timestamp + duration + 1);

        uint256 ea = stakingFans.earned(alice);
        uint256 eb = stakingFans.earned(bob);

        assertApproxEqRel(eb, ea * 3, 1e16, "bob earns ~3x alice");
        assertApproxEqRel(ea + eb, reward, 1e16, "split sums to ~R");
        assertLe(ea + eb, reward, "never pays out more than notified");
    }

    // --- exit ---

    function test_ExitWithdrawsAllAndClaims() public {
        vm.prank(alice);
        stakingFans.stake(200 ether);

        uint256 reward = 1_000 ether;
        _fundAndNotify(reward);
        vm.warp(block.timestamp + duration + 1);

        uint256 earnedFull = stakingFans.earned(alice);
        uint256 balBefore = fans.balanceOf(alice);

        vm.prank(alice);
        stakingFans.exit();

        assertEq(stakingFans.balanceOf(alice), 0, "stake fully withdrawn");
        assertEq(stakingFans.totalStaked(), 0, "totalStaked zeroed");
        // Got back principal (200) + reward.
        assertEq(fans.balanceOf(alice) - balBefore, 200 ether + earnedFull, "principal + reward returned");
    }

    // --- setRewardsDuration ---

    function test_SetRewardsDurationOnlyWhenDripInactive() public {
        vm.prank(alice);
        stakingFans.stake(100 ether);
        _fundAndNotify(1_000 ether);

        // Drip is live -> reverts.
        vm.prank(owner);
        vm.expectRevert(bytes("drip active"));
        stakingFans.setRewardsDuration(14 days);

        // After the period ends it succeeds.
        vm.warp(block.timestamp + duration + 1);
        vm.prank(owner);
        stakingFans.setRewardsDuration(14 days);
        assertEq(stakingFans.rewardsDuration(), 14 days, "duration updated");
    }

    function test_SetRewardsDurationOwnerOnly() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        stakingFans.setRewardsDuration(14 days);
    }
}
