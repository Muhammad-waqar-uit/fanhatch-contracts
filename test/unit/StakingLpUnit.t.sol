// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";

/// @title StakingLpUnit
/// @notice End-to-end test of the LP farm (`stakingLp`): provide FansSwap liquidity to mint
///         FANS-LP tokens, stake the LP, earn $FANS rewards, claim, and unstake.
///         Here stakingToken (FANS-LP) != rewardToken ($FANS), so no Synthetix self-stake caveat.
contract StakingLpUnit is FansBase {
    uint256 internal duration;
    uint256 internal lpShares;

    function setUp() public override {
        super.setUp();
        duration = stakingLp.rewardsDuration();

        // Alice provides liquidity to FansSwap and receives FANS-LP tokens.
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        fans.approve(address(swap), type(uint256).max);
        lpShares = swap.addLiquidity{value: 10 ether}(40 ether, 0);
        // Approve the LP token (the swap contract is the ERC20) to the LP farm.
        swap.approve(address(stakingLp), type(uint256).max);
        vm.stopPrank();
    }

    function test_LpStakingEndToEnd() public {
        assertGt(lpShares, 0, "alice should hold LP");

        // Stake all LP.
        vm.prank(alice);
        stakingLp.stake(lpShares);
        assertEq(stakingLp.balanceOf(alice), lpShares, "LP staked");
        assertEq(stakingLp.totalStaked(), lpShares, "totalStaked");
        assertEq(swap.balanceOf(alice), 0, "LP pulled from alice");

        // Owner (the configured rewardsDistributor for stakingLp) funds the farm in $FANS
        // and starts the drip.
        uint256 reward = 1_000 ether;
        vm.startPrank(owner);
        fans.mint(address(stakingLp), reward);
        stakingLp.notifyRewardAmount(reward);
        vm.stopPrank();

        // Run the full period; alice (sole staker) earns ~all of it in $FANS.
        vm.warp(block.timestamp + duration + 1);
        uint256 earnedFull = stakingLp.earned(alice);
        assertApproxEqRel(earnedFull, reward, 1e16, "alice earns ~R in $FANS");

        uint256 fansBefore = fans.balanceOf(alice);
        vm.prank(alice);
        stakingLp.getReward();
        assertEq(fans.balanceOf(alice) - fansBefore, earnedFull, "$FANS reward paid");
        assertEq(stakingLp.earned(alice), 0, "earned reset");

        // Withdraw the LP back.
        vm.prank(alice);
        stakingLp.withdraw(lpShares);
        assertEq(stakingLp.balanceOf(alice), 0, "stake withdrawn");
        assertEq(swap.balanceOf(alice), lpShares, "LP returned to alice");
    }
}
