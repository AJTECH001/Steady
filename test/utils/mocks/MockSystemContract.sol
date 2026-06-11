// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";

/// @notice Minimal stand-in for the Reactive Network system contract (0x0000...fffFfF).
///         Records the last subscribe() call for assertions. The callback in the standard
///         reactive-lib model is emitted as an event by the reactive contract (not a system
///         call), so this mock only needs the subscription surface plus the payer hooks.
contract MockSystemContract is ISystemContract {
    // last subscribe(...)
    uint256 public subChainId;
    address public subContract;
    uint256 public subTopic0;
    uint256 public subTopic1;
    uint256 public subscribeCalls;

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256, uint256) external override {
        subChainId = c;
        subContract = a;
        subTopic0 = t0;
        subTopic1 = t1;
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external override {}

    function debt(address) external pure override returns (uint256) {
        return 0;
    }

    receive() external payable override {}
}
