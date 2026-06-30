// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DeployToken} from "./DeployToken.s.sol";
import {DeployFees} from "./DeployFees.s.sol";
import {DeployFactory} from "./DeployFactory.s.sol";
import {DeployGovernance} from "./DeployGovernance.s.sol";
import {DeploySwap} from "./DeploySwap.s.sol";
import {DeployStaking} from "./DeployStaking.s.sol";
import {FeeDistributor} from "../../src/fees/FeeDistributor.sol";

/// @title DeployAll
/// @notice Deploys the entire Fans.tech system in dependency order in one broadcast,
///         and exports addresses to deployments/<network>/addresses.json.
/// @dev Dependency order:
///      1. PlatformToken ($FANS)
///      2. FeeDistributor      (needs $FANS, treasury)
///      3. ClubFactory         (needs $FANS, FeeDistributor; deploys ClubKey beacon impl)
///      4. GovernanceModule    (needs ClubFactory)
///      5. FansSwap            (needs $FANS)
///      6. StakingManager farms (need $FANS, FansSwap LP, FeeDistributor)
contract DeployAll is
    Script,
    DeployToken,
    DeployFees,
    DeployFactory,
    DeployGovernance,
    DeploySwap,
    DeployStaking
{
    using stdJson for string;

    // ═══════════════════════════════════════════════════════════════════════════
    //                  CONFIG — adjust before deploying
    // ═══════════════════════════════════════════════════════════════════════════

    string constant TOKEN_NAME = "Fans.tech";
    string constant TOKEN_SYMBOL = "FANS";
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether; // minted to owner on init

    // Output network folder under deployments/. Override with DEPLOY_NETWORK env if set.
    string constant DEFAULT_NETWORK = "base";

    struct Deployment {
        address fansImpl;
        address fans;
        address feeDistributorImpl;
        address feeDistributor;
        address clubKeyImpl;
        address clubFactoryImpl;
        address clubFactory;
        address governanceModuleImpl;
        address governanceModule;
        address fansSwapImpl;
        address fansSwap;
        address stakingImpl;
        address stakingFans;
        address stakingLp;
    }

    function run()
        external
        override(DeployToken, DeployFees, DeployFactory, DeployGovernance, DeploySwap, DeployStaking)
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY_1");
        address owner_ = vm.addr(deployerKey);
        address treasury = vm.envAddress("FANS_TREASURY");

        console.log("Deployer / Owner:", owner_);
        console.log("Treasury:", treasury);

        vm.startBroadcast(deployerKey);
        Deployment memory d = _deployAll(owner_, treasury);
        vm.stopBroadcast();

        console.log("=== Export ===");
        _exportDeployment(d);
        console.log("=== Deployment complete ===");
    }

    function _deployAll(address owner_, address treasury) internal returns (Deployment memory d) {
        // 1. PlatformToken ($FANS)
        console.log("=== Phase 1: PlatformToken ===");
        TokenResult memory token = deployToken(TOKEN_NAME, TOKEN_SYMBOL, owner_, INITIAL_SUPPLY);
        d.fansImpl = token.tokenImpl;
        d.fans = token.token;

        // 2. FeeDistributor
        console.log("=== Phase 2: FeeDistributor ===");
        FeesResult memory fees = deployFees(owner_, d.fans, treasury);
        d.feeDistributorImpl = fees.feeDistributorImpl;
        d.feeDistributor = fees.feeDistributor;

        // 3. ClubFactory (+ ClubKey beacon impl)
        console.log("=== Phase 3: ClubFactory ===");
        FactoryResult memory factory = deployFactory(owner_, d.fans, d.feeDistributor);
        d.clubKeyImpl = factory.clubKeyImpl;
        d.clubFactoryImpl = factory.clubFactoryImpl;
        d.clubFactory = factory.clubFactory;

        // 4. GovernanceModule
        console.log("=== Phase 4: GovernanceModule ===");
        GovernanceResult memory gov = deployGovernance(owner_, d.clubFactory);
        d.governanceModuleImpl = gov.governanceModuleImpl;
        d.governanceModule = gov.governanceModule;

        // 5. FansSwap
        console.log("=== Phase 5: FansSwap ===");
        SwapResult memory swap = deploySwap(d.fans);
        d.fansSwapImpl = swap.fansSwapImpl;
        d.fansSwap = swap.fansSwap;

        // 6. StakingManager farms ($FANS farm + LP farm)
        console.log("=== Phase 6: StakingManager farms ===");
        StakingResult memory staking = deployStaking(owner_, d.fans, d.fansSwap, d.feeDistributor);
        d.stakingImpl = staking.stakingImpl;
        d.stakingFans = staking.stakingFans;
        d.stakingLp = staking.stakingLp;

        // Wire the club-fee drip into the $FANS farm so the farmer share flows to stakers.
        FeeDistributor(d.feeDistributor).setStakingManager(d.stakingFans);
        console.log("FeeDistributor.setStakingManager ->", d.stakingFans);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        JSON EXPORT
    // ═══════════════════════════════════════════════════════════════════════════

    function _exportDeployment(Deployment memory d) internal {
        string memory network = vm.envOr("DEPLOY_NETWORK", DEFAULT_NETWORK);
        string memory root = vm.projectRoot();
        string memory folder = string.concat(root, "/deployments/", network, "/");
        vm.createDir(folder, true);

        string memory json = "deployment";

        json.serialize("fansImpl", d.fansImpl);
        json.serialize("fans", d.fans);
        json.serialize("feeDistributorImpl", d.feeDistributorImpl);
        json.serialize("feeDistributor", d.feeDistributor);
        json.serialize("clubKeyImpl", d.clubKeyImpl);
        json.serialize("clubFactoryImpl", d.clubFactoryImpl);
        json.serialize("clubFactory", d.clubFactory);
        json.serialize("governanceModuleImpl", d.governanceModuleImpl);
        json.serialize("governanceModule", d.governanceModule);
        json.serialize("fansSwapImpl", d.fansSwapImpl);
        json.serialize("fansSwap", d.fansSwap);
        json.serialize("stakingImpl", d.stakingImpl);
        json.serialize("stakingFans", d.stakingFans);
        string memory finalJson = json.serialize("stakingLp", d.stakingLp);

        string memory filePath = string.concat(folder, "addresses.json");
        vm.writeJson(finalJson, filePath);
        console.log("Addresses written to:", filePath);
    }
}
