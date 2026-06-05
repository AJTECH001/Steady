// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ChainConfig
/// @notice Per-chain constants for Steady deployment.
/// @dev V4 PoolManager/PositionManager come from hookmate's AddressConstants. This holds the
///      Reactive Network callback-proxy addresses (verified from dev.reactive.network) and chain
///      ids. The Reactive callback proxy is the only contract permitted to invoke the executor's
///      `executePlan` on the destination chain.
library ChainConfig {
    // --- Reactive Network ---
    uint256 internal constant REACTIVE_LASNA = 5318007; // Reactive testnet (where ReactiveSteady lives)

    // --- Destination/origin testnets supported by Reactive (origin + destination) ---
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant ETHEREUM_SEPOLIA = 11155111;

    /// @notice Trigger event topic0 ReactiveSteady subscribes to: keccak256("PlanDue(uint256)").
    function planDueTopic0() internal pure returns (uint256) {
        return uint256(keccak256("PlanDue(uint256)"));
    }

    /// @notice Reactive callback-proxy address for a given destination chain id.
    /// @dev Reverts on unsupported chains so we never deploy against a wrong/zero proxy.
    function callbackProxy(uint256 chainId) internal pure returns (address) {
        if (chainId == UNICHAIN_SEPOLIA) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;
        if (chainId == BASE_SEPOLIA) return 0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6;
        if (chainId == ETHEREUM_SEPOLIA) return 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA;
        revert("ChainConfig: unsupported destination chain (no Reactive callback proxy)");
    }
}
