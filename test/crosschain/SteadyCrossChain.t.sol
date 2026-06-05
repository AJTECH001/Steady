// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockSystemContract} from "../utils/mocks/MockSystemContract.sol";

import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";
import {SteadyVault} from "steady/core/SteadyVault.sol";
import {SteadyExecutor} from "steady/execution/SteadyExecutor.sol";
import {SteadyHook} from "steady/execution/SteadyHook.sol";
import {ReactiveSteady} from "steady/reactive/ReactiveSteady.sol";
import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";

/// @notice Phase 6 cross-chain simulation: poke (origin) -> ReactiveSteady.react (reactive VM)
///         -> requestCallback -> SteadyExecutor.executePlan (destination) -> real V4 swap.
/// @dev Collapses origin/destination onto one local chain (the trigger-only model keeps each
///      plan's funds+pool native; ReactiveSteady is the automation glue). The Reactive system
///      contract is mocked at 0x8888 and the callback proxy is simulated by an explicit call.
contract SteadyCrossChainTest is BaseTest {
    using EasyPosm for IPositionManager;

    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 constant TRIGGER_TOPIC0 = uint256(keccak256("PlanDue(uint256)"));

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

    SteadyPlanRegistry registry;
    SteadyVault vault;
    SteadyExecutor executor;
    SteadyHook hook;
    ReactiveSteady reactive;

    address admin = address(this);
    address user = makeAddr("user");
    address callbackProxy = makeAddr("callbackProxy");
    address keeper = makeAddr("keeper");

    uint256 constant AMOUNT_IN = 1e18;
    uint64 constant INTERVAL = 7 days;
    uint32 constant EXECUTIONS = 4;
    uint256 constant CHAIN_ID = 31337;

    uint256 planId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // SteadyHook on a mined address; dynamic-fee pool so executions route through the hook.
        // Deploy it before reading the nonce below so the address prediction stays correct.
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        deployCodeTo("SteadyHook.sol:SteadyHook", abi.encode(poolManager, uint24(3000), uint24(0), admin), flags);
        hook = SteadyHook(flags);

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        _addLiquidity();

        registry = new SteadyPlanRegistry(admin);
        vault = new SteadyVault(registry, admin);

        // Mock the Reactive system contract at 0x8888 before deploying ReactiveSteady (its ctor subscribes).
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);

        // Resolve the executor<->reactive cross-chain reference by deploy order:
        // ReactiveSteady first (executor settable), then the executor with the reactive address as
        // its callback sender, then wire the executor back into ReactiveSteady. This is exactly the
        // real two-chain deploy flow (reactive on Lasna, executor on the destination chain).
        reactive = new ReactiveSteady(CHAIN_ID, address(registry), TRIGGER_TOPIC0, CHAIN_ID, admin);
        executor =
            new SteadyExecutor(poolManager, vault, registry, poolKey, callbackProxy, address(reactive), admin);
        reactive.setExecutor(address(executor));

        // Wire executor auth: registry/vault grant it execution rights; hook makes it fee-free.
        registry.setExecutor(address(executor));
        vault.setExecutor(address(executor));
        hook.setExecutor(address(executor));

        // Plan + funding.
        vm.prank(user);
        planId = registry.createPlan(Currency.unwrap(currency0), Currency.unwrap(currency1), AMOUNT_IN, INTERVAL, EXECUTIONS);
        deal(Currency.unwrap(currency0), user, 10e18);
        vm.startPrank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        vault.deposit(planId, AMOUNT_IN * EXECUTIONS);
        vm.stopPrank();
    }

    function _addLiquidity() internal {
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidity = 100e18;
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        positionManager.mint(
            poolKey, tickLower, tickUpper, liquidity, amt0 + 1, amt1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }

    function _system() internal pure returns (MockSystemContract) {
        return MockSystemContract(payable(SYSTEM_ADDR));
    }

    /// @notice The full automation loop end to end.
    function test_fullLoop_pokeToSwap() public {
        vm.warp(block.timestamp + INTERVAL);
        uint256 ownerOutBefore = IERC20(Currency.unwrap(currency1)).balanceOf(user);

        // 1) Origin: keeper pokes the due plan -> PlanDue emitted (we assert via the next step).
        vm.prank(keeper);
        registry.poke(planId);

        // 2) Reactive VM: system delivers the matching log to ReactiveSteady.react().
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: CHAIN_ID,
            contractAddress: address(registry),
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
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        // 3) ReactiveSteady requested a callback to the executor. Decode it.
        MockSystemContract sys = _system();
        assertEq(sys.callbackCalls(), 1);
        assertEq(sys.cbRecipient(), address(executor));
        bytes memory payload = sys.cbPayload();

        // 4) Callback proxy delivers the callback, injecting the reactive contract as arg 0.
        (, uint256 decodedPlanId) = abi.decode(_stripSelector(payload), (address, uint256));
        assertEq(decodedPlanId, planId);
        vm.prank(callbackProxy);
        executor.executePlan(address(reactive), decodedPlanId);

        // 5) Destination: swap executed, owner received the bought token, schedule advanced.
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(user), ownerOutBefore);
        assertEq(registry.getPlan(planId).executionsRemaining, EXECUTIONS - 1);
    }

    function test_poke_revertsWhenNotDue() public {
        vm.expectRevert(); // PlanNotDue
        registry.poke(planId);
    }

    /// @dev Removes the leading 4-byte selector so the args can be abi.decoded.
    function _stripSelector(bytes memory payload) internal pure returns (bytes memory args) {
        args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
    }
}
