// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";
import {SteadyVault} from "steady/core/SteadyVault.sol";

/// @notice Demo: create a recurring savings plan and fund it (destination chain).
/// @dev After the interval elapses, run 06_Poke to emit PlanDue — ReactiveSteady then triggers
///      the cross-chain execution automatically.
contract Demo is Script {
    uint256 constant AMOUNT_IN = 100e18; // buy 100 sUSD worth each execution
    uint64 constant INTERVAL = 60; // 60s for a fast demo
    uint32 constant EXECUTIONS = 5;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        SteadyPlanRegistry registry = SteadyPlanRegistry(vm.envAddress("REGISTRY"));
        SteadyVault vault = SteadyVault(vm.envAddress("VAULT"));
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");

        vm.startBroadcast(pk);
        uint256 planId = registry.createPlan(token0, token1, AMOUNT_IN, INTERVAL, EXECUTIONS);

        IERC20(token0).approve(address(vault), AMOUNT_IN * EXECUTIONS);
        vault.deposit(planId, AMOUNT_IN * EXECUTIONS);
        vm.stopBroadcast();

        console2.log("PLAN_ID              :", planId);
        console2.log("Funded               :", AMOUNT_IN * EXECUTIONS);
        console2.log("Next: wait", INTERVAL, "s then run 06_Poke with PLAN_ID");
    }
}
