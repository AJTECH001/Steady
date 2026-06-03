// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";
import {ISteadyPlanRegistry} from "steady/interfaces/ISteadyPlanRegistry.sol";

/// @notice Phase 3: executor-gated advanceSchedule + executor role wiring on the registry.
contract SteadyScheduleAdvanceTest is Test {
    SteadyPlanRegistry registry;

    address admin = makeAddr("admin");
    address owner = makeAddr("owner");
    address executor = makeAddr("executor"); // mock executor (EOA) until Phase 5
    address tokenIn = makeAddr("tokenIn");
    address tokenOut = makeAddr("tokenOut");

    uint64 constant INTERVAL = 7 days;
    uint32 constant EXECUTIONS = 3;

    uint256 planId;

    function setUp() public {
        registry = new SteadyPlanRegistry(admin);
        vm.prank(admin);
        registry.setExecutor(executor);

        vm.prank(owner);
        planId = registry.createPlan(tokenIn, tokenOut, 50e6, INTERVAL, EXECUTIONS);
    }

    function test_setExecutor_onlyOwner() public {
        vm.expectRevert(); // OwnableUnauthorizedAccount
        vm.prank(owner);
        registry.setExecutor(owner);
    }

    function test_setExecutor_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(ISteadyPlanRegistry.InvalidExecutor.selector);
        registry.setExecutor(address(0));
    }

    function test_advance_reverts_forNonExecutor() public {
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(owner);
        vm.expectRevert(ISteadyPlanRegistry.NotExecutor.selector);
        registry.advanceSchedule(planId);
    }

    function test_advance_reverts_whenNotDue() public {
        vm.prank(executor);
        vm.expectRevert(ISteadyPlanRegistry.PlanNotDue.selector);
        registry.advanceSchedule(planId);
    }

    function test_advance_decrementsAndReschedules() public {
        vm.warp(block.timestamp + INTERVAL);
        uint64 expectedNextDue = uint64(block.timestamp) + INTERVAL;

        vm.expectEmit(true, false, false, true);
        emit ISteadyPlanRegistry.PlanAdvanced(planId, expectedNextDue, EXECUTIONS - 1);
        vm.prank(executor);
        registry.advanceSchedule(planId);

        ISteadyPlanRegistry.Plan memory p = registry.getPlan(planId);
        assertEq(p.executionsRemaining, EXECUTIONS - 1);
        assertEq(p.lastExecuted, uint64(block.timestamp));
        assertEq(p.nextDue, expectedNextDue);
        assertFalse(registry.isDue(planId)); // no catch-up burst
    }

    function test_advance_completesPlanOnLastExecution() public {
        for (uint256 i = 0; i < EXECUTIONS - 1; i++) {
            vm.warp(block.timestamp + INTERVAL);
            vm.prank(executor);
            registry.advanceSchedule(planId);
        }

        vm.warp(block.timestamp + INTERVAL);
        vm.expectEmit(true, false, false, false);
        emit ISteadyPlanRegistry.PlanCompleted(planId);
        vm.prank(executor);
        registry.advanceSchedule(planId);

        ISteadyPlanRegistry.Plan memory p = registry.getPlan(planId);
        assertEq(p.executionsRemaining, 0);
        assertEq(uint8(p.status), uint8(ISteadyPlanRegistry.PlanStatus.Completed));
        assertFalse(registry.isDue(planId));
    }

    function test_advance_reverts_afterCompletion() public {
        for (uint256 i = 0; i < EXECUTIONS; i++) {
            vm.warp(block.timestamp + INTERVAL);
            vm.prank(executor);
            registry.advanceSchedule(planId);
        }
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(executor);
        vm.expectRevert(ISteadyPlanRegistry.PlanNotActive.selector);
        registry.advanceSchedule(planId);
    }

    function test_advance_reverts_whenPaused() public {
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(owner);
        registry.pausePlan(planId);
        vm.prank(executor);
        vm.expectRevert(ISteadyPlanRegistry.PlanNotActive.selector);
        registry.advanceSchedule(planId);
    }
}
