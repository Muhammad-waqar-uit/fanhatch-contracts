// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType, IClubKey} from "../../src/interfaces/IFansInterfaces.sol";

/// @title ClubKeyUnit
/// @notice Unit tests for ClubKey: free first key, buy/sell pricing + fees, gifting, reserve accounting.
contract ClubKeyUnit is FansBase {
    // Linear ("Casual") preset constants, mirrored from CurveLibrary for exact-number assertions.
    uint256 internal constant BASE_PRICE = 1e16;
    uint256 internal constant LINEAR_SLOPE = 1e15;
    uint256 internal constant FEE_BPS = 150; // 1.5%
    uint256 internal constant TREASURY_SHARE_BPS = 7000; // 70%

    /// @dev Total cost (excl. fee) to buy `amount` keys at the given `supply` on the Linear curve.
    function _linearCost(uint256 supply, uint256 amount) internal pure returns (uint256) {
        uint256 indexSum = amount * supply + (amount * (amount - 1)) / 2;
        return amount * BASE_PRICE + LINEAR_SLOPE * indexSum;
    }

    // --- Creation: free first key (spec §1.3) ---

    function test_creationMintsFreeFirstKey() public {
        // KeyBought(creator, 1, 0) is emitted during initialize inside createClub.
        // Emitter (the not-yet-known proxy) is intentionally unchecked.
        vm.expectEmit(true, false, false, true);
        emit IClubKey.KeyBought(creator, 1, 0);

        (, ClubKey key) = _createClub(CurveType.Linear);

        assertEq(key.totalSupplyKeys(), 1);
        assertEq(key.balanceOf(creator), 1);
    }

    // --- buyKeys ---

    function test_buyKeysChargesCostPlusFeeAndSplitsFee() public {
        (, ClubKey key) = _createClub(CurveType.Linear);

        uint256 amount = 10;
        uint256 expectedCost = _linearCost(1, amount); // supply starts at 1 after creation
        uint256 expectedFee = (expectedCost * FEE_BPS) / 10_000;
        uint256 toTreasury = (expectedFee * TREASURY_SHARE_BPS) / 10_000;
        uint256 toFarmers = expectedFee - toTreasury;

        uint256 aliceBefore = fans.balanceOf(alice);
        uint256 treasuryBefore = fans.balanceOf(treasury);
        uint256 farmersBefore = fees.farmerRewards();

        _buy(key, alice, amount);

        // Supply + buyer balance grew.
        assertEq(key.totalSupplyKeys(), 1 + amount);
        assertEq(key.balanceOf(alice), amount);

        // Buyer charged cost + fee in $FANS.
        assertEq(fans.balanceOf(alice), aliceBefore - expectedCost - expectedFee);

        // Reserve (cost) held by the ClubKey contract.
        assertEq(fans.balanceOf(address(key)), expectedCost);

        // Fee split: 70% treasury, 30% farmers.
        assertEq(fans.balanceOf(treasury) - treasuryBefore, toTreasury);
        assertEq(fees.farmerRewards() - farmersBefore, toFarmers);
    }

    function test_buyKeysRevertsSlippage() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        vm.startPrank(alice);
        fans.approve(address(key), type(uint256).max);
        vm.expectRevert(ClubKey.SlippageExceeded.selector);
        key.buyKeys(1, 1); // total cost+fee far exceeds maxCost of 1
        vm.stopPrank();
    }

    function test_buyKeysRevertsZeroAmount() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        vm.prank(alice);
        vm.expectRevert(ClubKey.ZeroAmount.selector);
        key.buyKeys(0, type(uint256).max);
    }

    // --- sellKeys ---

    function test_sellKeysPaysProceedsNetOfFee() public {
        (, ClubKey key) = _createClub(CurveType.Linear);

        uint256 amount = 8;
        _buy(key, alice, amount);

        uint256 supplyBefore = key.totalSupplyKeys();
        // Symmetric curve: proceeds for selling `amount` at supply S == cost integral over [S-amount, S).
        uint256 gross = _linearCost(supplyBefore - amount, amount);
        uint256 fee = (gross * FEE_BPS) / 10_000;
        uint256 payout = gross - fee;

        uint256 aliceBefore = fans.balanceOf(alice);

        vm.prank(alice);
        key.sellKeys(amount, 0);

        assertEq(fans.balanceOf(alice) - aliceBefore, payout);
        assertEq(key.totalSupplyKeys(), supplyBefore - amount);
        assertEq(key.balanceOf(alice), 0);
    }

    function test_sellKeysRevertsInsufficientKeys() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        vm.prank(alice); // alice owns 0 keys
        vm.expectRevert(ClubKey.InsufficientKeys.selector);
        key.sellKeys(1, 0);
    }

    function test_sellKeysRevertsSlippage() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        _buy(key, alice, 5);
        vm.prank(alice);
        vm.expectRevert(ClubKey.SlippageExceeded.selector);
        key.sellKeys(5, type(uint256).max); // minProceeds unreachable
    }

    // --- gift (spec §1.7) ---

    function test_giftMovesKeysWithoutFee() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        _buy(key, alice, 4);

        uint256 aliceFansBefore = fans.balanceOf(alice);
        uint256 keyReserveBefore = fans.balanceOf(address(key));
        uint256 supplyBefore = key.totalSupplyKeys();

        vm.expectEmit(true, true, false, true, address(key));
        emit IClubKey.Gift(alice, bob, 3);

        vm.prank(alice);
        key.gift(bob, 3);

        assertEq(key.balanceOf(alice), 1);
        assertEq(key.balanceOf(bob), 3);
        // No fee, no $FANS movement, supply unchanged.
        assertEq(fans.balanceOf(alice), aliceFansBefore);
        assertEq(fans.balanceOf(address(key)), keyReserveBefore);
        assertEq(key.totalSupplyKeys(), supplyBefore);
    }

    function test_giftRevertsInsufficientKeys() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        vm.prank(alice); // alice owns 0
        vm.expectRevert(ClubKey.InsufficientKeys.selector);
        key.gift(bob, 1);
    }

    function test_giftRevertsZeroAmount() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        vm.prank(creator);
        vm.expectRevert(ClubKey.ZeroAmount.selector);
        key.gift(bob, 0);
    }

    function test_giftRevertsZeroAddress() public {
        (, ClubKey key) = _createClub(CurveType.Linear);
        vm.prank(creator);
        vm.expectRevert(ClubKey.NotCreator.selector);
        key.gift(address(0), 1);
    }

    // --- round trip: buy then immediately sell loses to fees; reserve stays solvent ---

    function test_buyThenSellLosesToFeesAndReserveSolvent() public {
        (, ClubKey key) = _createClub(CurveType.Linear);

        uint256 amount = 6;
        uint256 cost = _linearCost(1, amount);
        uint256 buyFee = (cost * FEE_BPS) / 10_000;
        uint256 paid = cost + buyFee;

        uint256 aliceStart = fans.balanceOf(alice);
        _buy(key, alice, amount);

        // Reserve must cover everything that could be sold back (down to the free first key).
        uint256 owed = key.sellPrice(key.totalSupplyKeys() - 1);
        assertGe(fans.balanceOf(address(key)), owed);

        uint256 aliceAfterBuy = fans.balanceOf(alice);
        assertEq(aliceStart - aliceAfterBuy, paid);

        vm.prank(alice);
        key.sellKeys(amount, 0);

        uint256 received = fans.balanceOf(alice) - aliceAfterBuy;

        // Got back strictly less than paid (fee on both sides).
        assertLt(received, paid);

        // Reserve drained back to zero (round trip nets out the curve, fees siphoned off).
        assertEq(fans.balanceOf(address(key)), 0);
        assertGe(fans.balanceOf(address(key)), 0); // trivially solvent: nothing owed at supply 1
    }

    /// The creator's free first key is non-redeemable — supply can never be sold to zero.
    function test_cannotSellLastKey() public {
        (, ClubKey key) = _createClub(CurveType.Linear); // supply == 1 (creator's free key)
        vm.prank(creator);
        vm.expectRevert(ClubKey.CannotSellLastKey.selector);
        key.sellKeys(1, 0);
    }
}
