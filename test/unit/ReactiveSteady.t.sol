// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ReactiveSteady} from "steady/reactive/ReactiveSteady.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";
import {MockSystemContract} from "../utils/mocks/MockSystemContract.sol";

contract ReactiveSteadyTest is Test {
    /// @dev Canonical Reactive Network system contract address (reactive-lib `SERVICE_ADDR`).
    address constant SERVICE_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    // Mirror of IReactive.Callback for expectEmit matching.
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);

    uint256 constant ORIGIN_CHAIN = 11155111; // Sepolia
    uint256 constant DEST_CHAIN = 84532; // Base Sepolia
    address triggerContract = makeAddr("triggerContract");
    address executor = makeAddr("executor");
    uint256 constant TRIGGER_TOPIC0 = uint256(keccak256("PlanDue(uint256)"));

    /// @dev "Reactive Network" instance: system contract present at SERVICE_ADDR, so `detectVm`
    ///      sets vm=false and the constructor subscribes. `react()` is disabled here (vmOnly).
    function _rnInstance() internal returns (ReactiveSteady r, MockSystemContract sys) {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SERVICE_ADDR, address(mock).code);
        r = new ReactiveSteady(ORIGIN_CHAIN, triggerContract, TRIGGER_TOPIC0, DEST_CHAIN, address(this));
        sys = MockSystemContract(payable(SERVICE_ADDR));
    }

    /// @dev "ReactVM" instance: no system contract at SERVICE_ADDR, so `detectVm` sets vm=true and
    ///      `react()` is enabled. The constructor skips subscribing (the `if (!vm)` guard).
    function _vmInstance() internal returns (ReactiveSteady r) {
        vm.etch(SERVICE_ADDR, ""); // ensure no code -> vm = true
        r = new ReactiveSteady(ORIGIN_CHAIN, triggerContract, TRIGGER_TOPIC0, DEST_CHAIN, address(this));
        r.setExecutor(executor);
    }

    function test_constructor_subscribesToTrigger() public {
        (ReactiveSteady r, MockSystemContract sys) = _rnInstance();
        assertEq(sys.subscribeCalls(), 1);
        assertEq(sys.subChainId(), ORIGIN_CHAIN);
        assertEq(sys.subContract(), triggerContract);
        assertEq(sys.subTopic0(), TRIGGER_TOPIC0);
        assertEq(sys.subTopic1(), REACTIVE_IGNORE);
        assertEq(r.destinationChainId(), DEST_CHAIN);
    }

    function test_react_emitsCallbackToExecutor() public {
        ReactiveSteady r = _vmInstance();
        uint256 planId = 7;

        bytes memory payload =
            abi.encodeWithSelector(bytes4(keccak256("executePlan(address,uint256)")), address(0), planId);

        vm.expectEmit(true, true, true, true);
        emit Callback(DEST_CHAIN, executor, r.CALLBACK_GAS_LIMIT(), payload);
        r.react(_logWithPlan(planId));
    }

    function test_react_reverts_onReactiveNetworkInstance() public {
        // vm=false (system present) -> react() guarded by vmOnly must revert.
        (ReactiveSteady r,) = _rnInstance();
        r.setExecutor(executor);
        vm.expectRevert(bytes("VM only"));
        r.react(_logWithPlan(1));
    }

    function test_setExecutor_onlyOwner() public {
        ReactiveSteady r = _vmInstance();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ReactiveSteady.NotOwner.selector);
        r.setExecutor(makeAddr("x"));
    }

    function test_react_reverts_whenExecutorNotSet() public {
        vm.etch(SERVICE_ADDR, ""); // vm = true
        ReactiveSteady fresh =
            new ReactiveSteady(ORIGIN_CHAIN, triggerContract, TRIGGER_TOPIC0, DEST_CHAIN, address(this));
        vm.expectRevert(ReactiveSteady.ExecutorNotSet.selector);
        fresh.react(_logWithPlan(1));
    }

    function _logWithPlan(uint256 planId) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN,
            _contract: triggerContract,
            topic_0: TRIGGER_TOPIC0,
            topic_1: planId,
            topic_2: 0,
            topic_3: 0,
            data: "",
            block_number: 1,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }
}
