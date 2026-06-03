// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Pure schedule math for recurring plans.
/// @dev Kept side-effect free so it can be fuzzed in isolation (Phase 2/3).
library ScheduleLib {
    /// @notice Compute the next due timestamp after a reference point.
    /// @dev Solidity 0.8 checked arithmetic reverts on overflow, which is the
    ///      desired behaviour for absurd (from + interval) values.
    function nextDue(uint64 from, uint64 interval) internal pure returns (uint64) {
        return from + interval;
    }

    /// @notice Whether an execution scheduled at `dueAt` is due as of `nowTs`.
    function isDue(uint64 dueAt, uint64 nowTs) internal pure returns (bool) {
        return nowTs >= dueAt;
    }
}
