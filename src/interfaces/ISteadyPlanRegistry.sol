// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Source of truth for recurring savings plans.
/// @dev Phase 2: plan CRUD + schedule reads. Executor-gated schedule advance lands in Phase 3.
interface ISteadyPlanRegistry {
    enum PlanStatus {
        None, // 0 = unset / nonexistent
        Active,
        Paused,
        Cancelled,
        Completed // all scheduled executions consumed
    }

    /// @param owner               address allowed to manage and withdraw the plan
    /// @param tokenIn             token spent on each execution (the savings funding token)
    /// @param tokenOut            token bought on each execution (the target asset)
    /// @param amountIn            tokenIn spent per execution
    /// @param interval            seconds between executions
    /// @param lastExecuted        timestamp of the last execution (0 if never)
    /// @param nextDue             timestamp the next execution becomes due
    /// @param executionsRemaining number of executions left before the plan completes
    /// @param status              lifecycle status
    struct Plan {
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint64 interval;
        uint64 lastExecuted;
        uint64 nextDue;
        uint32 executionsRemaining;
        PlanStatus status;
    }

    event PlanCreated(
        uint256 indexed planId,
        address indexed owner,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint64 interval,
        uint32 executions
    );
    event PlanPaused(uint256 indexed planId);
    event PlanResumed(uint256 indexed planId);
    event PlanCancelled(uint256 indexed planId);
    /// @notice Emitted when the executor consumes a due execution and reschedules.
    event PlanAdvanced(uint256 indexed planId, uint64 nextDue, uint32 executionsRemaining);
    /// @notice Emitted when the final scheduled execution is consumed.
    event PlanCompleted(uint256 indexed planId);
    event ExecutorUpdated(address indexed executor);

    error NotPlanOwner();
    error NotExecutor();
    error InvalidAmount();
    error InvalidInterval();
    error InvalidExecutions();
    error InvalidToken();
    error InvalidExecutor();
    error PlanDoesNotExist();
    error PlanNotActive();
    error PlanNotPaused();
    error PlanNotDue();
    error PlanAlreadyCancelled();

    function createPlan(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint64 interval,
        uint32 executions
    ) external returns (uint256 planId);

    function pausePlan(uint256 planId) external;

    function resumePlan(uint256 planId) external;

    function cancelPlan(uint256 planId) external;

    /// @notice Executor-only. Consumes one due execution and reschedules the plan.
    /// @dev Reverts unless the plan is currently due. Completes the plan when the
    ///      last execution is consumed.
    function advanceSchedule(uint256 planId) external;

    /// @notice Admin-only. Sets the contract authorised to call `advanceSchedule`.
    function setExecutor(address executor) external;

    function executor() external view returns (address);

    function getPlan(uint256 planId) external view returns (Plan memory);

    function isDue(uint256 planId) external view returns (bool);

    function getUserPlans(address user) external view returns (uint256[] memory);
}
