// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";

/// @title FeeDripStakingIntegration
/// @notice End-to-end: club-key trading fees become a $FANS drip to stakers when a StakingManager
///         is wired into the FeeDistributor (figma Wallet "Farm Rewards"). Also covers the fallback
///         (farmerRewards accrual) and the no-revert invariant of the notify path.
contract FeeDripStakingIntegration is FansBase {
    /// @dev Stake `amount` $FANS into stakingFans as `who`.
    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        fans.approve(address(stakingFans), amount);
        stakingFans.stake(amount);
        vm.stopPrank();
    }

    /// @dev Sell `amount` keys as `who` (no approval needed; reserve pays out).
    function _sell(ClubKey key, address who, uint256 amount) internal {
        vm.prank(who);
        key.sellKeys(amount, 0);
    }

    /// Full drip path: fees -> staking manager -> notifyRewardAmount -> alice earns & claims $FANS.
    function test_tradingFeesDripToStakers() public {
        // Wire the farm into the fee distributor.
        vm.prank(owner);
        fees.setStakingManager(address(stakingFans));
        assertEq(fees.stakingManager(), address(stakingFans), "staking manager set");

        // Alice stakes $FANS BEFORE any trade so she's the sole farmer.
        uint256 aliceStake = 100_000 ether;
        _stake(alice, aliceStake);
        assertEq(stakingFans.totalStaked(), aliceStake, "alice is sole staker");

        // Snapshots before bob generates fees.
        uint256 treasuryBefore = fans.balanceOf(treasury);
        uint256 stakingBalBefore = fans.balanceOf(address(stakingFans));
        assertEq(stakingBalBefore, aliceStake, "farm holds only the stake so far");

        // Bob trades on a fresh club: buy then sell, generating fees on each leg.
        (, ClubKey key) = _createClub(CurveType.Linear);
        _buy(key, bob, 10);
        _sell(key, bob, 5);

        // The fee split is 70% treasury / 30% farmers; total fee = treasuryDelta / 0.7.
        uint256 treasuryDelta = fans.balanceOf(treasury) - treasuryBefore;
        assertGt(treasuryDelta, 0, "treasury received its 70% share");

        // The 30% farmer share was pushed into the farm: its $FANS balance grew by that amount.
        uint256 farmerShare = fans.balanceOf(address(stakingFans)) - stakingBalBefore;
        assertGt(farmerShare, 0, "farmer share streamed into the farm");
        // Sanity: farmerShare ~= 30/70 of the treasury share (rounding aside).
        assertApproxEqRel(farmerShare, (treasuryDelta * 3000) / 7000, 1e15, "30/70 split holds");

        // The drip is live.
        uint256 rate = stakingFans.rewardRate();
        assertGt(rate, 0, "rewardRate > 0");
        assertGt(stakingFans.periodFinish(), block.timestamp, "periodFinish in the future");

        // Nothing earned yet (no time has elapsed since the last notify).
        assertEq(stakingFans.earned(alice), 0, "no rewards before time passes");

        // Stream forward half the duration.
        uint256 elapsed = stakingFans.rewardsDuration() / 2;
        vm.warp(block.timestamp + elapsed);

        uint256 earned = stakingFans.earned(alice);
        assertGt(earned, 0, "alice's earned() grew");
        // Sole staker => earned == rewardRate * elapsed (modulo integer rounding).
        assertApproxEqRel(earned, rate * elapsed, 1e15, "earned == farmer share streamed so far");

        // Alice claims: she receives the $FANS.
        uint256 aliceBefore = fans.balanceOf(alice);
        vm.prank(alice);
        stakingFans.getReward();
        uint256 received = fans.balanceOf(alice) - aliceBefore;
        assertApproxEqRel(received, earned, 1e15, "getReward() paid out the earned $FANS");
    }

    /// Fallback: with NO staking manager wired, the farmer share accrues to farmerRewards and the
    /// farm's $FANS balance is untouched.
    function test_fallbackAccruesFarmerRewardsWhenUnset() public {
        assertEq(fees.stakingManager(), address(0), "no staking manager by default");

        uint256 farmerRewardsBefore = fees.farmerRewards();
        uint256 stakingBalBefore = fans.balanceOf(address(stakingFans));

        // Trades without ever calling setStakingManager.
        (, ClubKey key) = _createClub(CurveType.Linear);
        _buy(key, bob, 10);
        _sell(key, bob, 5);

        assertGt(fees.farmerRewards(), farmerRewardsBefore, "farmerRewards accrued (fallback path)");
        assertEq(fans.balanceOf(address(stakingFans)), stakingBalBefore, "farm balance untouched");
    }

    /// Edge: a trade still succeeds with a staking manager set, and the notify path keeps rewardRate
    /// within what the farm balance can cover (Synthetix invariant, no RewardTooHigh revert).
    function test_tradeSucceedsAndRewardRateWithinBalance() public {
        vm.prank(owner);
        fees.setStakingManager(address(stakingFans));

        // A staker must exist for a meaningful farm, but the notify path must not revert regardless.
        _stake(alice, 50_000 ether);

        (, ClubKey key) = _createClub(CurveType.Linear);
        // Should not revert from the notify path.
        _buy(key, bob, 8);

        uint256 rate = stakingFans.rewardRate();
        assertGt(rate, 0, "drip started");
        uint256 dur = stakingFans.rewardsDuration();
        // Invariant: rewardRate <= balance / duration.
        assertLe(rate, fans.balanceOf(address(stakingFans)) / dur, "rewardRate covered by balance");
        assertGt(stakingFans.periodFinish(), block.timestamp, "drip active");

        // A second trade extends the drip without reverting and preserves the invariant.
        _sell(key, bob, 3);
        rate = stakingFans.rewardRate();
        assertLe(rate, fans.balanceOf(address(stakingFans)) / dur, "rewardRate still covered after extend");
    }
}
