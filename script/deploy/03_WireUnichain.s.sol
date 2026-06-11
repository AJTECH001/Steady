// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {SteadyExecutor} from "steady/execution/SteadyExecutor.sol";

/// @notice Destination-chain wiring: tell the executor which reactive RVM id may trigger it.
/// @dev Run on the destination chain (Unichain Sepolia) after 02_DeployReactive. In the standard
///      Reactive callback model the proxy injects the reactive contract's RVM id — the address that
///      deployed ReactiveSteady — as the callback's leading argument, so the executor authorizes the
///      deployer address (not the ReactiveSteady contract address). Override with REACTIVE_RVM_ID.
contract WireUnichain is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address executor = vm.envAddress("EXECUTOR");
        address rvmId = vm.envOr("REACTIVE_RVM_ID", vm.addr(pk));

        vm.startBroadcast(pk);
        SteadyExecutor(payable(executor)).setReactiveSender(rvmId);
        vm.stopBroadcast();

        console2.log("Executor reactiveSender set to (reactive RVM id):", rvmId);
    }
}
