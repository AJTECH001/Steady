// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISteadyPlanRegistry} from "steady/interfaces/ISteadyPlanRegistry.sol";
import {ScheduleLib} from "steady/libraries/ScheduleLib.sol";

/// @notice Source of truth for recurring savings plans.
/// @dev Phase 2 scope: plan lifecycle (create/pause/resume/cancel) + schedule reads.
///      Executor-gated `advanceSchedule` and vault wiring arrive in Phase 3.
contract SteadyPlanRegistry is ISteadyPlanRegistry {
    using ScheduleLib for uint64;

    /// @dev Plan ids start at 1; id 0 is reserved for "nonexistent".
    uint256 private _nextPlanId;

    mapping(uint256 planId => Plan) private _plans;
    mapping(address user => uint256[] planIds) private _userPlans;

    /// @inheritdoc ISteadyPlanRegistry
    function createPlan(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint64 interval,
        uint32 executions
    ) external returns (uint256 planId) {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert InvalidToken();
        if (amountIn == 0) revert InvalidAmount();
        if (interval == 0) revert InvalidInterval();
        if (executions == 0) revert InvalidExecutions();

        planId = ++_nextPlanId;

        uint64 nowTs = uint64(block.timestamp);
        _plans[planId] = Plan({
            owner: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            interval: interval,
            lastExecuted: 0,
            nextDue: nowTs.nextDue(interval),
            executionsRemaining: executions,
            status: PlanStatus.Active
        });
        _userPlans[msg.sender].push(planId);

        emit PlanCreated(planId, msg.sender, tokenIn, tokenOut, amountIn, interval, executions);
    }

    /// @inheritdoc ISteadyPlanRegistry
    function pausePlan(uint256 planId) external {
        Plan storage plan = _ownedActivePlan(planId);
        plan.status = PlanStatus.Paused;
        emit PlanPaused(planId);
    }

    /// @inheritdoc ISteadyPlanRegistry
    function resumePlan(uint256 planId) external {
        Plan storage plan = _existingOwnedPlan(planId);
        if (plan.status != PlanStatus.Paused) revert PlanNotPaused();
        plan.status = PlanStatus.Active;
        emit PlanResumed(planId);
    }

    /// @inheritdoc ISteadyPlanRegistry
    function cancelPlan(uint256 planId) external {
        Plan storage plan = _existingOwnedPlan(planId);
        if (plan.status == PlanStatus.Cancelled) revert PlanAlreadyCancelled();
        plan.status = PlanStatus.Cancelled;
        emit PlanCancelled(planId);
    }

    /// @inheritdoc ISteadyPlanRegistry
    function getPlan(uint256 planId) external view returns (Plan memory) {
        Plan memory plan = _plans[planId];
        if (plan.status == PlanStatus.None) revert PlanDoesNotExist();
        return plan;
    }

    /// @inheritdoc ISteadyPlanRegistry
    function isDue(uint256 planId) external view returns (bool) {
        Plan memory plan = _plans[planId];
        if (plan.status != PlanStatus.Active) return false;
        if (plan.executionsRemaining == 0) return false;
        return plan.nextDue.isDue(uint64(block.timestamp));
    }

    /// @inheritdoc ISteadyPlanRegistry
    function getUserPlans(address user) external view returns (uint256[] memory) {
        return _userPlans[user];
    }

    // --- internal ---

    function _existingOwnedPlan(uint256 planId) private view returns (Plan storage plan) {
        plan = _plans[planId];
        if (plan.status == PlanStatus.None) revert PlanDoesNotExist();
        if (plan.owner != msg.sender) revert NotPlanOwner();
    }

    function _ownedActivePlan(uint256 planId) private view returns (Plan storage plan) {
        plan = _existingOwnedPlan(planId);
        if (plan.status != PlanStatus.Active) revert PlanNotActive();
    }
}
