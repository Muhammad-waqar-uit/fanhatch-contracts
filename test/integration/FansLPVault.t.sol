// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlatformToken} from "../../src/token/PlatformToken.sol";
import {FeeDistributor} from "../../src/fees/FeeDistributor.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";
import {IFeeDistributor} from "../../src/interfaces/IFansInterfaces.sol";
import {FansHook} from "../../src/swap/FansHook.sol";
import {FansV4Router} from "../../src/swap/FansV4Router.sol";
import {FansLPVault} from "../../src/swap/FansLPVault.sol";

/// @title FansLPVaultTest
/// @notice Phase-2 harness: the {FansLPVault} owns the single full-range position over the Phase-1
///         ETH/$FANS pool. Verifies share/liquidity math on deposit & withdraw, that swaps trade
///         against the vault's liquidity, and the end-to-end LP-farm path (deposit -> stake FANS-LP
///         -> swaps drip the farm -> LP staker earns and claims $FANS).
contract FansLPVaultTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    int24 constant TICK_SPACING = 60;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PlatformToken fans;
    FeeDistributor fees;
    StakingManager lpFarm; // LP farm: stake FANS-LP, earn $FANS
    FansHook hook;
    FansV4Router router;
    FansLPVault vault;
    PoolKey poolKey;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); // first LP depositor
    address bob = makeAddr("bob"); // second LP depositor + farm staker
    address carol = makeAddr("carol"); // swapper

    function setUp() public {
        deployFreshManagerAndRouters();

        // ── $FANS token (UUPS) ──────────────────────────────────────────────────
        PlatformToken tokenImpl = new PlatformToken();
        fans = PlatformToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeWithSelector(
                        PlatformToken.initialize.selector, "Fans Token", "FANS", address(this), 10_000_000 ether
                    )
                )
            )
        );

        // ── FeeDistributor ──────────────────────────────────────────────────────
        FeeDistributor feesImpl = new FeeDistributor();
        fees = FeeDistributor(
            address(
                new ERC1967Proxy(
                    address(feesImpl),
                    abi.encodeWithSelector(
                        FeeDistributor.initialize.selector, address(this), IERC20(address(fans)), treasury
                    )
                )
            )
        );

        // ── Mine + deploy FansHook ──────────────────────────────────────────────
        bytes memory args = abi.encode(
            IPoolManager(address(manager)), address(this), address(fans), IFeeDistributor(address(fees)), uint256(150)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(FansHook).creationCode, args);
        hook = new FansHook{salt: salt}(
            IPoolManager(address(manager)), address(this), address(fans), IFeeDistributor(address(fees)), 150
        );
        assertEq(address(hook), hookAddr, "mined hook address mismatch");

        // ── Initialize the canonical ETH/$FANS pool ─────────────────────────────
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(fans)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // ── Phase-2: the vault owns the single full-range position ──────────────
        vault = new FansLPVault(IPoolManager(address(manager)), poolKey);
        router = new FansV4Router(IPoolManager(address(manager)), poolKey);

        // ── LP farm: stake FANS-LP, earn $FANS, dripped from the FeeDistributor ──
        StakingManager stakingImpl = new StakingManager();
        lpFarm = StakingManager(
            address(
                new ERC1967Proxy(
                    address(stakingImpl),
                    abi.encodeWithSelector(
                        StakingManager.initialize.selector,
                        address(this),
                        IERC20(address(vault)), // stake FANS-LP (the vault ERC-20)
                        IERC20(address(fans)), // earn $FANS
                        address(fees)
                    )
                )
            )
        );
        fees.setStakingManager(address(lpFarm));

        // ── Fund actors ─────────────────────────────────────────────────────────
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        fans.transfer(alice, 100_000 ether);
        fans.transfer(bob, 100_000 ether);
        fans.transfer(carol, 100_000 ether);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 ethIn, uint256 fansIn) internal returns (uint256 shares) {
        vm.startPrank(who);
        fans.approve(address(vault), fansIn);
        shares = vault.deposit{value: ethIn}(fansIn);
        vm.stopPrank();
    }

    // ── 1. first deposit mints shares == L, reserves reflect it ─────────────────
    function test_FirstDepositMintsSharesAndGrowsPosition() public {
        assertEq(vault.positionLiquidity(), 0);
        assertEq(vault.totalSupply(), 0);

        uint256 shares = _deposit(alice, 100 ether, 100 ether);

        uint128 liq = vault.positionLiquidity();
        assertGt(liq, 0, "no liquidity added");
        assertEq(shares, uint256(liq), "first deposit shares != L");
        assertEq(vault.totalSupply(), shares, "supply mismatch");
        assertEq(vault.balanceOf(alice), shares, "alice not credited");

        // Pool's stored liquidity for our range equals the vault's tracked value.
        assertEq(manager.getLiquidity(poolKey.toId()), liq, "pool liquidity mismatch");

        // Reserves reflect ~100/100 at price 1:1.
        (uint256 ethR, uint256 fansR) = vault.getReserves();
        assertApproxEqRel(ethR, 100 ether, 1e15, "eth reserve off");
        assertApproxEqRel(fansR, 100 ether, 1e15, "fans reserve off");
    }

    // ── 2. second depositor gets proportional shares ────────────────────────────
    function test_SecondDepositorGetsProportionalShares() public {
        uint256 aliceShares = _deposit(alice, 100 ether, 100 ether);
        uint128 liqAfter1 = vault.positionLiquidity();

        // Bob deposits half of Alice's size -> ~half the shares.
        uint256 bobShares = _deposit(bob, 50 ether, 50 ether);
        uint128 liqAfter2 = vault.positionLiquidity();

        assertGt(bobShares, 0, "bob got no shares");
        assertApproxEqRel(bobShares, aliceShares / 2, 1e15, "bob shares not ~half");
        assertEq(vault.totalSupply(), aliceShares + bobShares, "supply != sum");
        assertEq(uint256(liqAfter2 - liqAfter1), uint256(vault.positionLiquidity()) - uint256(liqAfter1)); // sanity
        assertGt(liqAfter2, liqAfter1, "position did not grow");

        // Share price invariant: totalSupply == positionLiquidity (no fees accrue to the position).
        assertEq(vault.totalSupply(), vault.positionLiquidity(), "share/liquidity invariant broken");
    }

    // ── 3. withdraw burns shares + returns ~proportional ETH + $FANS ─────────────
    function test_WithdrawReturnsProportionalAssets() public {
        _deposit(alice, 100 ether, 100 ether);
        uint256 aliceShares = vault.balanceOf(alice);

        uint256 ethBefore = alice.balance;
        uint256 fansBefore = fans.balanceOf(alice);

        // Withdraw half.
        uint256 half = aliceShares / 2;
        vm.prank(alice);
        (uint256 ethOut, uint256 fansOut) = vault.withdraw(half);

        assertApproxEqRel(ethOut, 50 ether, 1e15, "eth out not ~half");
        assertApproxEqRel(fansOut, 50 ether, 1e15, "fans out not ~half");
        assertEq(alice.balance - ethBefore, ethOut, "eth not delivered");
        assertEq(fans.balanceOf(alice) - fansBefore, fansOut, "fans not delivered");
        assertEq(vault.balanceOf(alice), aliceShares - half, "shares not burned");

        // Remaining position ~ half.
        assertApproxEqRel(uint256(vault.positionLiquidity()), aliceShares - half, 1e12, "remaining liquidity off");

        // Full exit of the remainder.
        uint256 remaining = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(remaining);
        assertEq(vault.balanceOf(alice), 0, "alice still holds shares");
        assertEq(vault.positionLiquidity(), 0, "position not emptied");
    }

    // ── 4. a swap through FansV4Router trades against the vault's liquidity ──────
    function test_SwapTradesAgainstVaultLiquidity() public {
        _deposit(alice, 500 ether, 500 ether);
        uint128 liqBefore = vault.positionLiquidity();
        assertGt(liqBefore, 0);

        uint256 forwardedBefore = hook.totalFeesForwarded();

        vm.prank(carol);
        uint256 out = router.swapExactEthForFans{value: 10 ether}(0);

        assertGt(out, 0, "no FANS out from vault liquidity");
        assertEq(fans.balanceOf(carol), 100_000 ether + out, "carol FANS mismatch");

        // The trade moved against the vault's position (liquidity constant, price moved).
        assertEq(vault.positionLiquidity(), liqBefore, "liquidity should be unchanged by a swap");
        assertGt(hook.totalFeesForwarded(), forwardedBefore, "hook took no fee");

        // Price moved: selling ETH (token0) for FANS (token1) pushes sqrtPrice down.
        assertLt(vault.sqrtPriceX96(), SQRT_PRICE_1_1, "price did not move");
    }

    // ── 5. end-to-end: deposit -> stake FANS-LP -> swaps drip farm -> earn/claim ─
    function test_EndToEnd_LpFarmDripsToStaker() public {
        // Bob provides liquidity and receives FANS-LP.
        uint256 bobShares = _deposit(bob, 500 ether, 500 ether);
        assertGt(bobShares, 0);

        // Bob stakes his FANS-LP in the LP farm.
        vm.startPrank(bob);
        vault.approve(address(lpFarm), bobShares);
        lpFarm.stake(bobShares);
        vm.stopPrank();
        assertEq(lpFarm.balanceOf(bob), bobShares, "stake not recorded");
        assertEq(vault.balanceOf(bob), 0, "FANS-LP not transferred to farm");

        uint256 treasuryBefore = fans.balanceOf(treasury);

        // Swaps generate hook fees -> FeeDistributor -> LP farm drip.
        vm.startPrank(carol);
        fans.approve(address(router), type(uint256).max);
        router.swapExactEthForFans{value: 25 ether}(0);
        router.swapExactFansForEth(20_000 ether, 0);
        vm.stopPrank();

        assertGt(fans.balanceOf(treasury), treasuryBefore, "treasury share missing");
        assertGt(lpFarm.rewardRate(), 0, "farm drip not started");

        // earned() grows over time.
        uint256 earnedBefore = lpFarm.earned(bob);
        vm.warp(block.timestamp + 1 days);
        uint256 earnedAfter = lpFarm.earned(bob);
        assertGt(earnedAfter, earnedBefore, "LP staker earned did not grow");

        // Bob claims the dripped $FANS.
        uint256 balBefore = fans.balanceOf(bob);
        vm.prank(bob);
        lpFarm.getReward();
        assertGt(fans.balanceOf(bob), balBefore, "reward not claimable");

        // Bob can still exit his LP stake and withdraw underlying assets.
        vm.startPrank(bob);
        lpFarm.withdraw(bobShares);
        (uint256 ethOut, uint256 fansOut) = vault.withdraw(bobShares);
        vm.stopPrank();
        assertGt(ethOut, 0, "no eth on final withdraw");
        assertGt(fansOut, 0, "no fans on final withdraw");
    }

    // ── previewDeposit matches actual first deposit ─────────────────────────────
    function test_PreviewDepositMatches() public {
        uint256 preview = vault.previewDeposit(100 ether, 100 ether);
        uint256 actual = _deposit(alice, 100 ether, 100 ether);
        assertEq(preview, actual, "previewDeposit != actual shares");
    }
}
