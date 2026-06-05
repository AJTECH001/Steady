// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {SteadyExecutor} from "steady/execution/SteadyExecutor.sol";

/// @notice Destination-chain wiring: tell the executor which ReactiveSteady contract may trigger it.
/// @dev Run on the destination chain (Unichain Sepolia) after 02_DeployReactive.
contract WireUnichain is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address executor = vm.envAddress("EXECUTOR");
        address reactive = vm.envAddress("REACTIVE_STEADY");

        vm.startBroadcast(pk);
        SteadyExecutor(payable(executor)).setReactiveSender(reactive);
        vm.stopBroadcast();

        console2.log("Executor reactiveSender set to:", reactive);
    }
}
