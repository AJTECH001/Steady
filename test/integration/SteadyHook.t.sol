// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {SteadyHook} from "steady/execution/SteadyHook.sol";

contract SteadyHookTest is BaseTest {
    using EasyPosm for IPositionManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    SteadyHook hook;

    uint24 constant DEFAULT_FEE = 3000; // 0.30%
    uint24 constant STEADY_FEE = 0; // fee-free for savers
    uint256 constant SWAP_IN = 1e18;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy SteadyHook to an address encoding {afterInitialize, beforeSwap}.
        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144)
        );
        bytes memory args = abi.encode(poolManager, DEFAULT_FEE, STEADY_FEE, address(this));
        deployCodeTo("SteadyHook.sol:SteadyHook", args, flags);
        hook = SteadyHook(flags);

        // Dynamic-fee pool with the hook.
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        _addLiquidity();
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

    function _swapOut() internal returns (uint256) {
        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        return uint256(uint128(delta.amount1()));
    }

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeSwapReturnDelta);
    }

    function test_initialFees() public view {
        assertEq(hook.defaultFee(), DEFAULT_FEE);
        assertEq(hook.steadyFee(), STEADY_FEE);
    }

    /// @notice The core feature: a swap from the Steady executor pays steadyFee (0), so it returns
    ///         more output than the same swap from a non-Steady caller paying defaultFee (0.30%).
    function test_steadyExecutionGetsFeeWaiver() public {
        uint256 snap = vm.snapshotState();

        // Treat the router as the Steady executor => fee-free.
        hook.setExecutor(address(swapRouter));
        uint256 outFeeFree = _swapOut();

        vm.revertToState(snap);

        // Router is NOT the executor => default 0.30% fee.
        hook.setExecutor(makeAddr("someOtherExecutor"));
        uint256 outWithFee = _swapOut();

        assertGt(outFeeFree, outWithFee, "fee-free swap must return more output");
    }

    function test_setExecutor_onlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        hook.setExecutor(makeAddr("x"));
    }

    function test_setFees_validation_and_access() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        hook.setFees(1, 2);

        // Read MAX_FEE before arming expectRevert (it is itself an external call).
        uint24 tooHigh = hook.MAX_FEE() + 1;
        vm.expectRevert(SteadyHook.InvalidFee.selector);
        hook.setFees(tooHigh, 0);

        hook.setFees(5000, 100);
        assertEq(hook.defaultFee(), 5000);
        assertEq(hook.steadyFee(), 100);
    }

    function test_afterInitialize_revertsForStaticFeePool() public {
        // The hook's afterInitialize reverts NotDynamicFee; the PoolManager wraps hook reverts,
        // so we assert it reverts (a static-fee pool cannot use this dynamic-fee hook).
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        poolManager.initialize(staticKey, Constants.SQRT_PRICE_1_1);
    }
}
