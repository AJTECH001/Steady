// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";

/// @notice Emit PlanDue for a due plan (destination chain). ReactiveSteady reacts to this event
///         and posts the cross-chain callback that runs the swap. Reverts if the plan is not due.
contract Poke is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        SteadyPlanRegistry registry = SteadyPlanRegistry(vm.envAddress("REGISTRY"));
        uint256 planId = vm.envUint("PLAN_ID");

        vm.startBroadcast(pk);
        registry.poke(planId);
        vm.stopBroadcast();

        console2.log("Poked plan, PlanDue emitted:", planId);
    }
}
