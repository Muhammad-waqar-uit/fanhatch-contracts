// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract PlatformTokenUnit is FansBase {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // --- mint access control ---

    function test_MintByOwner() public {
        uint256 before = fans.balanceOf(alice);
        vm.prank(owner);
        fans.mint(alice, 1_000 ether);
        assertEq(fans.balanceOf(alice), before + 1_000 ether);
    }

    function test_MintRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        fans.mint(alice, 1_000 ether);
    }

    // --- pause / unpause ---

    function test_PauseBlocksTransfers() public {
        vm.prank(owner);
        fans.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        fans.transfer(bob, 1 ether);
    }

    function test_UnpauseRestoresTransfers() public {
        vm.prank(owner);
        fans.pause();
        vm.prank(owner);
        fans.unpause();

        uint256 bobBefore = fans.balanceOf(bob);
        vm.prank(alice);
        fans.transfer(bob, 1 ether);
        assertEq(fans.balanceOf(bob), bobBefore + 1 ether);
    }

    function test_PauseOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        fans.pause();
    }

    // --- ERC20Votes delegation ---

    function test_VotesRequireDelegation() public {
        // No delegation yet -> zero voting power despite holding a balance.
        assertGt(fans.balanceOf(alice), 0);
        assertEq(fans.getVotes(alice), 0);

        vm.prank(alice);
        fans.delegate(alice);

        assertEq(fans.getVotes(alice), fans.balanceOf(alice));
        assertEq(fans.delegates(alice), alice);
    }

    function test_VotesMoveWithTransferWhenDelegated() public {
        vm.prank(alice);
        fans.delegate(alice);
        vm.prank(bob);
        fans.delegate(bob);

        uint256 aliceVotes = fans.getVotes(alice);
        uint256 bobVotes = fans.getVotes(bob);

        vm.prank(alice);
        fans.transfer(bob, 100 ether);

        assertEq(fans.getVotes(alice), aliceVotes - 100 ether);
        assertEq(fans.getVotes(bob), bobVotes + 100 ether);
    }

    // --- permit / nonces ---

    function test_PermitSetsAllowanceAndBumpsNonce() public {
        (address signer, uint256 pk) = makeAddrAndKey("permitSigner");
        vm.prank(owner);
        fans.mint(signer, 500 ether);

        assertEq(fans.nonces(signer), 0);

        uint256 value = 250 ether;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, signer, bob, value, fans.nonces(signer), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", fans.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        fans.permit(signer, bob, value, deadline, v, r, s);

        assertEq(fans.allowance(signer, bob), value);
        assertEq(fans.nonces(signer), 1);
    }
}
