// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlatformToken} from "../../src/token/PlatformToken.sol";
import {FeeDistributor} from "../../src/fees/FeeDistributor.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";
import {IFeeDistributor} from "../../src/interfaces/IFansInterfaces.sol";
import {FansHook} from "../../src/swap/FansHook.sol";
import {FansV4Router} from "../../src/swap/FansV4Router.sol";

/// @title FansV4HookTest
/// @notice Phase-1 v4 harness: real PoolManager + our $FANS/FeeDistributor/StakingManager +
///         CREATE2-mined FansHook on the ETH/$FANS pool. Exercises exact-in (both directions,
///         through FansV4Router) and exact-out swaps, asserting the hook captured the fee in
///         $FANS, it reached the FeeDistributor, and it dripped to the StakingManager.
contract FansV4HookTest is Test, Deployers {
    int24 constant TICK_SPACING = 60;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PlatformToken fans;
    FeeDistributor fees;
    StakingManager stakingFans;
    FansHook hook;
    FansV4Router router;
    PoolKey poolKey;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); // ETH buyer
    address bob = makeAddr("bob"); // staker/farmer
    address carol = makeAddr("carol"); // FANS seller

    function setUp() public {
        // v4-core PoolManager + test routers (manager, swapRouter, modifyLiquidityRouter).
        deployFreshManagerAndRouters();

        // ── Our system (UUPS proxies), owned by this test contract ──────────────
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

        StakingManager stakingImpl = new StakingManager();
        stakingFans = StakingManager(
            address(
                new ERC1967Proxy(
                    address(stakingImpl),
                    abi.encodeWithSelector(
                        StakingManager.initialize.selector,
                        address(this),
                        IERC20(address(fans)), // stake $FANS
                        IERC20(address(fans)), // earn $FANS
                        address(fees)
                    )
                )
            )
        );
        // Wire the farmer-share drip: FeeDistributor -> StakingManager.
        fees.setStakingManager(address(stakingFans));

        // ── Mine + deploy FansHook at a flag-encoding address (CREATE2) ─────────
        bytes memory args = abi.encode(
            IPoolManager(address(manager)), address(this), address(fans), IFeeDistributor(address(fees)), uint256(150)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(FansHook).creationCode, args);
        hook = new FansHook{salt: salt}(
            IPoolManager(address(manager)), address(this), address(fans), IFeeDistributor(address(fees)), 150
        );
        assertEq(address(hook), hookAddr, "mined hook address mismatch");

        // ── Initialize the canonical ETH/$FANS pool (this == authorizedInitializer) ─
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(fans)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // ── Seed full-range liquidity (≈100 ETH / 100 FANS at 1:1) ──────────────
        vm.deal(address(this), 10_000 ether);
        fans.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 5_000 ether}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(100 ether),
                salt: bytes32(0)
            }),
            ""
        );

        router = new FansV4Router(IPoolManager(address(manager)), poolKey);

        // ── Fund actors ─────────────────────────────────────────────────────────
        vm.deal(alice, 100 ether);
        fans.transfer(bob, 1_000 ether);
        fans.transfer(carol, 1_000 ether);

        // Bob stakes in the $FANS farm so a drip has a recipient.
        vm.startPrank(bob);
        fans.approve(address(stakingFans), type(uint256).max);
        stakingFans.stake(1_000 ether);
        vm.stopPrank();
    }

    // ── exact-in ETH -> $FANS (afterSwap fee path) + full drip assertion ────────
    function test_ExactInEthForFans_capturesFeeAndDripsToStaking() public {
        uint256 treasuryBefore = fans.balanceOf(treasury);

        vm.prank(alice);
        uint256 out = router.swapExactEthForFans{value: 10 ether}(0);

        assertGt(out, 0, "no FANS out");
        assertEq(fans.balanceOf(alice), out, "alice FANS mismatch");

        // Hook captured a $FANS fee and forwarded it.
        uint256 forwarded = hook.totalFeesForwarded();
        assertGt(forwarded, 0, "no fee forwarded");

        // Fee ~= 1.5% of gross output. Gross = out + fee ; check within tolerance.
        uint256 gross = out + forwarded;
        assertApproxEqRel(forwarded, (gross * 150) / 10_000, 1e15, "fee != ~1.5%");

        // Reached FeeDistributor: treasury (70%) + staking drip (30%).
        assertGt(fans.balanceOf(treasury), treasuryBefore, "treasury share missing");
        assertGt(stakingFans.rewardRate(), 0, "drip not started");

        // Dripped to StakingManager: earned() grows over time.
        uint256 earnedBefore = stakingFans.earned(bob);
        vm.warp(block.timestamp + 1 days);
        uint256 earnedAfter = stakingFans.earned(bob);
        assertGt(earnedAfter, earnedBefore, "staking earned did not grow");

        // Farmer can actually claim the dripped $FANS.
        uint256 balBefore = fans.balanceOf(bob);
        vm.prank(bob);
        stakingFans.getReward();
        assertGt(fans.balanceOf(bob), balBefore, "reward not claimable");
    }

    // ── exact-in $FANS -> ETH (beforeSwap fee path, fee on input) ───────────────
    function test_ExactInFansForEth_capturesFee() public {
        uint256 forwardedBefore = hook.totalFeesForwarded();

        vm.startPrank(carol);
        fans.approve(address(router), type(uint256).max);
        uint256 ethOut = router.swapExactFansForEth(100 ether, 0);
        vm.stopPrank();

        assertGt(ethOut, 0, "no ETH out");
        assertEq(carol.balance, ethOut, "carol ETH mismatch");
        assertGt(hook.totalFeesForwarded(), forwardedBefore, "no fee on sell");
        assertGt(stakingFans.rewardRate(), 0, "sell drip not started");
    }

    // ── exact-out ETH -> $FANS via the core swap router (beforeSwap on output) ───
    function test_ExactOut_capturesFee() public {
        uint256 forwardedBefore = hook.totalFeesForwarded();

        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: 100 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true, // ETH in, exact FANS out
                amountSpecified: int256(5 ether), // positive => exact-output
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            st,
            ""
        );

        assertGt(hook.totalFeesForwarded(), forwardedBefore, "no fee on exact-out");
    }

    // ── beforeInitialize guard: only the authorized deployer may create pools ───
    function test_ForeignPoolInitializationReverts() public {
        PoolKey memory foreign = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(fans)),
            fee: 0,
            tickSpacing: 120, // different -> new poolId
            hooks: IHooks(address(hook))
        });
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(foreign, SQRT_PRICE_1_1);
    }

    // ── configurable fee ────────────────────────────────────────────────────────
    function test_FeeIsConfigurable() public {
        assertEq(hook.feeBps(), 150);
        hook.setFeeBps(50); // 0.5%
        assertEq(hook.feeBps(), 50);

        vm.prank(alice);
        uint256 out = router.swapExactEthForFans{value: 10 ether}(0);
        uint256 gross = out + hook.totalFeesForwarded();
        assertApproxEqRel(hook.totalFeesForwarded(), (gross * 50) / 10_000, 1e15, "fee != ~0.5%");
    }
}
