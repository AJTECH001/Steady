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

import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";
import {SteadyVault} from "steady/core/SteadyVault.sol";
import {SteadyExecutor} from "steady/execution/SteadyExecutor.sol";
import {SteadyHook} from "steady/execution/SteadyHook.sol";
import {ReactiveSteady} from "steady/reactive/ReactiveSteady.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";

/// @notice Phase 6 cross-chain simulation: poke (origin) -> ReactiveSteady.react (reactive VM)
///         -> Callback event -> SteadyExecutor.executePlan (destination) -> real V4 swap.
/// @dev Collapses origin/destination onto one local chain (the trigger-only model keeps each
///      plan's funds+pool native; ReactiveSteady is the automation glue). ReactiveSteady is
///      deployed as a ReactVM instance (no system contract at SERVICE_ADDR, so `vm` is true and
///      `react()` is enabled); the callback proxy is simulated by an explicit call.
contract SteadyCrossChainTest is BaseTest {
    using EasyPosm for IPositionManager;

    /// @dev Canonical Reactive Network system contract address (reactive-lib `SERVICE_ADDR`).
    address constant SERVICE_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant TRIGGER_TOPIC0 = uint256(keccak256("PlanDue(uint256)"));

    // Mirror of IReactive.Callback for expectEmit matching.
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);

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

        // Deploy ReactiveSteady as a ReactVM instance: no system contract at SERVICE_ADDR means
        // `detectVm` sets vm=true, which enables react() (and skips the constructor subscribe, which
        // only runs on the top-level Reactive Network instance — covered in the unit test).
        vm.etch(SERVICE_ADDR, "");

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

    /// @notice The full automation loop end to end.
    function test_fullLoop_pokeToSwap() public {
        vm.warp(block.timestamp + INTERVAL);
        uint256 ownerOutBefore = IERC20(Currency.unwrap(currency1)).balanceOf(user);

        // 1) Origin: keeper pokes the due plan -> PlanDue emitted (we assert via the next step).
        vm.prank(keeper);
        registry.poke(planId);

        // 2) Reactive VM: the network delivers the matching log to ReactiveSteady.react(), which
        //    emits a Callback requesting executePlan on the destination chain.
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: CHAIN_ID,
            _contract: address(registry),
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
        bytes memory payload =
            abi.encodeWithSelector(bytes4(keccak256("executePlan(address,uint256)")), address(0), planId);
        vm.expectEmit(true, true, true, true);
        emit Callback(CHAIN_ID, address(executor), reactive.CALLBACK_GAS_LIMIT(), payload);
        reactive.react(log);

        // 3) Callback proxy delivers the callback, injecting the reactive RVM id (modeled here as the
        //    reactive contract address, matching the executor's configured reactiveSender).
        vm.prank(callbackProxy);
        executor.executePlan(address(reactive), planId);

        // 4) Destination: swap executed, owner received the bought token, schedule advanced.
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(user), ownerOutBefore);
        assertEq(registry.getPlan(planId).executionsRemaining, EXECUTIONS - 1);
    }

    function test_poke_revertsWhenNotDue() public {
        vm.expectRevert(); // PlanNotDue
        registry.poke(planId);
    }
}
