// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";

/// @notice Minimal stand-in for the Reactive Network system contract (0x8888...8888).
///         Records the last subscribe() and requestCallbackV_1_0() calls for assertions.
contract MockSystemContract is ISystemContract {
    // last subscribe(...)
    uint256 public subChainId;
    address public subContract;
    uint256 public subTopic0;
    uint256 public subTopic1;
    uint256 public subscribeCalls;

    // last requestCallbackV_1_0(...)
    uint256 public cbChainId;
    address public cbRecipient;
    uint64 public cbGasLimit;
    bytes public cbPayload;
    uint256 public callbackCalls;

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256, uint256) external override {
        subChainId = c;
        subContract = a;
        subTopic0 = t0;
        subTopic1 = t1;
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external override {}

    function requestCallback(CallbackVersion, bytes memory) external override {}

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        cbChainId = config_.chainId;
        cbRecipient = config_.recipient;
        cbGasLimit = config_.gasLimit;
        cbPayload = config_.payload;
        callbackCalls++;
    }

    function debt(address) external pure override returns (uint256) {
        return 0;
    }

    receive() external payable override {}
}
