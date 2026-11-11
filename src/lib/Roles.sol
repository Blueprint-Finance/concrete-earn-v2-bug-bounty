// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library ConcreteV2RolesLib {
    /// Roles
    bytes32 public constant VAULT_MANAGER = keccak256("VAULT_MANAGER");
    bytes32 public constant HOOK_MANAGER = keccak256("HOOK_MANAGER");
    bytes32 public constant STRATEGY_MANAGER = keccak256("STRATEGY_MANAGER");
    bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");
    bytes32 public constant WITHDRAWAL_MANAGER = keccak256("WITHDRAWAL_MANAGER");
    bytes32 public constant PAUSER = keccak256("PAUSER");
    bytes32 public constant PRIORITY_WITHDRAWAL_EXECUTOR = keccak256("PRIORITY_WITHDRAWAL_EXECUTOR");

    /// Single role admin for all roles
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
}
