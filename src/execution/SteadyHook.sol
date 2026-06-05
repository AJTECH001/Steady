// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Uniswap V4 dynamic-fee hook for Steady.
/// @dev Built on OpenZeppelin's audited `BaseOverrideFee`, which enforces a dynamic-fee pool and
///      applies the fee returned by `_getFee` via the override-fee flag in `beforeSwap`.
///
///      Policy: swaps initiated by the SteadyExecutor (recurring savings executions) are charged
///      `steadyFee` (e.g. 0 — fee-free DCA), while all other swappers are charged `defaultFee`.
///      The pool must be initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG` and this hook.
///
///      Deploy note: this hook must be deployed to an address whose low bits encode the
///      {afterInitialize, beforeSwap} permissions (mine via HookMiner / `deployCodeTo` in tests).
///      The executor address is set post-deploy via {setExecutor} to avoid a deploy-time cycle with
///      the executor (whose PoolKey references this hook).
contract SteadyHook is BaseOverrideFee, Ownable {
    using LPFeeLibrary for uint24;

    /// @notice Max valid LP fee (100% in hundredths of a bip).
    uint24 public constant MAX_FEE = LPFeeLibrary.MAX_LP_FEE;

    /// @notice Address whose swaps are treated as Steady executions and charged `steadyFee`.
    address public steadyExecutor;

    /// @notice Fee charged to ordinary swappers (hundredths of a bip; 3000 = 0.30%).
    uint24 public defaultFee;

    /// @notice Fee charged to Steady executions (hundredths of a bip; 0 = fee-free).
    uint24 public steadyFee;

    event ExecutorUpdated(address indexed executor);
    event FeesUpdated(uint24 defaultFee, uint24 steadyFee);

    error InvalidFee();

    constructor(IPoolManager poolManager_, uint24 defaultFee_, uint24 steadyFee_, address initialOwner_)
        BaseOverrideFee(poolManager_)
        Ownable(initialOwner_)
    {
        _setFees(defaultFee_, steadyFee_);
    }

    /// @notice Owner sets the executor whose swaps receive the Steady fee.
    function setExecutor(address executor_) external onlyOwner {
        steadyExecutor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @notice Owner updates the default and Steady fees.
    function setFees(uint24 defaultFee_, uint24 steadyFee_) external onlyOwner {
        _setFees(defaultFee_, steadyFee_);
    }

    function _setFees(uint24 defaultFee_, uint24 steadyFee_) internal {
        if (defaultFee_ > MAX_FEE || steadyFee_ > MAX_FEE) revert InvalidFee();
        defaultFee = defaultFee_;
        steadyFee = steadyFee_;
        emit FeesUpdated(defaultFee_, steadyFee_);
    }

    /// @inheritdoc BaseOverrideFee
    /// @dev `sender` is the address that called `swap` on the PoolManager — i.e. the SteadyExecutor
    ///      when it executes a plan. Steady executions pay `steadyFee`; everyone else pays `defaultFee`.
    function _getFee(address sender, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return sender == steadyExecutor ? steadyFee : defaultFee;
    }
}
