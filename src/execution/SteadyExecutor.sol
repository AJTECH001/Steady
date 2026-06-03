// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISteadyExecutor} from "steady/interfaces/ISteadyExecutor.sol";

/// @notice Turns a "due" signal into a bounded V4 swap on the destination chain.
/// @dev Phase 5 scaffold — direct-swap-behind-TWAMM-shaped-iface (locked decision).
contract SteadyExecutor is ISteadyExecutor {
    // scaffold
}
