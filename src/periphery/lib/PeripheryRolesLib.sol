// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title PeripheryRolesLib
 * @dev Library containing role definitions for periphery contracts
 */
library PeripheryRolesLib {
    /// @dev Role for operators that can adjust total assets in strategies
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @dev Role for strategy administrators
    bytes32 public constant STRATEGY_ADMIN = keccak256("STRATEGY_ADMIN");

    /// @dev Role for pausing strategies
    bytes32 public constant PAUSER = keccak256("PAUSER");

    /// @dev Role for managing hooks in containers
    bytes32 public constant HOOK_MANAGER_ROLE = keccak256("HOOK_MANAGER_ROLE");

    /// @dev Single role admin for all periphery roles
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
}
