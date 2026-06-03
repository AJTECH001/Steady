// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ISteadyVault} from "steady/interfaces/ISteadyVault.sol";
import {ISteadyPlanRegistry} from "steady/interfaces/ISteadyPlanRegistry.sol";

/// @notice Holds the tokenIn funding each plan and tracks per-plan balances.
/// @dev deposit/withdraw against the plan's tokenIn, plus the executor-gated `debit`
///      that pulls funds for execution. The registry is the source of truth for
///      ownership and token.
contract SteadyVault is ISteadyVault, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    ISteadyPlanRegistry public immutable registry;

    /// @inheritdoc ISteadyVault
    address public executor;

    mapping(uint256 planId => uint256 balance) private _balanceOf;

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    constructor(ISteadyPlanRegistry _registry, address initialOwner) Ownable(initialOwner) {
        registry = _registry;
    }

    /// @inheritdoc ISteadyVault
    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidExecutor();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @inheritdoc ISteadyVault
    /// @dev Anyone may fund a plan; funds are pulled in the plan's tokenIn.
    ///      Reverts via the registry if the plan does not exist.
    function deposit(uint256 planId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        ISteadyPlanRegistry.Plan memory plan = registry.getPlan(planId);

        _balanceOf[planId] += amount;
        IERC20(plan.tokenIn).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(planId, msg.sender, amount);
    }

    /// @inheritdoc ISteadyVault
    /// @dev Only the plan owner may withdraw, in the plan's tokenIn.
    function withdraw(uint256 planId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        ISteadyPlanRegistry.Plan memory plan = registry.getPlan(planId);
        if (msg.sender != plan.owner) revert NotPlanOwner();

        uint256 balance = _balanceOf[planId];
        if (amount > balance) revert InsufficientBalance();
        _balanceOf[planId] = balance - amount;

        IERC20(plan.tokenIn).safeTransfer(msg.sender, amount);

        emit Withdrawn(planId, msg.sender, amount);
    }

    /// @inheritdoc ISteadyVault
    /// @dev Pulls funds to `to` (the execution sink, e.g. the executor/router). Only the
    ///      registered executor may call this; balance accounting is updated before transfer.
    function debit(uint256 planId, uint256 amount, address to) external nonReentrant onlyExecutor {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = _balanceOf[planId];
        if (amount > balance) revert InsufficientBalance();
        _balanceOf[planId] = balance - amount;

        ISteadyPlanRegistry.Plan memory plan = registry.getPlan(planId);
        IERC20(plan.tokenIn).safeTransfer(to, amount);

        emit Debited(planId, to, amount);
    }

    /// @inheritdoc ISteadyVault
    function balanceOf(uint256 planId) external view returns (uint256) {
        return _balanceOf[planId];
    }
}
