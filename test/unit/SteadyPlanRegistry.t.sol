// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";
import {ISteadyPlanRegistry} from "steady/interfaces/ISteadyPlanRegistry.sol";

contract SteadyPlanRegistryTest is Test {
    SteadyPlanRegistry registry;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");
    address tokenIn = makeAddr("tokenIn");
    address tokenOut = makeAddr("tokenOut");

    uint256 constant AMOUNT = 50e6;
    uint64 constant INTERVAL = 7 days;
    uint32 constant EXECUTIONS = 10;

    event PlanCreated(
        uint256 indexed planId,
        address indexed owner,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint64 interval,
        uint32 executions
    );

    function setUp() public {
        registry = new SteadyPlanRegistry(address(this));
    }

    function _create() internal returns (uint256) {
        vm.prank(owner);
        return registry.createPlan(tokenIn, tokenOut, AMOUNT, INTERVAL, EXECUTIONS);
    }

    function test_createPlan_setsFields() public {
        vm.expectEmit(true, true, false, true);
        emit PlanCreated(1, owner, tokenIn, tokenOut, AMOUNT, INTERVAL, EXECUTIONS);
        uint256 id = _create();

        assertEq(id, 1);
        ISteadyPlanRegistry.Plan memory p = registry.getPlan(id);
        assertEq(p.owner, owner);
        assertEq(p.tokenIn, tokenIn);
        assertEq(p.tokenOut, tokenOut);
        assertEq(p.amountIn, AMOUNT);
        assertEq(p.interval, INTERVAL);
        assertEq(p.lastExecuted, 0);
        assertEq(p.nextDue, uint64(block.timestamp) + INTERVAL);
        assertEq(p.executionsRemaining, EXECUTIONS);
        assertEq(uint8(p.status), uint8(ISteadyPlanRegistry.PlanStatus.Active));

        uint256[] memory plans = registry.getUserPlans(owner);
        assertEq(plans.length, 1);
        assertEq(plans[0], 1);
    }

    function test_createPlan_incrementsIds() public {
        assertEq(_create(), 1);
        assertEq(_create(), 2);
    }

    function test_createPlan_reverts_onBadInput() public {
        vm.startPrank(owner);
        vm.expectRevert(ISteadyPlanRegistry.InvalidToken.selector);
        registry.createPlan(address(0), tokenOut, AMOUNT, INTERVAL, EXECUTIONS);

        vm.expectRevert(ISteadyPlanRegistry.InvalidToken.selector);
        registry.createPlan(tokenIn, tokenIn, AMOUNT, INTERVAL, EXECUTIONS);

        vm.expectRevert(ISteadyPlanRegistry.InvalidAmount.selector);
        registry.createPlan(tokenIn, tokenOut, 0, INTERVAL, EXECUTIONS);

        vm.expectRevert(ISteadyPlanRegistry.InvalidInterval.selector);
        registry.createPlan(tokenIn, tokenOut, AMOUNT, 0, EXECUTIONS);

        vm.expectRevert(ISteadyPlanRegistry.InvalidExecutions.selector);
        registry.createPlan(tokenIn, tokenOut, AMOUNT, INTERVAL, 0);
        vm.stopPrank();
    }

    function test_getPlan_reverts_whenMissing() public {
        vm.expectRevert(ISteadyPlanRegistry.PlanDoesNotExist.selector);
        registry.getPlan(999);
    }

    function test_isDue_falseBeforeDue_trueAfter() public {
        uint256 id = _create();
        assertFalse(registry.isDue(id));
        vm.warp(block.timestamp + INTERVAL);
        assertTrue(registry.isDue(id));
    }

    function test_isDue_falseWhenNotActive() public {
        uint256 id = _create();
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(owner);
        registry.pausePlan(id);
        assertFalse(registry.isDue(id));
    }

    function test_pause_resume() public {
        uint256 id = _create();
        vm.prank(owner);
        registry.pausePlan(id);
        assertEq(uint8(registry.getPlan(id).status), uint8(ISteadyPlanRegistry.PlanStatus.Paused));

        vm.prank(owner);
        registry.resumePlan(id);
        assertEq(uint8(registry.getPlan(id).status), uint8(ISteadyPlanRegistry.PlanStatus.Active));
    }

    function test_pause_reverts_whenNotActive() public {
        uint256 id = _create();
        vm.prank(owner);
        registry.pausePlan(id);
        vm.prank(owner);
        vm.expectRevert(ISteadyPlanRegistry.PlanNotActive.selector);
        registry.pausePlan(id);
    }

    function test_resume_reverts_whenNotPaused() public {
        uint256 id = _create();
        vm.prank(owner);
        vm.expectRevert(ISteadyPlanRegistry.PlanNotPaused.selector);
        registry.resumePlan(id);
    }

    function test_cancel_isTerminal() public {
        uint256 id = _create();
        vm.prank(owner);
        registry.cancelPlan(id);
        assertEq(uint8(registry.getPlan(id).status), uint8(ISteadyPlanRegistry.PlanStatus.Cancelled));

        vm.prank(owner);
        vm.expectRevert(ISteadyPlanRegistry.PlanAlreadyCancelled.selector);
        registry.cancelPlan(id);
    }

    function test_poke_emitsWhenDue_revertsWhenNot() public {
        uint256 id = _create();

        // Not yet due.
        vm.expectRevert(ISteadyPlanRegistry.PlanNotDue.selector);
        registry.poke(id);

        // Due: permissionless poke emits PlanDue(planId).
        vm.warp(block.timestamp + INTERVAL);
        vm.expectEmit(true, false, false, false);
        emit ISteadyPlanRegistry.PlanDue(id);
        vm.prank(stranger); // anyone may poke
        registry.poke(id);
    }

    function test_management_reverts_forNonOwner() public {
        uint256 id = _create();
        vm.startPrank(stranger);
        vm.expectRevert(ISteadyPlanRegistry.NotPlanOwner.selector);
        registry.pausePlan(id);
        vm.expectRevert(ISteadyPlanRegistry.NotPlanOwner.selector);
        registry.cancelPlan(id);
        vm.stopPrank();
    }
}
