// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GovernanceModule} from "../../src/governance/GovernanceModule.sol";

/// @title DeployGovernance
/// @notice Deploys GovernanceModule as a UUPS proxy (impl + ERC1967Proxy + initialize).
contract DeployGovernance is Script {
    struct GovernanceResult {
        address governanceModuleImpl;
        address governanceModule;
    }

    function deployGovernance(address owner_, address factory) internal returns (GovernanceResult memory result) {
        GovernanceModule govImpl = new GovernanceModule();
        result.governanceModuleImpl = address(govImpl);
        console.log("GovernanceModule impl:", result.governanceModuleImpl);

        bytes memory initData = abi.encodeWithSelector(GovernanceModule.initialize.selector, owner_, factory);
        result.governanceModule = address(new ERC1967Proxy(address(govImpl), initData));
        console.log("GovernanceModule proxy:", result.governanceModule);
    }

    /// @dev Standalone entry point — hardcode params below before running.
    function run() external virtual {
        address owner_ = msg.sender;
        address factory = address(0xdead01); // TODO: replace with ClubFactory address

        vm.startBroadcast();
        deployGovernance(owner_, factory);
        vm.stopBroadcast();
    }
}
