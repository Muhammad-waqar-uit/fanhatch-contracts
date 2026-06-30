// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingManager} from "../../src/staking/StakingManager.sol";

/// @title DeployStaking
/// @notice Deploys the two "farm" instances behind ERC1967 proxies on a single shared impl:
///         - stakingFans: stake $FANS, earn $FANS dripped from the FeeDistributor (club trade fees).
///         - stakingLp:   stake FansSwap LP tokens, earn $FANS (rewards funded by the owner).
/// @dev One StakingManager UUPS impl is shared by both proxies (impl + 2x ERC1967Proxy + initialize).
contract DeployStaking is Script {
    struct StakingResult {
        address stakingImpl;
        address stakingFans;
        address stakingLp;
    }

    /// @param owner_         protocol owner (also the LP farm's rewards distributor)
    /// @param fans           $FANS token (stake + reward for the $FANS farm; reward for the LP farm)
    /// @param fansSwap       FansSwap LP token (stake token for the LP farm)
    /// @param feeDistributor FeeDistributor (rewards distributor for the $FANS farm)
    function deployStaking(address owner_, address fans, address fansSwap, address feeDistributor)
        internal
        returns (StakingResult memory result)
    {
        StakingManager stakingImpl = new StakingManager();
        result.stakingImpl = address(stakingImpl);
        console.log("StakingManager impl:", result.stakingImpl);

        // $FANS farm: stake $FANS, reward $FANS, dripped by the FeeDistributor.
        bytes memory fansInit =
            abi.encodeWithSelector(StakingManager.initialize.selector, owner_, fans, fans, feeDistributor);
        result.stakingFans = address(new ERC1967Proxy(address(stakingImpl), fansInit));
        console.log("StakingManager (stakingFans) proxy:", result.stakingFans);

        // LP farm: stake FansSwap LP, reward $FANS, funded by the owner.
        bytes memory lpInit =
            abi.encodeWithSelector(StakingManager.initialize.selector, owner_, fansSwap, fans, owner_);
        result.stakingLp = address(new ERC1967Proxy(address(stakingImpl), lpInit));
        console.log("StakingManager (stakingLp) proxy:", result.stakingLp);
    }

    /// @dev Standalone entry point — hardcode params below before running.
    function run() external virtual {
        address owner_ = msg.sender;
        address fans = address(0xdead01); // TODO: replace with $FANS token address
        address fansSwap = address(0xdead02); // TODO: replace with FansSwap LP token address
        address feeDistributor = address(0xdead03); // TODO: replace with FeeDistributor address

        vm.startBroadcast();
        deployStaking(owner_, fans, fansSwap, feeDistributor);
        vm.stopBroadcast();
    }
}
