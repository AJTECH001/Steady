// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ReactiveSteady} from "steady/reactive/ReactiveSteady.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";
import {ISubscriptionService} from "reactive-lib/src/interfaces/ISubscriptionService.sol";

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

contract ReactiveSteadyTest is Test {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    ReactiveSteady reactive;

    uint256 constant ORIGIN_CHAIN = 11155111; // Sepolia
    uint256 constant DEST_CHAIN = 84532; // Base Sepolia
    address triggerContract = makeAddr("triggerContract");
    address executor = makeAddr("executor");
    uint256 constant TRIGGER_TOPIC0 = uint256(keccak256("PlanDue(uint256)"));

    function setUp() public {
        // Place the mock system-contract code at the canonical 0x8888 address.
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);

        reactive = new ReactiveSteady(ORIGIN_CHAIN, triggerContract, TRIGGER_TOPIC0, DEST_CHAIN, executor);
    }

    function _system() internal pure returns (MockSystemContract) {
        return MockSystemContract(payable(SYSTEM_ADDR));
    }

    function test_constructor_subscribesToTrigger() public view {
        MockSystemContract sys = _system();
        assertEq(sys.subscribeCalls(), 1);
        assertEq(sys.subChainId(), ORIGIN_CHAIN);
        assertEq(sys.subContract(), triggerContract);
        assertEq(sys.subTopic0(), TRIGGER_TOPIC0);
        assertEq(sys.subTopic1(), REACTIVE_IGNORE);
        assertEq(reactive.destinationChainId(), DEST_CHAIN);
        assertEq(reactive.executor(), executor);
    }

    function test_react_requestsCallbackToExecutor() public {
        uint256 planId = 7;
        IReactive.LogRecord memory log = _logWithPlan(planId);

        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        MockSystemContract sys = _system();
        assertEq(sys.callbackCalls(), 1);
        assertEq(sys.cbChainId(), DEST_CHAIN);
        assertEq(sys.cbRecipient(), executor);
        assertEq(sys.cbGasLimit(), reactive.CALLBACK_GAS_LIMIT());

        // payload = executePlan(address(0) placeholder, planId)
        bytes memory expected =
            abi.encodeWithSelector(bytes4(keccak256("executePlan(address,uint256)")), address(0), planId);
        assertEq(sys.cbPayload(), expected);
    }

    function test_react_reverts_forNonSystem() public {
        IReactive.LogRecord memory log = _logWithPlan(1);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(); // AbstractPayer.NotAuthorized
        reactive.react(log);
    }

    function _logWithPlan(uint256 planId) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: triggerContract,
            topic0: TRIGGER_TOPIC0,
            topic1: planId,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }
}
