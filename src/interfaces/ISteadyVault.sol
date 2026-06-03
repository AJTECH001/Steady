// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Custody of user funds + per-plan accounting.
/// @dev Phase 2: deposit/withdraw. Executor-gated `debit` lands in Phase 3.
interface ISteadyVault {
    event Deposited(uint256 indexed planId, address indexed from, uint256 amount);
    event Withdrawn(uint256 indexed planId, address indexed to, uint256 amount);
    /// @notice Emitted when the executor pulls funds to execute a plan.
    event Debited(uint256 indexed planId, address indexed to, uint256 amount);
    event ExecutorUpdated(address indexed executor);

    error ZeroAmount();
    error InsufficientBalance();
    error NotPlanOwner();
    error NotExecutor();
    error InvalidExecutor();

    function deposit(uint256 planId, uint256 amount) external;

    function withdraw(uint256 planId, uint256 amount) external;

    /// @notice Executor-only. Pulls `amount` of the plan's tokenIn to `to` for execution.
    function debit(uint256 planId, uint256 amount, address to) external;

    /// @notice Admin-only. Sets the contract authorised to call `debit`.
    function setExecutor(address executor) external;

    function executor() external view returns (address);

    function balanceOf(uint256 planId) external view returns (uint256);
}
