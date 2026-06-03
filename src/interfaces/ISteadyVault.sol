// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Custody of user funds + per-plan accounting.
/// @dev Phase 2: deposit/withdraw. Executor-gated `debit` lands in Phase 3.
interface ISteadyVault {
    event Deposited(uint256 indexed planId, address indexed from, uint256 amount);
    event Withdrawn(uint256 indexed planId, address indexed to, uint256 amount);

    error ZeroAmount();
    error InsufficientBalance();
    error NotPlanOwner();

    function deposit(uint256 planId, uint256 amount) external;

    function withdraw(uint256 planId, uint256 amount) external;

    function balanceOf(uint256 planId) external view returns (uint256);
}
