// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";

import {ReactiveSteady} from "steady/reactive/ReactiveSteady.sol";
import {ChainConfig} from "../config/ChainConfig.sol";

/// @notice Deploys ReactiveSteady on the Reactive Network (e.g. Lasna testnet, chain 5318007).
/// @dev Run with the Reactive RPC. Reads the registry + destination chain from env (output of
///      01_DeploySteady). The executor is wired afterwards by 04_WireReactive.
contract DeployReactive is Script {
    /// @dev REACT funding sent to the contract at construction (covers subscription + callbacks).
    ///      Override via the REACTIVE_FUND env var (wei); defaults to 0.05 REACT.
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address registry = vm.envAddress("REGISTRY");
        uint256 destChainId = vm.envUint("DESTINATION_CHAIN_ID");
        uint256 fund = vm.envOr("REACTIVE_FUND", uint256(0.05 ether));

        vm.startBroadcast(pk);
        // origin == destination chain: the registry emits PlanDue on the destination chain, and the
        // callback executes there too (trigger-only cross-chain; funds stay native). Fund the
        // contract with REACT at construction so its constructor subscription registers.
        ReactiveSteady reactive = new ReactiveSteady{value: fund}(
            destChainId, registry, ChainConfig.planDueTopic0(), destChainId, deployer
        );
        vm.stopBroadcast();

        console2.log("REACTIVE_STEADY      :", address(reactive));
    }
}
