// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {ReactiveSteady} from "steady/reactive/ReactiveSteady.sol";

/// @notice Reactive-chain wiring: set the destination executor as the callback recipient.
/// @dev Run on the Reactive RPC after 01_DeploySteady (executor) and 02_DeployReactive.
contract WireReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address reactive = vm.envAddress("REACTIVE_STEADY");
        address executor = vm.envAddress("EXECUTOR");

        vm.startBroadcast(pk);
        ReactiveSteady(payable(reactive)).setExecutor(executor);
        vm.stopBroadcast();

        console2.log("ReactiveSteady executor set to:", executor);
    }
}
