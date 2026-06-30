// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FansBase} from "../base/FansBase.t.sol";
import {FansSwap} from "../../src/swap/FansSwap.sol";

/// @title FansSwapUnit
/// @notice Unit tests for the constant-product (x*y=k) AMM in FansSwap.
contract FansSwapUnit is FansBase {
    event LiquidityAdded(address indexed provider, uint256 ethIn, uint256 fansIn, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 ethOut, uint256 fansOut, uint256 shares);
    event Swapped(address indexed user, bool ethToFans, uint256 amountIn, uint256 amountOut);

    function setUp() public override {
        super.setUp();
        // Fund providers with ETH and approve $FANS to the swap.
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.prank(alice);
        fans.approve(address(swap), type(uint256).max);
        vm.prank(bob);
        fans.approve(address(swap), type(uint256).max);
    }

    /// @dev Mirror of FansSwap._amountOut (0.3% fee).
    function _expectedOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 9970;
        return (amountInWithFee * reserveOut) / (reserveIn * 10_000 + amountInWithFee);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    // --- addLiquidity ---

    function test_FirstProviderMintsSqrtShares() public {
        uint256 ethIn = 10 ether;
        uint256 fansIn = 40 ether;
        uint256 expectedShares = _sqrt(ethIn * fansIn);

        vm.expectEmit(true, false, false, true, address(swap));
        emit LiquidityAdded(alice, ethIn, fansIn, expectedShares);

        vm.prank(alice);
        uint256 shares = swap.addLiquidity{value: ethIn}(fansIn, 0);

        assertEq(shares, expectedShares, "shares != sqrt(eth*fans)");
        assertEq(swap.totalSupply(), expectedShares, "totalShares");
        assertEq(swap.balanceOf(alice), expectedShares, "sharesOf");
        assertEq(swap.reserveEth(), ethIn, "reserveEth");
        assertEq(swap.reserveFans(), fansIn, "reserveFans");
    }

    function test_SecondProviderProportionalShares() public {
        uint256 ethIn = 10 ether;
        uint256 fansIn = 40 ether;
        vm.prank(alice);
        uint256 aShares = swap.addLiquidity{value: ethIn}(fansIn, 0);

        // Bob adds at the current ratio (1 ETH : 4 FANS). Provide >= required.
        uint256 bobEth = 5 ether;
        uint256 expectedBobShares = (bobEth * swap.totalSupply()) / swap.reserveEth();
        uint256 requiredFans = (bobEth * swap.reserveFans()) / swap.reserveEth();

        vm.prank(bob);
        uint256 bShares = swap.addLiquidity{value: bobEth}(requiredFans, 0);

        assertEq(bShares, expectedBobShares, "proportional shares");
        // Bob put in half of Alice's ETH -> roughly half her shares.
        assertApproxEqAbs(bShares, aShares / 2, 1, "approx half");
        assertEq(swap.reserveEth(), ethIn + bobEth, "reserveEth combined");
        assertEq(swap.reserveFans(), fansIn + requiredFans, "reserveFans combined");
    }

    function test_AddLiquidityRevertsOnMismatchedRatio() public {
        vm.prank(alice);
        swap.addLiquidity{value: 10 ether}(40 ether, 0);

        // Required fans for 5 ETH is 20 ether; supply less -> SlippageExceeded.
        vm.prank(bob);
        vm.expectRevert(FansSwap.SlippageExceeded.selector);
        swap.addLiquidity{value: 5 ether}(19 ether, 0);
    }

    function test_AddLiquidityRevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(FansSwap.ZeroAmount.selector);
        swap.addLiquidity{value: 0}(40 ether, 0);

        vm.prank(alice);
        vm.expectRevert(FansSwap.ZeroAmount.selector);
        swap.addLiquidity{value: 10 ether}(0, 0);
    }

    function test_AddLiquidityRevertsMinSharesNotMet() public {
        vm.prank(alice);
        vm.expectRevert(FansSwap.SlippageExceeded.selector);
        swap.addLiquidity{value: 10 ether}(40 ether, type(uint256).max);
    }

    // --- swapEthForFans ---

    function test_SwapEthForFansRespectsFee() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);

        uint256 amountIn = 1 ether;
        uint256 expected = _expectedOut(amountIn, swap.reserveEth(), swap.reserveFans());
        uint256 fansBefore = fans.balanceOf(bob);

        vm.expectEmit(true, false, false, true, address(swap));
        emit Swapped(bob, true, amountIn, expected);

        vm.prank(bob);
        uint256 out = swap.swapEthForFans{value: amountIn}(0);

        assertEq(out, expected, "output != fee formula");
        assertEq(fans.balanceOf(bob) - fansBefore, expected, "fans received");
        assertEq(swap.reserveEth(), 100 ether + amountIn, "reserveEth");
        assertEq(swap.reserveFans(), 400 ether - expected, "reserveFans");
    }

    function test_SwapEthForFansRevertsSlippage() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);

        vm.prank(bob);
        vm.expectRevert(FansSwap.SlippageExceeded.selector);
        swap.swapEthForFans{value: 1 ether}(type(uint256).max);
    }

    function test_SwapEthForFansRevertsEmptyPool() public {
        vm.prank(bob);
        vm.expectRevert(FansSwap.InsufficientLiquidity.selector);
        swap.swapEthForFans{value: 1 ether}(0);
    }

    function test_SwapEthForFansRevertsZeroAmount() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);
        vm.prank(bob);
        vm.expectRevert(FansSwap.ZeroAmount.selector);
        swap.swapEthForFans{value: 0}(0);
    }

    // --- swapFansForEth ---

    function test_SwapFansForEthRespectsFee() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);

        uint256 fansIn = 4 ether;
        uint256 expected = _expectedOut(fansIn, swap.reserveFans(), swap.reserveEth());
        uint256 ethBefore = bob.balance;

        vm.expectEmit(true, false, false, true, address(swap));
        emit Swapped(bob, false, fansIn, expected);

        vm.prank(bob);
        uint256 out = swap.swapFansForEth(fansIn, 0);

        assertEq(out, expected, "output != fee formula");
        assertEq(bob.balance - ethBefore, expected, "eth received");
        assertEq(swap.reserveFans(), 400 ether + fansIn, "reserveFans");
        assertEq(swap.reserveEth(), 100 ether - expected, "reserveEth");
    }

    function test_SwapFansForEthRevertsSlippage() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);

        vm.prank(bob);
        vm.expectRevert(FansSwap.SlippageExceeded.selector);
        swap.swapFansForEth(4 ether, type(uint256).max);
    }

    function test_SwapFansForEthRevertsEmptyPool() public {
        vm.prank(bob);
        vm.expectRevert(FansSwap.InsufficientLiquidity.selector);
        swap.swapFansForEth(4 ether, 0);
    }

    function test_SwapFansForEthRevertsZeroAmount() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);
        vm.prank(bob);
        vm.expectRevert(FansSwap.ZeroAmount.selector);
        swap.swapFansForEth(0, 0);
    }

    // --- removeLiquidity ---

    function test_RemoveLiquidityProRata() public {
        vm.prank(alice);
        uint256 shares = swap.addLiquidity{value: 10 ether}(40 ether, 0);

        uint256 removeShares = shares / 2;
        uint256 expectedEth = (removeShares * swap.reserveEth()) / swap.totalSupply();
        uint256 expectedFans = (removeShares * swap.reserveFans()) / swap.totalSupply();

        uint256 ethBefore = alice.balance;
        uint256 fansBefore = fans.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(swap));
        emit LiquidityRemoved(alice, expectedEth, expectedFans, removeShares);

        vm.prank(alice);
        (uint256 ethOut, uint256 fansOut) = swap.removeLiquidity(removeShares, 0, 0);

        assertEq(ethOut, expectedEth, "ethOut");
        assertEq(fansOut, expectedFans, "fansOut");
        assertEq(alice.balance - ethBefore, expectedEth, "eth credited");
        assertEq(fans.balanceOf(alice) - fansBefore, expectedFans, "fans credited");
        assertEq(swap.balanceOf(alice), shares - removeShares, "shares burned");
        assertEq(swap.totalSupply(), shares - removeShares, "totalShares burned");
    }

    function test_RemoveLiquidityRevertsInsufficientShares() public {
        vm.prank(alice);
        uint256 shares = swap.addLiquidity{value: 10 ether}(40 ether, 0);

        vm.prank(alice);
        vm.expectRevert(FansSwap.InsufficientShares.selector);
        swap.removeLiquidity(shares + 1, 0, 0);
    }

    function test_RemoveLiquidityRevertsZeroAmount() public {
        vm.prank(alice);
        swap.addLiquidity{value: 10 ether}(40 ether, 0);
        vm.prank(alice);
        vm.expectRevert(FansSwap.ZeroAmount.selector);
        swap.removeLiquidity(0, 0, 0);
    }

    // --- getAmountOut view ---

    function test_GetAmountOutMatchesSwapEthForFans() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);

        uint256 amountIn = 2 ether;
        uint256 quoted = swap.getAmountOut(amountIn, true);

        vm.prank(bob);
        uint256 out = swap.swapEthForFans{value: amountIn}(0);
        assertEq(out, quoted, "quote != actual (eth->fans)");
    }

    function test_GetAmountOutMatchesSwapFansForEth() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);

        uint256 fansIn = 8 ether;
        uint256 quoted = swap.getAmountOut(fansIn, false);

        vm.prank(bob);
        uint256 out = swap.swapFansForEth(fansIn, 0);
        assertEq(out, quoted, "quote != actual (fans->eth)");
    }

    // --- constant product invariant ---

    function test_ConstantProductGrowsAfterSwap() public {
        vm.prank(alice);
        swap.addLiquidity{value: 100 ether}(400 ether, 0);

        uint256 kBefore = swap.reserveEth() * swap.reserveFans();

        vm.prank(bob);
        swap.swapEthForFans{value: 5 ether}(0);

        uint256 kAfter = swap.reserveEth() * swap.reserveFans();
        assertGe(kAfter, kBefore, "k must not shrink after swap");

        // And again on the reverse direction.
        uint256 kBefore2 = swap.reserveEth() * swap.reserveFans();
        vm.prank(bob);
        swap.swapFansForEth(10 ether, 0);
        uint256 kAfter2 = swap.reserveEth() * swap.reserveFans();
        assertGe(kAfter2, kBefore2, "k must not shrink after reverse swap");
    }
}
