// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Turns a "due" signal into a bounded V4 swap on the destination chain.
/// @dev Phase 5: direct V4 swap. The internal swap path is structured as a strategy seam so a
///      TWAMM execution can replace it later without changing this interface (locked decision).
interface ISteadyExecutor {
    /// @notice Emitted on a successful plan execution.
    event Executed(uint256 indexed planId, uint256 amountIn, uint256 amountOut);
    /// @notice Emitted when a plan owner sets a per-execution minimum output (slippage guard).
    event MinAmountOutUpdated(uint256 indexed planId, uint256 minAmountOut);
    /// @notice Emitted when the owner updates the trusted ReactiveSteady sender.
    event ReactiveSenderUpdated(address indexed reactiveSender);

    error NotPoolManager();
    error NotPlanOwner();
    error PoolMismatch();
    error SlippageExceeded();
    error UnauthorizedCallback();

    /// @notice Owner sets the trusted ReactiveSteady contract whose injected address authorises
    ///         callbacks. Settable to resolve the cross-chain deploy cycle with ReactiveSteady.
    function setReactiveSender(address reactiveSender) external;

    function reactiveSender() external view returns (address);

    /// @notice Reactive callback entry point. `sender` is injected by the callback proxy and
    ///         authenticated against the configured reactive contract.
    /// @dev First arg MUST be the injected address per the Reactive payload convention.
    function executePlan(address sender, uint256 planId) external;

    /// @notice Plan-owner-only opt-in slippage protection: minimum tokenOut per execution.
    function setMinAmountOut(uint256 planId, uint256 minAmountOut) external;

    function minAmountOut(uint256 planId) external view returns (uint256);
}
