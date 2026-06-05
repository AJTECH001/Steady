// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";
import {SteadyVault} from "steady/core/SteadyVault.sol";
import {SteadyExecutor} from "steady/execution/SteadyExecutor.sol";
import {SteadyHook} from "steady/execution/SteadyHook.sol";
import {ChainConfig} from "../config/ChainConfig.sol";

/// @notice Destination-chain deployment for Steady (e.g. Unichain Sepolia).
/// @dev Deploys test tokens, core, the mined SteadyHook, the executor, wires roles, creates the
///      dynamic-fee pool and seeds liquidity. The executor's reactive sender is left unset and is
///      wired by 03_WireUnichain after ReactiveSteady is deployed on the Reactive chain.
contract DeploySteady is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint24 constant DEFAULT_FEE = 3000; // 0.30% for ordinary swappers
    uint24 constant STEADY_FEE = 0; // fee-free for Steady executions
    int24 constant TICK_SPACING = 60;

    struct Deployed {
        MockERC20 t0;
        MockERC20 t1;
        SteadyPlanRegistry registry;
        SteadyVault vault;
        SteadyHook hook;
        SteadyExecutor executor;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        IPoolManager pm = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        address proxy = ChainConfig.callbackProxy(block.chainid);

        vm.startBroadcast(pk);
        Deployed memory d = _deploy(pm, proxy, deployer);
        vm.stopBroadcast();

        _log(d, proxy);
    }

    function _deploy(IPoolManager pm, address proxy, address deployer)
        internal
        returns (Deployed memory d)
    {
        (d.t0, d.t1) = _tokens(deployer);
        d.registry = new SteadyPlanRegistry(deployer);
        d.vault = new SteadyVault(d.registry, deployer);
        d.hook = _deployHook(pm, deployer);

        PoolKey memory key = _poolKey(d.t0, d.t1, d.hook);
        d.executor = new SteadyExecutor(pm, d.vault, d.registry, key, proxy, address(0), deployer);

        d.registry.setExecutor(address(d.executor));
        d.vault.setExecutor(address(d.executor));
        d.hook.setExecutor(address(d.executor));

        pm.initialize(key, Constants.SQRT_PRICE_1_1);
        _seedLiquidity(key, deployer);
    }

    function _tokens(address deployer) internal returns (MockERC20 t0, MockERC20 t1) {
        MockERC20 a = new MockERC20("Steady USD", "sUSD", 18);
        MockERC20 b = new MockERC20("Steady ETH", "sETH", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(deployer, 1_000_000e18);
        t1.mint(deployer, 1_000_000e18);
    }

    function _deployHook(IPoolManager pm, address deployer) internal returns (SteadyHook hook) {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(pm, DEFAULT_FEE, STEADY_FEE, deployer);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(SteadyHook).creationCode, args);
        hook = new SteadyHook{salt: salt}(pm, DEFAULT_FEE, STEADY_FEE, deployer);
        require(address(hook) == hookAddr, "hook address mismatch");
    }

    function _poolKey(MockERC20 t0, MockERC20 t1, SteadyHook hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _seedLiquidity(PoolKey memory key, address recipient) internal {
        IPositionManager positionManager =
            IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid));

        MockERC20(Currency.unwrap(key.currency0)).approve(PERMIT2, type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            Currency.unwrap(key.currency0), address(positionManager), type(uint160).max, type(uint48).max
        );
        IPermit2(PERMIT2).approve(
            Currency.unwrap(key.currency1), address(positionManager), type(uint160).max, type(uint48).max
        );

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = 100e18;
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        // Broadcast-safe mint via PositionManager actions (recipient = deployer, not address(this)).
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amt0 + 1, amt1 + 1, recipient, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, recipient);
        params[3] = abi.encode(key.currency1, recipient);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _log(Deployed memory d, address proxy) internal view {
        console2.log("DESTINATION_CHAIN_ID :", block.chainid);
        console2.log("TOKEN0               :", address(d.t0));
        console2.log("TOKEN1               :", address(d.t1));
        console2.log("REGISTRY             :", address(d.registry));
        console2.log("VAULT                :", address(d.vault));
        console2.log("HOOK                 :", address(d.hook));
        console2.log("EXECUTOR             :", address(d.executor));
        console2.log("CALLBACK_PROXY       :", proxy);
    }
}
