// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ISteadyPlanRegistry} from "steady/interfaces/ISteadyPlanRegistry.sol";
import {ScheduleLib} from "steady/libraries/ScheduleLib.sol";

/// @notice Source of truth for recurring savings plans.
/// @dev Plan lifecycle (create/pause/resume/cancel) + schedule reads, plus the
///      executor-gated `advanceSchedule` that consumes a due execution.
contract SteadyPlanRegistry is ISteadyPlanRegistry, Ownable {
    using ScheduleLib for uint64;

    /// @dev Plan ids start at 1; id 0 is reserved for "nonexistent".
    uint256 private _nextPlanId;

    /// @inheritdoc ISteadyPlanRegistry
    address public executor;

    mapping(uint256 planId => Plan) private _plans;
    mapping(address user => uint256[] planIds) private _userPlans;

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc ISteadyPlanRegistry
    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidExecutor();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

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
    /// @dev Reschedules anchored to the current timestamp (now + interval) rather than the
    ///      previous due time. This avoids a "catch-up burst" of back-to-back executions
    ///      draining a plan if execution is delayed — a deliberate MVP safety choice.
    function advanceSchedule(uint256 planId) external onlyExecutor {
        Plan storage plan = _plans[planId];
        if (plan.status == PlanStatus.None) revert PlanDoesNotExist();
        if (plan.status != PlanStatus.Active) revert PlanNotActive();
        if (plan.executionsRemaining == 0 || !plan.nextDue.isDue(uint64(block.timestamp))) {
            revert PlanNotDue();
        }

        uint64 nowTs = uint64(block.timestamp);
        plan.lastExecuted = nowTs;
        uint32 remaining = plan.executionsRemaining - 1;
        plan.executionsRemaining = remaining;

        if (remaining == 0) {
            plan.status = PlanStatus.Completed;
            emit PlanCompleted(planId);
        } else {
            plan.nextDue = nowTs.nextDue(plan.interval);
        }
        emit PlanAdvanced(planId, plan.nextDue, remaining);
    }

    /// @inheritdoc ISteadyPlanRegistry
    function getPlan(uint256 planId) external view returns (Plan memory) {
        Plan memory plan = _plans[planId];
        if (plan.status == PlanStatus.None) revert PlanDoesNotExist();
        return plan;
    }

    /// @inheritdoc ISteadyPlanRegistry
    function isDue(uint256 planId) external view returns (bool) {
        return _isDue(planId);
    }

    function _isDue(uint256 planId) internal view returns (bool) {
        Plan memory plan = _plans[planId];
        if (plan.status != PlanStatus.Active) return false;
        if (plan.executionsRemaining == 0) return false;
        return plan.nextDue.isDue(uint64(block.timestamp));
    }

    /// @inheritdoc ISteadyPlanRegistry
    function poke(uint256 planId) external {
        if (!_isDue(planId)) revert PlanNotDue();
        emit PlanDue(planId);
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
