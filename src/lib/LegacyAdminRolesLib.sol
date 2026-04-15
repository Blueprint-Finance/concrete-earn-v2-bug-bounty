// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LegacyAdminRolesLib
 * @dev Library containing legacy admin role definitions that were replaced by ROLE_ADMIN
 */
library LegacyAdminRolesLib {
    /// @dev Legacy admin roles (deprecated, replaced by ROLE_ADMIN)
    bytes32 public constant VAULT_MANAGER_ADMIN = keccak256("VAULT_MANAGER_ADMIN");
    bytes32 public constant HOOK_MANAGER_ADMIN = keccak256("HOOK_MANAGER_ADMIN");
    bytes32 public constant STRATEGY_MANAGER_ADMIN = keccak256("STRATEGY_MANAGER_ADMIN");
    bytes32 public constant ALLOCATOR_ADMIN = keccak256("ALLOCATOR_ADMIN");
    bytes32 public constant WITHDRAWAL_MANAGER_ADMIN = keccak256("WITHDRAWAL_MANAGER_ADMIN");
    bytes32 public constant PAUSER_ADMIN = keccak256("PAUSER_ADMIN");

    /**
     * @dev Returns all legacy admin roles as an array
     * @return roles Array of legacy admin role bytes32 values
     */
    function getAllLegacyAdminRoles() public pure returns (bytes32[] memory roles) {
        roles = new bytes32[](6);
        roles[0] = VAULT_MANAGER_ADMIN;
        roles[1] = HOOK_MANAGER_ADMIN;
        roles[2] = STRATEGY_MANAGER_ADMIN;
        roles[3] = ALLOCATOR_ADMIN;
        roles[4] = WITHDRAWAL_MANAGER_ADMIN;
        roles[5] = PAUSER_ADMIN;
    }
}

