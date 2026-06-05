// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {ISteadyExecutor} from "steady/interfaces/ISteadyExecutor.sol";

/// @notice Phase 5 integration: full execution path against a real local V4 pool with liquidity,
///         routed through the SteadyHook dynamic-fee hook (executions are fee-free).
contract SteadyExecutorIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

    SteadyPlanRegistry registry;
    SteadyVault vault;
    SteadyExecutor executor;
    SteadyHook hook;

    address admin = address(this);
    address user = makeAddr("user");
    address callbackProxy = makeAddr("callbackProxy"); // stand-in for Reactive callback proxy
    address reactive = makeAddr("reactive"); // stand-in for ReactiveSteady (the callback sender)

    uint256 constant AMOUNT_IN = 1e18;
    uint64 constant INTERVAL = 7 days;
    uint32 constant EXECUTIONS = 4;

    uint256 planId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy SteadyHook to an address encoding {afterInitialize, beforeSwap} and use a
        // dynamic-fee pool so Steady executions route through the hook (fee-free).
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        deployCodeTo("SteadyHook.sol:SteadyHook", abi.encode(poolManager, uint24(3000), uint24(0), admin), flags);
        hook = SteadyHook(flags);

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

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

        registry = new SteadyPlanRegistry(admin);
        vault = new SteadyVault(registry, admin);
        executor = new SteadyExecutor(
            poolManager, vault, registry, poolKey, callbackProxy, reactive, admin
        );
        registry.setExecutor(address(executor));
        vault.setExecutor(address(executor));
        hook.setExecutor(address(executor)); // executor's swaps are fee-free

        // Plan: spend currency0 to buy currency1.
        vm.prank(user);
        planId = registry.createPlan(
            Currency.unwrap(currency0), Currency.unwrap(currency1), AMOUNT_IN, INTERVAL, EXECUTIONS
        );

        // Fund the plan: give the user currency0 and deposit it.
        deal(Currency.unwrap(currency0), user, 10e18);
        vm.startPrank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        vault.deposit(planId, AMOUNT_IN * EXECUTIONS);
        vm.stopPrank();
    }

    function _callExecute() internal {
        vm.prank(callbackProxy);
        executor.executePlan(reactive, planId);
    }

    function test_execute_swapsAndDelivers() public {
        vm.warp(block.timestamp + INTERVAL);

        uint256 ownerOutBefore = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 vaultInBefore = vault.balanceOf(planId);

        _callExecute();

        // Plan funding token debited by exactly amountIn.
        assertEq(vault.balanceOf(planId), vaultInBefore - AMOUNT_IN);
        // Plan owner received the bought token.
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(user), ownerOutBefore);
        // Schedule advanced.
        assertEq(registry.getPlan(planId).executionsRemaining, EXECUTIONS - 1);
    }

    function test_execute_routesThroughHook_feeFree() public {
        // The executor is registered as the hook's Steady executor with a 0 steady fee, so its
        // swaps pay no LP fee. A fee-free execution returns more output than the same swap would
        // at the hook's 0.30% default fee.
        assertEq(hook.steadyExecutor(), address(executor));
        assertEq(hook.steadyFee(), 0);

        vm.warp(block.timestamp + INTERVAL);
        uint256 snap = vm.snapshotState();

        // Baseline: bump the executor's fee to the default so we can compare.
        _callExecute();
        uint256 outFeeFree = IERC20(Currency.unwrap(currency1)).balanceOf(user);

        vm.revertToState(snap);
        hook.setFees(3000, 3000); // executor now also pays 0.30%
        _callExecute();
        uint256 outWithFee = IERC20(Currency.unwrap(currency1)).balanceOf(user);

        assertGt(outFeeFree, outWithFee, "Steady execution must be fee-free via the hook");
    }

    function test_execute_reverts_forWrongCallbackProxy() public {
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(); // AbstractPayer.NotAuthorized (msg.sender != callback proxy)
        executor.executePlan(reactive, planId);
    }

    function test_execute_reverts_forWrongCallbackSender() public {
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(callbackProxy);
        vm.expectRevert(); // CallbackNotAuthorized (injected sender != reactive)
        executor.executePlan(makeAddr("notReactive"), planId);
    }

    function test_execute_reverts_whenNotDue() public {
        vm.prank(callbackProxy);
        vm.expectRevert(); // registry advanceSchedule => PlanNotDue
        executor.executePlan(reactive, planId);
    }

    function test_execute_replayInSamePeriod_reverts() public {
        vm.warp(block.timestamp + INTERVAL);
        _callExecute();
        // Second call in the same window: schedule moved forward, no longer due.
        vm.prank(callbackProxy);
        vm.expectRevert();
        executor.executePlan(reactive, planId);
    }

    function test_execute_slippageGuard() public {
        // Owner sets an impossibly high min-out; execution must revert.
        vm.prank(user);
        executor.setMinAmountOut(planId, 1e30);

        vm.warp(block.timestamp + INTERVAL);
        vm.prank(callbackProxy);
        vm.expectRevert(ISteadyExecutor.SlippageExceeded.selector);
        executor.executePlan(reactive, planId);
    }

    function test_setMinAmountOut_onlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ISteadyExecutor.NotPlanOwner.selector);
        executor.setMinAmountOut(planId, 1);
    }
}
