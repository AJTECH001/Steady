// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {AbstractCallback} from "reactive-lib/src/abstract-base/AbstractCallback.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ISteadyExecutor} from "steady/interfaces/ISteadyExecutor.sol";
import {ISteadyVault} from "steady/interfaces/ISteadyVault.sol";
import {ISteadyPlanRegistry} from "steady/interfaces/ISteadyPlanRegistry.sol";

/// @notice Destination-chain executor. On a verified Reactive callback it consumes one due plan
///         execution, pulls the funding token from the vault, swaps it into the target token via
///         the Uniswap V4 PoolManager, and delivers the output to the plan owner.
/// @dev Self-custodial swap: the executor holds the funding token (from `vault.debit`) and performs
///      the V4 unlock/settle/take flow itself — no router or Permit2 approvals required.
///
///      Replay protection is inherent: `registry.advanceSchedule` reverts `PlanNotDue` unless the
///      plan's window has elapsed, so a replayed callback within the same period reverts. Schedule
///      monotonicity guarantees each period executes at most once.
///
///      Deployment note (Phase 10): SteadyExecutor and ReactiveSteady reference each other, so deploy
///      the executor at a CREATE2-precomputed address, pass it to ReactiveSteady, then deploy the
///      executor with ReactiveSteady's address as `callbackSender_`.
contract SteadyExecutor is ISteadyExecutor, AbstractCallback, Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    ISteadyVault public immutable vault;
    ISteadyPlanRegistry public immutable registry;

    // Pool used for execution. tokenIn/tokenOut of every plan must match these currencies.
    Currency public immutable currency0;
    Currency public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hooks;

    /// @inheritdoc ISteadyExecutor
    mapping(uint256 planId => uint256) public minAmountOut;

    /// @notice Trusted reactive RVM id; the proxy-injected `sender` must equal this.
    /// @dev In the Reactive callback model the proxy overwrites the payload's leading address with
    ///      the originating reactive contract's RVM id (the deployer address that owns the ReactVM).
    ///      Owner-settable to resolve the cross-chain deploy cycle and to pin the exact RVM id once
    ///      ReactiveSteady is deployed.
    address public reactiveSender;

    /// @dev Authorises a callback: the proxy-injected sender must be the trusted reactive RVM id.
    modifier onlyReactive(address sender) {
        if (sender == address(0) || sender != reactiveSender) revert UnauthorizedCallback();
        _;
    }

    struct SwapCallbackData {
        bool zeroForOne;
        uint256 amountIn;
        address inputToken;
        address recipient;
    }

    constructor(
        IPoolManager poolManager_,
        ISteadyVault vault_,
        ISteadyPlanRegistry registry_,
        PoolKey memory poolKey_,
        address callbackProxy_,
        address callbackSender_,
        address initialOwner_
    ) AbstractCallback(callbackProxy_) Ownable(initialOwner_) {
        reactiveSender = callbackSender_;
        poolManager = poolManager_;
        vault = vault_;
        registry = registry_;
        currency0 = poolKey_.currency0;
        currency1 = poolKey_.currency1;
        fee = poolKey_.fee;
        tickSpacing = poolKey_.tickSpacing;
        hooks = address(poolKey_.hooks);
    }

    /// @inheritdoc ISteadyExecutor
    /// @dev Dual cross-chain auth: `authorizedSenderOnly` enforces msg.sender == the callback proxy
    ///      (the only address in the AbstractCallback ACL, so no arbitrary EOA can call this), and
    ///      `onlyReactive` enforces the proxy-injected `sender` == the configured reactive RVM id.
    ///      Both are required to prevent spoofing.
    function executePlan(address sender, uint256 planId)
        external
        nonReentrant
        authorizedSenderOnly
        onlyReactive(sender)
    {
        ISteadyPlanRegistry.Plan memory plan = registry.getPlan(planId);

        // Direction & pool sanity: the plan's tokens must be the pool's currencies.
        bool zeroForOne;
        if (plan.tokenIn == Currency.unwrap(currency0) && plan.tokenOut == Currency.unwrap(currency1)) {
            zeroForOne = true;
        } else if (plan.tokenIn == Currency.unwrap(currency1) && plan.tokenOut == Currency.unwrap(currency0)) {
            zeroForOne = false;
        } else {
            revert PoolMismatch();
        }

        // Effect first: consume the due slot (reverts unless due) — replay guard.
        registry.advanceSchedule(planId);

        // Pull the funding token from the vault into this contract.
        vault.debit(planId, plan.amountIn, address(this));

        // Swap via the PoolManager and deliver the output to the plan owner.
        bytes memory result = poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    zeroForOne: zeroForOne,
                    amountIn: plan.amountIn,
                    inputToken: plan.tokenIn,
                    recipient: plan.owner
                })
            )
        );
        uint256 amountOut = abi.decode(result, (uint256));

        if (amountOut < minAmountOut[planId]) revert SlippageExceeded();

        emit Executed(planId, plan.amountIn, amountOut);
    }

    /// @notice PoolManager unlock callback — performs the swap, pays the input, takes the output.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapCallbackData memory d = abi.decode(data, (SwapCallbackData));

        PoolKey memory key = _poolKey();
        uint160 priceLimit = d.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.amountIn), // negative => exact input
                sqrtPriceLimitX96: priceLimit
            }),
            ""
        );

        (int128 amount0, int128 amount1) = (delta.amount0(), delta.amount1());
        (int128 inputDelta, int128 outputDelta) = d.zeroForOne ? (amount0, amount1) : (amount1, amount0);

        uint256 owed = uint256(uint128(-inputDelta));
        uint256 amountOut = uint256(uint128(outputDelta));

        // Pay the input token to the manager.
        Currency inputCurrency = Currency.wrap(d.inputToken);
        poolManager.sync(inputCurrency);
        IERC20(d.inputToken).safeTransfer(address(poolManager), owed);
        poolManager.settle();

        // Take the output token directly to the plan owner.
        Currency outputCurrency = d.zeroForOne ? currency1 : currency0;
        poolManager.take(outputCurrency, d.recipient, amountOut);

        return abi.encode(amountOut);
    }

    /// @inheritdoc ISteadyExecutor
    function setReactiveSender(address reactiveSender_) external onlyOwner {
        reactiveSender = reactiveSender_;
        emit ReactiveSenderUpdated(reactiveSender_);
    }

    /// @inheritdoc ISteadyExecutor
    function setMinAmountOut(uint256 planId, uint256 minOut) external {
        if (msg.sender != registry.getPlan(planId).owner) revert NotPlanOwner();
        minAmountOut[planId] = minOut;
        emit MinAmountOutUpdated(planId, minOut);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }
}
