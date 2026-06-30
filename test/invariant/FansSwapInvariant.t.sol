// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FansBase} from "../base/FansBase.t.sol";
import {FansSwap} from "../../src/swap/FansSwap.sol";
import {PlatformToken} from "../../src/token/PlatformToken.sol";

/// @title FansSwapHandler
/// @notice Bounded actor that drives random add/remove/swap operations against FansSwap.
contract FansSwapHandler is Test {
    FansSwap public swap;
    PlatformToken public fans;

    address[] public actors;

    constructor(FansSwap swap_, PlatformToken fans_, address[] memory actors_) {
        swap = swap_;
        fans = fans_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function addLiquidity(uint256 actorSeed, uint256 ethIn, uint256 fansIn) external {
        address actor = _actor(actorSeed);
        ethIn = bound(ethIn, 1e15, 50 ether);
        vm.deal(actor, actor.balance + ethIn);

        if (swap.totalSupply() == 0) {
            fansIn = bound(fansIn, 1e15, 50 ether);
        } else {
            // Supply at least the required ratio so the call can succeed.
            uint256 required = (ethIn * swap.reserveFans()) / swap.reserveEth();
            if (required == 0) required = 1;
            fansIn = bound(fansIn, required, required + 50 ether);
        }
        if (fans.balanceOf(actor) < fansIn) return;

        vm.prank(actor);
        try swap.addLiquidity{value: ethIn}(fansIn, 0) {} catch {}
    }

    function removeLiquidity(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 bal = swap.balanceOf(actor);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(actor);
        try swap.removeLiquidity(shares, 0, 0) {} catch {}
    }

    function swapEthForFans(uint256 actorSeed, uint256 ethIn) external {
        if (swap.reserveEth() == 0 || swap.reserveFans() == 0) return;
        address actor = _actor(actorSeed);
        ethIn = bound(ethIn, 1e12, 20 ether);
        vm.deal(actor, actor.balance + ethIn);

        uint256 kBefore = swap.reserveEth() * swap.reserveFans();
        vm.prank(actor);
        try swap.swapEthForFans{value: ethIn}(0) {
            uint256 kAfter = swap.reserveEth() * swap.reserveFans();
            assertGe(kAfter, kBefore, "k decreased on eth->fans swap");
        } catch {}
    }

    function swapFansForEth(uint256 actorSeed, uint256 fansIn) external {
        if (swap.reserveEth() == 0 || swap.reserveFans() == 0) return;
        address actor = _actor(actorSeed);
        fansIn = bound(fansIn, 1e12, 20 ether);
        if (fans.balanceOf(actor) < fansIn) return;

        uint256 kBefore = swap.reserveEth() * swap.reserveFans();
        vm.prank(actor);
        try swap.swapFansForEth(fansIn, 0) {
            uint256 kAfter = swap.reserveEth() * swap.reserveFans();
            assertGe(kAfter, kBefore, "k decreased on fans->eth swap");
        } catch {}
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

/// @title FansSwapInvariant
/// @notice Invariant tests driving FansSwap through a bounded handler.
contract FansSwapInvariant is FansBase {
    FansSwapHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();

        // Fixed set of actors, each funded with $FANS + ETH and approved to the swap.
        actors.push(makeAddr("lp1"));
        actors.push(makeAddr("lp2"));
        actors.push(makeAddr("trader1"));

        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            vm.prank(owner);
            fans.mint(a, SEED);
            vm.deal(a, 100 ether);
            vm.prank(a);
            fans.approve(address(swap), type(uint256).max);
        }

        // Bootstrap the pool so swaps have something to work with.
        vm.deal(actors[0], actors[0].balance + 50 ether);
        vm.prank(actors[0]);
        swap.addLiquidity{value: 50 ether}(200 ether, 0);

        handler = new FansSwapHandler(swap, fans, actors);

        // Handler must approve too (it is the msg.sender substitute via prank,
        // but actors prank inside the handler, so actor approvals already cover it).
        targetContract(address(handler));
    }

    /// @notice Sum of every actor's shares must equal totalShares.
    function invariant_ShareAccounting() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += swap.balanceOf(actors[i]);
        }
        assertEq(sum, swap.totalSupply(), "sum(sharesOf) != totalShares");
    }

    /// @notice totalShares == 0 if and only if both reserves are zero.
    function invariant_SharesIffReserves() public view {
        bool noShares = swap.totalSupply() == 0;
        bool noReserves = swap.reserveEth() == 0 && swap.reserveFans() == 0;
        assertEq(noShares, noReserves, "totalShares==0 must match empty reserves");
    }

    /// @notice Whenever there are shares, both reserves are strictly positive.
    function invariant_ReservesPositiveWhileActive() public view {
        if (swap.totalSupply() > 0) {
            assertGt(swap.reserveEth(), 0, "reserveEth zero while shares outstanding");
            assertGt(swap.reserveFans(), 0, "reserveFans zero while shares outstanding");
        }
    }
}
