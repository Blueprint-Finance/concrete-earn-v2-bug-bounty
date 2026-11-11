// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title TimelockRolesLib
 * @notice `bytes32` role identifiers consumed by the {Timelock} contract.
 *
 * @dev Roles are stored and checked by OpenZeppelin's
 *      `AccessControlEnumerableUpgradeable`. They are exposed here as a
 *      shared compile-time surface so off-chain tooling, deployment scripts,
 *      and adjacent contracts can reference them without depending on the
 *      `Timelock` implementation.
 *
 * @custom:protocol Concrete Earn V2
 */
library TimelockRolesLib {
    /// @notice Proposes new schedule entries via {Timelock.propose}.
    bytes32 internal constant PROPOSER_ROLE = keccak256("TIMELOCK_PROPOSER_ROLE");

    /// @notice Cancels queued actions via {Timelock.cancel}.
    bytes32 internal constant GUARDIAN_ROLE = keccak256("TIMELOCK_GUARDIAN_ROLE");

    /// @notice Updates tier delays and the artifact registry.
    ///         High-threshold multisig.
    bytes32 internal constant CONFIG_ROLE = keccak256("TIMELOCK_CONFIG_ROLE");

    /// @notice Compresses a queued action's `readyAt` to the current block
    ///         via {Timelock.overrideTimelock}. Very-high-threshold multisig.
    bytes32 internal constant OVERRIDE_ROLE = keccak256("TIMELOCK_OVERRIDE_ROLE");

    /// @notice Authorizes UUPS upgrades. Upgrades are also self-timelocked:
    ///         the `upgradeToAndCall` selector is registered under
    ///         {TimelockContractTypesLib.CT_TIMELOCK} and gated by
    ///         {Timelock.afterDelay}.
    bytes32 internal constant UPGRADER_ROLE = keccak256("TIMELOCK_UPGRADER_ROLE");

    /// @notice Removes schedule entries that have passed their staleness window
    ///         (`readyAt + STALENESS_WINDOW`). Intended for backend automation /
    ///         keeper bots. Cannot touch pending or matured-but-fresh entries.
    bytes32 internal constant JANITOR_ROLE = keccak256("TIMELOCK_JANITOR_ROLE");
}
