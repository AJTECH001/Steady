// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/src/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";

/// @notice Reactive Network contract for Steady.
/// @dev Deployed on the Reactive Network (not the origin/destination EVM chains).
///      It subscribes to a "due" trigger event on the origin chain and, on each match,
///      requests a callback to the SteadyExecutor on the destination chain (trigger-only
///      cross-chain — funds never leave their native chain). All Reactive APIs here are
///      verified against Reactive-Network/reactive-lib-omni @ v0.1.0.
contract ReactiveSteady is AbstractReactive {
    /// @notice Chain id of the destination network where SteadyExecutor lives.
    uint256 public immutable destinationChainId;

    /// @notice SteadyExecutor address on the destination chain (the callback recipient).
    /// @dev Owner-settable rather than immutable: the executor on the destination chain and this
    ///      contract on the Reactive chain reference each other, so the second-deployed address is
    ///      unknown at the first's construction. Deploy this first, deploy the executor with this
    ///      address as its callback sender, then call {setExecutor}.
    address public executor;

    /// @notice Admin allowed to set the executor.
    address public owner;

    /// @notice Gas limit forwarded for the destination callback.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @dev Selector of `SteadyExecutor.executePlan(address,uint256)`. The leading address is a
    ///      placeholder that the callback proxy overwrites with this contract's address for
    ///      authentication (see IReactive payload convention).
    bytes4 internal constant EXECUTE_PLAN_SELECTOR = bytes4(keccak256("executePlan(address,uint256)"));

    event ExecutorUpdated(address indexed executor);

    error NotOwner();
    error ExecutorNotSet();

    /// @param originChainId_  EIP-155 chain id of the network emitting the trigger event.
    /// @param triggerContract_ Contract emitting the trigger event (e.g. the origin vault/registry).
    /// @param triggerTopic0_   topic0 (event signature hash) of the trigger event to watch.
    /// @param destinationChainId_ Chain id where SteadyExecutor is deployed.
    /// @param owner_           Admin allowed to set the executor after deployment.
    constructor(
        uint256 originChainId_,
        address triggerContract_,
        uint256 triggerTopic0_,
        uint256 destinationChainId_,
        address owner_
    ) {
        destinationChainId = destinationChainId_;
        owner = owner_;

        // Watch the trigger event on the origin chain; planId is carried in topic1.
        SYSTEM.subscribe(
            originChainId_,
            triggerContract_,
            triggerTopic0_,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Owner sets the destination-chain SteadyExecutor (callback recipient).
    function setExecutor(address executor_) external {
        if (msg.sender != owner) revert NotOwner();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @notice Entry point invoked by the Reactive Network system contract on a matching event.
    /// @dev `onlySystem` ensures only the network may trigger reactions. The planId is read from
    ///      the indexed topic1 of the trigger event.
    function react(LogRecord calldata log_) external override onlySystem {
        address dest = executor;
        if (dest == address(0)) revert ExecutorNotSet();
        uint256 planId = log_.topic1;

        bytes memory payload = abi.encodeWithSelector(EXECUTE_PLAN_SELECTOR, address(0), planId);

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: dest,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }
}
