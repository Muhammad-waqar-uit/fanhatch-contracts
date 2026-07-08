// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlatformToken} from "../../src/token/PlatformToken.sol";
import {FeeDistributor} from "../../src/fees/FeeDistributor.sol";
import {ClubFactory} from "../../src/factory/ClubFactory.sol";
import {ClubKey} from "../../src/club/ClubKey.sol";
import {GovernanceModule} from "../../src/governance/GovernanceModule.sol";
import {FansSwap} from "../../src/swap/FansSwap.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";
import {CurveType, IClubFactory, IFeeDistributor} from "../../src/interfaces/IFansInterfaces.sol";

/// @title FansBase
/// @notice Shared harness: deploys the full Fanhatch system behind proxies and seeds balances.
///         Every test suite extends this so the wiring lives in one place.
contract FansBase is Test {
    PlatformToken public fans;
    FeeDistributor public fees;
    ClubFactory public factory;
    GovernanceModule public gov;
    FansSwap public swap;
    StakingManager public stakingFans; // "Farm": stake $FANS, earn $FANS from fees
    StakingManager public stakingLp; // LP farm: stake FansSwap LP token, earn $FANS
    address public clubKeyImpl;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant SEED = 1_000_000 ether;

    function setUp() public virtual {
        vm.startPrank(owner);

        // $FANS token (UUPS proxy)
        PlatformToken tokenImpl = new PlatformToken();
        fans = PlatformToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeWithSelector(PlatformToken.initialize.selector, "Fans Token", "FANS", owner, 0)
                )
            )
        );

        // FeeDistributor (UUPS proxy)
        FeeDistributor feesImpl = new FeeDistributor();
        fees = FeeDistributor(
            address(
                new ERC1967Proxy(
                    address(feesImpl),
                    abi.encodeWithSelector(FeeDistributor.initialize.selector, owner, IERC20(address(fans)), treasury)
                )
            )
        );

        // ClubFactory (UUPS proxy) + ClubKey beacon implementation
        clubKeyImpl = address(new ClubKey());
        ClubFactory factoryImpl = new ClubFactory();
        factory = ClubFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeWithSelector(
                        ClubFactory.initialize.selector,
                        owner,
                        clubKeyImpl,
                        IERC20(address(fans)),
                        IFeeDistributor(address(fees))
                    )
                )
            )
        );

        // GovernanceModule (UUPS proxy)
        GovernanceModule govImpl = new GovernanceModule();
        gov = GovernanceModule(
            address(
                new ERC1967Proxy(
                    address(govImpl),
                    abi.encodeWithSelector(GovernanceModule.initialize.selector, owner, IClubFactory(address(factory)))
                )
            )
        );

        // FansSwap (UUPS-less, just proxy for upgrade parity)
        FansSwap swapImpl = new FansSwap();
        swap = FansSwap(
            address(
                new ERC1967Proxy(
                    address(swapImpl), abi.encodeWithSelector(FansSwap.initialize.selector, IERC20(address(fans)))
                )
            )
        );

        // Staking farms (UUPS proxies). fees->staking wiring is left OFF by default so the
        // FeeDistributor fallback (farmerRewards) stays testable; opt in per-test via
        // fees.setStakingManager(address(stakingFans)).
        StakingManager stakingImpl = new StakingManager();
        stakingFans = StakingManager(
            address(
                new ERC1967Proxy(
                    address(stakingImpl),
                    abi.encodeWithSelector(
                        StakingManager.initialize.selector,
                        owner,
                        IERC20(address(fans)), // stake $FANS
                        IERC20(address(fans)), // earn $FANS
                        address(fees)
                    )
                )
            )
        );
        stakingLp = StakingManager(
            address(
                new ERC1967Proxy(
                    address(stakingImpl),
                    abi.encodeWithSelector(
                        StakingManager.initialize.selector,
                        owner,
                        IERC20(address(swap)), // stake FansSwap LP token
                        IERC20(address(fans)), // earn $FANS
                        owner
                    )
                )
            )
        );

        // Seed $FANS to the usual suspects.
        fans.mint(creator, SEED);
        fans.mint(alice, SEED);
        fans.mint(bob, SEED);
        vm.stopPrank();
    }

    /// @notice Create a club as `creator` and return its id + ClubKey.
    function _createClub(CurveType curveType) internal returns (uint256 clubId, ClubKey key) {
        vm.prank(creator);
        (uint256 id, address keyAddr) = factory.createClub("Test Club", "$TEST", "ipfs://avatar", curveType);
        return (id, ClubKey(keyAddr));
    }

    /// @notice Buy `amount` keys as `who`, approving enough $FANS first.
    function _buy(ClubKey key, address who, uint256 amount) internal {
        vm.startPrank(who);
        fans.approve(address(key), type(uint256).max);
        key.buyKeys(amount, type(uint256).max);
        vm.stopPrank();
    }
}
