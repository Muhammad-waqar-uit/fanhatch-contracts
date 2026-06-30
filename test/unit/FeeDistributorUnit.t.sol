// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {FeeDistributor} from "../../src/fees/FeeDistributor.sol";
import {IFeeDistributor} from "../../src/interfaces/IFansInterfaces.sol";

/// @title FeeDistributorUnit
/// @notice Unit tests for the 1.5% trade-fee router (spec §1.5).
contract FeeDistributorUnit is FansBase {
    // Mirror of events for expectEmit.
    event FeeDistributed(address indexed source, uint256 total, uint256 toTreasury, uint256 toFarmers);
    event FeeConfigUpdated(uint256 feeBps, uint256 treasuryShareBps);
    event FarmerRewardsClaimed(address indexed to, uint256 amount);

    /// Initial config: 1.5% fee, 70% to treasury.
    function test_initialConfig() public view {
        assertEq(fees.feeBps(), 150);
        assertEq(fees.treasuryShareBps(), 7000);
    }

    /// distribute splits the incoming $FANS 70/30 between treasury and the farmer pool.
    function test_distributeSplits70_30() public {
        uint256 amount = 1_000 ether;
        // Fund the distributor first (caller convention: tokens already transferred in).
        vm.prank(owner);
        fans.mint(address(fees), amount);

        uint256 expectedTreasury = (amount * 7000) / 10_000; // 700
        uint256 expectedFarmers = amount - expectedTreasury; // 300

        vm.expectEmit(true, false, false, true);
        emit FeeDistributed(address(this), amount, expectedTreasury, expectedFarmers);
        fees.distribute(amount);

        assertEq(fans.balanceOf(treasury), expectedTreasury, "treasury got 70%");
        assertEq(fees.farmerRewards(), expectedFarmers, "farmer pool += 30%");
        // The 30% stays in the distributor as the claimable pool.
        assertEq(fans.balanceOf(address(fees)), expectedFarmers);
    }

    /// claimFarmerRewards is owner-only; it pays out and zeroes the pool.
    function test_claimFarmerRewards() public {
        uint256 amount = 1_000 ether;
        vm.prank(owner);
        fans.mint(address(fees), amount);
        fees.distribute(amount);
        uint256 farmers = fees.farmerRewards();
        assertGt(farmers, 0);

        // Non-owner cannot claim.
        vm.prank(alice);
        vm.expectRevert();
        fees.claimFarmerRewards(alice);

        // Owner claims to a target address.
        vm.expectEmit(true, false, false, true);
        emit FarmerRewardsClaimed(bob, farmers);
        vm.prank(owner);
        fees.claimFarmerRewards(bob);

        assertEq(fans.balanceOf(bob), SEED + farmers, "rewards delivered");
        assertEq(fees.farmerRewards(), 0, "pool zeroed");
    }

    /// setFeeConfig is owner-only, validates bounds, and emits.
    function test_setFeeConfig() public {
        vm.expectEmit(false, false, false, true);
        emit FeeConfigUpdated(200, 6000);
        vm.prank(owner);
        fees.setFeeConfig(200, 6000);
        assertEq(fees.feeBps(), 200);
        assertEq(fees.treasuryShareBps(), 6000);
    }

    function test_setFeeConfigRevertsInvalidBps() public {
        // feeBps > 1000 (10% cap).
        vm.prank(owner);
        vm.expectRevert(FeeDistributor.InvalidBps.selector);
        fees.setFeeConfig(1001, 7000);

        // treasuryShareBps > 10000.
        vm.prank(owner);
        vm.expectRevert(FeeDistributor.InvalidBps.selector);
        fees.setFeeConfig(150, 10_001);
    }

    function test_setFeeConfigOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        fees.setFeeConfig(200, 6000);
    }

    /// distribute(0) is a no-op: nothing moves, no event side effects.
    function test_distributeZeroIsNoop() public {
        uint256 treasuryBefore = fans.balanceOf(treasury);
        uint256 farmersBefore = fees.farmerRewards();
        fees.distribute(0);
        assertEq(fans.balanceOf(treasury), treasuryBefore);
        assertEq(fees.farmerRewards(), farmersBefore);
    }
}
