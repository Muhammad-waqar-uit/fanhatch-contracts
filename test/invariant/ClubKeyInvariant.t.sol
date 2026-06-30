// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType} from "../../src/interfaces/IFansInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ClubKeyHandler
/// @notice Drives random buy/sell/gift actions across a fixed set of actors on one Linear club.
/// @dev Bounded so the 5000 supply cap is never hit; gifts stay within the actor set so the
///      "sum of balances == totalSupplyKeys" invariant holds (no keys escape to outsiders).
contract ClubKeyHandler is Test {
    ClubKey public key;
    IERC20 public fans;
    address[3] public actors;

    uint256 internal constant SUPPLY_CEIL = 2_000;

    constructor(ClubKey key_, IERC20 fans_, address a0, address a1, address a2) {
        key = key_;
        fans = fans_;
        actors = [a0, a1, a2];
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            fans.approve(address(key_), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1, 20);
        if (key.totalSupplyKeys() + amount > SUPPLY_CEIL) return;
        address who = _actor(actorSeed);
        vm.prank(who);
        key.buyKeys(amount, type(uint256).max);
    }

    function sell(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 bal = key.balanceOf(who);
        if (bal == 0) return;
        // Never redeem the creator's free first key (minted with zero reserve at index 0):
        // keep total supply >= 1 so the reserve always covers the proceeds it pays out.
        uint256 supply = key.totalSupplyKeys();
        uint256 maxSell = bal < supply - 1 ? bal : supply - 1;
        if (maxSell == 0) return;
        amount = bound(amount, 1, maxSell);
        vm.prank(who);
        key.sellKeys(amount, 0);
    }

    function gift(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 bal = key.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        key.gift(to, amount);
    }
}

/// @title ClubKeyInvariant
/// @notice Reserve-solvency and supply-accounting invariants for ClubKey (spec §1.3, §1.4).
contract ClubKeyInvariant is FansBase {
    ClubKey internal key;
    ClubKeyHandler internal handler;

    function setUp() public override {
        super.setUp();
        (, key) = _createClub(CurveType.Linear);

        handler = new ClubKeyHandler(key, IERC20(address(fans)), creator, alice, bob);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ClubKeyHandler.buy.selector;
        selectors[1] = ClubKeyHandler.sell.selector;
        selectors[2] = ClubKeyHandler.gift.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Every key in existence is held by one of the three actors: balances sum to totalSupplyKeys.
    function invariant_supplyEqualsSumOfBalances() public view {
        uint256 sum = key.balanceOf(creator) + key.balanceOf(alice) + key.balanceOf(bob);
        assertEq(sum, key.totalSupplyKeys(), "balances must sum to supply");
    }

    /// The ClubKey holds at least the $FANS needed to redeem every key down to the creator's first
    /// key — the curve reserve is never insolvent.
    function invariant_reserveSolvent() public view {
        uint256 supply = key.totalSupplyKeys();
        uint256 owed = supply > 1 ? key.sellPrice(supply - 1) : 0;
        assertGe(fans.balanceOf(address(key)), owed, "reserve must cover full redemption");
    }
}
