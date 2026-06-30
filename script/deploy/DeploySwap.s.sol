// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FansSwap} from "../../src/swap/FansSwap.sol";

/// @title DeploySwap
/// @notice Deploys FansSwap (ETH <-> $FANS AMM) behind an ERC1967 proxy (impl + ERC1967Proxy + initialize).
contract DeploySwap is Script {
    struct SwapResult {
        address fansSwapImpl;
        address fansSwap;
    }

    function deploySwap(address fans) internal returns (SwapResult memory result) {
        FansSwap swapImpl = new FansSwap();
        result.fansSwapImpl = address(swapImpl);
        console.log("FansSwap impl:", result.fansSwapImpl);

        bytes memory initData = abi.encodeWithSelector(FansSwap.initialize.selector, fans);
        result.fansSwap = address(new ERC1967Proxy(address(swapImpl), initData));
        console.log("FansSwap proxy:", result.fansSwap);
    }

    /// @dev Standalone entry point — hardcode params below before running.
    function run() external virtual {
        address fans = address(0xdead01); // TODO: replace with $FANS token address

        vm.startBroadcast();
        deploySwap(fans);
        vm.stopBroadcast();
    }
}
