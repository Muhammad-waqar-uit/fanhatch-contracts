// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";
import {FeeDistributor} from "../../src/fees/FeeDistributor.sol";

/// @title DeployLpFarm
/// @notice Phase-3 wiring (Option 1): create a NEW LP {StakingManager} whose `stakingToken` is the
///         already-deployed {FansLPVault} (ERC-20 FANS-LP), then repoint the existing {FeeDistributor}
///         at it. After this, BOTH v4 swap fees AND club-key trade fees drip $FANS to FANS-LP stakers.
/// @dev The v4 pool + FansHook + FansLPVault are already deployed. The FeeDistributor
///      (0xfb8d…e10E) is repointed via `setStakingManager` (owner-only; broadcaster is the owner).
///      StakingManager is UUPS: deploy an impl (or reuse via STAKING_IMPL) + an ERC1967Proxy, then
///      `initialize(owner, stakingToken=VAULT, rewardToken=FANS, rewardsDistributor=FEE_DISTRIBUTOR)`.
///      `rewardsDuration` is set to 7 days inside `initialize` (not a constructor/initialize arg).
contract DeployLpFarm is Script {
    /// @dev Requires env: VAULT (FansLPVault / FANS-LP), FANS, FEE_DISTRIBUTOR.
    ///      Optional env: STAKING_IMPL (reuse an existing StakingManager UUPS impl instead of deploying one).
    function run() external returns (address stakingLpV4) {
        address vault = vm.envAddress("VAULT");
        address fans = vm.envAddress("FANS");
        address feeDistributor = vm.envAddress("FEE_DISTRIBUTOR");
        // Optional: reuse a previously deployed StakingManager implementation.
        address implOverride = vm.envOr("STAKING_IMPL", address(0));

        vm.startBroadcast();
        address broadcaster = msg.sender;

        // 1. StakingManager implementation (reuse if provided; UUPS impl is stateless & shareable).
        address impl = implOverride;
        if (impl == address(0)) {
            impl = address(new StakingManager());
            console.log("StakingManager impl (deployed):", impl);
        } else {
            console.log("StakingManager impl (reused):", impl);
        }

        // 2. LP farm proxy: stake FANS-LP (VAULT), reward $FANS, dripped by the FeeDistributor.
        //    initialize(owner_, stakingToken_, rewardToken_, rewardsDistributor_)
        bytes memory lpInit = abi.encodeWithSelector(
            StakingManager.initialize.selector,
            broadcaster, // owner_
            IERC20(vault), // stakingToken_  = FansLPVault (FANS-LP)
            IERC20(fans), // rewardToken_   = $FANS
            feeDistributor // rewardsDistributor_ = FeeDistributor (allowed to notifyRewardAmount)
        );
        stakingLpV4 = address(new ERC1967Proxy(impl, lpInit));
        console.log("LP StakingManager (stakingLpV4) proxy:", stakingLpV4);

        // 3. Repoint the existing FeeDistributor at the new LP farm (owner-only; broadcaster is owner).
        FeeDistributor(feeDistributor).setStakingManager(stakingLpV4);
        console.log("FeeDistributor repointed:", feeDistributor, "-> stakingManager:", stakingLpV4);

        vm.stopBroadcast();

        _persist(stakingLpV4);
    }

    /// @dev Best-effort update of deployments/ethereum-sepolia/v4-addresses.json with the new address.
    ///      Falls back to a console.log if the write is not permitted / file is absent.
    function _persist(address stakingLpV4) internal {
        string memory path = "deployments/ethereum-sepolia/v4-addresses.json";
        string memory value = string.concat('"', vm.toString(stakingLpV4), '"');
        try vm.writeJson(value, path, ".stakingLpV4") {
            console.log("Wrote stakingLpV4 to:", path);
        } catch {
            console.log("Could not update JSON; record stakingLpV4 manually:", stakingLpV4);
        }
    }
}
