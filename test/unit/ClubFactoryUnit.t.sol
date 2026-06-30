// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {FansBase} from "../base/FansBase.t.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {CurveType, IClubFactory} from "../../src/interfaces/IFansInterfaces.sol";

/// @title ClubFactoryUnit
/// @notice Unit tests for ClubFactory: sequential ids, registry, ftId, club independence, both curves.
contract ClubFactoryUnit is FansBase {
    bytes32 internal constant CLUB_CREATED_SIG =
        keccak256("ClubCreated(uint256,address,string,uint8,address)");

    function test_createClubSequentialIdsAndRegistry() public {
        assertEq(factory.clubCount(), 0);

        (uint256 id1, address key1) = _create("$AAA", CurveType.Linear);
        (uint256 id2, address key2) = _create("$BBB", CurveType.Exponential);
        (uint256 id3, address key3) = _create("$CCC", CurveType.Linear);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(factory.clubCount(), 3);

        assertEq(factory.clubKeyOf(1), key1);
        assertEq(factory.clubKeyOf(2), key2);
        assertEq(factory.clubKeyOf(3), key3);
    }

    function test_clubCreatedEvent() public {
        vm.recordLogs();
        vm.prank(creator);
        (uint256 id, address keyAddr) =
            factory.createClub("Club", "$EVT", "ipfs://a", CurveType.Exponential);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != CLUB_CREATED_SIG) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), id); // indexed clubId
            assertEq(address(uint160(uint256(logs[i].topics[2]))), creator); // indexed creator
            (string memory ticker, uint8 curve, address clubKey) =
                abi.decode(logs[i].data, (string, uint8, address));
            assertEq(ticker, "$EVT");
            assertEq(curve, uint8(CurveType.Exponential));
            assertEq(clubKey, keyAddr);
        }
        assertTrue(found, "ClubCreated not emitted");
    }

    function test_ftId() public view {
        assertEq(factory.ftId(1), "FT1");
        assertEq(factory.ftId(2), "FT2");
        assertEq(factory.ftId(42), "FT42");
    }

    function test_clubsAreIndependent() public {
        (, address k1) = _create("$ONE", CurveType.Linear);
        (, address k2) = _create("$TWO", CurveType.Linear);

        ClubKey key1 = ClubKey(k1);
        ClubKey key2 = ClubKey(k2);

        assertTrue(k1 != k2);
        assertEq(key1.totalSupplyKeys(), 1);
        assertEq(key2.totalSupplyKeys(), 1);

        _buy(key1, alice, 5);

        assertEq(key1.totalSupplyKeys(), 6);
        assertEq(key2.totalSupplyKeys(), 1); // untouched
        assertEq(key1.balanceOf(alice), 5);
        assertEq(key2.balanceOf(alice), 0);
    }

    function test_bothCurveTypesCreatableAndTradable() public {
        (, ClubKey linear) = _createClub(CurveType.Linear);
        (, ClubKey exp) = _createClub(CurveType.Exponential);

        assertEq(uint8(linear.curveType()), uint8(CurveType.Linear));
        assertEq(uint8(exp.curveType()), uint8(CurveType.Exponential));

        _buy(linear, alice, 3);
        _buy(exp, bob, 3);

        assertEq(linear.balanceOf(alice), 3);
        assertEq(exp.balanceOf(bob), 3);
        assertEq(linear.totalSupplyKeys(), 4);
        assertEq(exp.totalSupplyKeys(), 4);
    }

    function _create(string memory ticker, CurveType curveType)
        internal
        returns (uint256 id, address keyAddr)
    {
        vm.prank(creator);
        (id, keyAddr) = factory.createClub("Club", ticker, "ipfs://a", curveType);
    }
}
