// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/src/abstract-base/AbstractReactive.sol";

/// @notice Reactive Network contract for Steady.
/// @dev Deployed on the Reactive Network (not the origin/destination EVM chains).
///      It subscribes to a "due" trigger event on the origin chain and, on each match,
///      emits a `Callback` that the Reactive callback proxy delivers to the SteadyExecutor on
///      the destination chain (trigger-only cross-chain — funds never leave their native chain).
///      Built on Reactive-Network/reactive-lib (the standard lib the live network runs):
///      `AbstractReactive` exposes `service` (the system contract), the `vm` flag, the `vmOnly`
///      guard for `react()`, and the inherited `Callback` event used to request the callback.
contract ReactiveSteady is AbstractReactive {
    /// @notice Chain id of the destination network where SteadyExecutor lives.
    uint256 public immutable destinationChainId;

    /// @notice SteadyExecutor address on the destination chain (the callback recipient).
    /// @dev Owner-settable rather than immutable: the executor on the destination chain and this
    ///      contract on the Reactive chain reference each other, so the second-deployed address is
    ///      unknown at the first's construction. Deploy this first, deploy the executor, then call
    ///      {setExecutor}.
    address public executor;

    /// @notice Admin allowed to set the executor.
    address public owner;

    /// @notice Gas limit forwarded for the destination callback.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @dev Selector of `SteadyExecutor.executePlan(address,uint256)`. The leading address is a
    ///      placeholder that the callback proxy overwrites with the reactive contract's RVM id for
    ///      authentication (see the Reactive callback payload convention).
    bytes4 internal constant EXECUTE_PLAN_SELECTOR = bytes4(keccak256("executePlan(address,uint256)"));

    event ExecutorUpdated(address indexed executor);

    error NotOwner();
    error ExecutorNotSet();

    /// @param originChainId_  EIP-155 chain id of the network emitting the trigger event.
    /// @param triggerContract_ Contract emitting the trigger event (e.g. the origin registry).
    /// @param triggerTopic0_   topic0 (event signature hash) of the trigger event to watch.
    /// @param destinationChainId_ Chain id where SteadyExecutor is deployed.
    /// @param owner_           Admin allowed to set the executor after deployment.
    /// @dev Payable so the deployer can fund the contract with REACT at construction — the Reactive
    ///      Network charges the contract for its subscription and for each callback it requests.
    constructor(
        uint256 originChainId_,
        address triggerContract_,
        uint256 triggerTopic0_,
        uint256 destinationChainId_,
        address owner_
    ) payable {
        destinationChainId = destinationChainId_;
        owner = owner_;

        // Only the top-level Reactive Network instance subscribes; the per-contract ReactVM copy
        // (where `vm` is true) must not. Watch the trigger event on the origin chain; planId is
        // carried in topic1.
        if (!vm) {
            service.subscribe(
                originChainId_,
                triggerContract_,
                triggerTopic0_,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    /// @notice Owner sets the destination-chain SteadyExecutor (callback recipient).
    function setExecutor(address executor_) external {
        if (msg.sender != owner) revert NotOwner();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @notice Entry point invoked by the Reactive Network on a matching event (ReactVM only).
    /// @dev `vmOnly` ensures only the network's ReactVM may trigger reactions. The planId is read
    ///      from the indexed topic1 of the trigger event. Emitting `Callback` requests the proxy to
    ///      invoke `executePlan` on the destination chain.
    function react(LogRecord calldata log) external override vmOnly {
        address dest = executor;
        if (dest == address(0)) revert ExecutorNotSet();
        uint256 planId = log.topic_1;

        bytes memory payload = abi.encodeWithSelector(EXECUTE_PLAN_SELECTOR, address(0), planId);

        emit Callback(destinationChainId, dest, CALLBACK_GAS_LIMIT, payload);
    }
}
