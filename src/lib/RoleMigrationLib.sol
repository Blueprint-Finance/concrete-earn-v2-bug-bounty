// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ACL_OZ_5_2_0_Lib} from "./AccessControlLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "./Roles.sol";
import {LegacyAdminRolesLib} from "./LegacyAdminRolesLib.sol";

/**
 * @title RoleMigrationLib
 * @dev Library for migrating from legacy admin roles to ROLE_ADMIN
 */
library RoleMigrationLib {
    /**
     * @dev Migrates legacy admin roles to ROLE_ADMIN
     * @dev Gets the first VAULT_MANAGER_ADMIN member (if any) and grants them ROLE_ADMIN
     * @dev Updates all role admin relationships to use ROLE_ADMIN
     * @dev Then revokes all legacy admin roles from all their members
     * @param sender The address performing the migration (typically the factory or upgrade caller)
     */
    function migrateLegacyAdminRoles(address sender) external {
        // Get all legacy admin roles
        bytes32[] memory legacyRoles = LegacyAdminRolesLib.getAllLegacyAdminRoles();

        // Try to get the first VAULT_MANAGER_ADMIN member
        address firstVaultManagerAdmin = _getFirstRoleMember(LegacyAdminRolesLib.VAULT_MANAGER_ADMIN);

        // If VAULT_MANAGER_ADMIN has members, grant ROLE_ADMIN to the first one
        if (firstVaultManagerAdmin != address(0)) {
            ACL_OZ_5_2_0_Lib._grantRole(RolesLib.ROLE_ADMIN, firstVaultManagerAdmin, sender);

            // Update all role admin relationships to use ROLE_ADMIN
            // This must be done BEFORE revoking legacy admin roles, otherwise we won't have permission
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.VAULT_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.HOOK_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.STRATEGY_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.ALLOCATOR, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.WITHDRAWAL_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.PAUSER, RolesLib.ROLE_ADMIN);

            // ROLE_ADMIN is self-admin
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.ROLE_ADMIN, RolesLib.ROLE_ADMIN);

            // Revoke all legacy admin roles from all their members
            for (uint256 i = 0; i < legacyRoles.length; i++) {
                _revokeRoleFromAllMembers(legacyRoles[i], sender);
            }
        }
    }

    /**
     * @dev Gets the first member of a role, or address(0) if the role has no members
     * @param role The role to get the first member from
     * @return The first member address, or address(0) if none
     */
    function _getFirstRoleMember(bytes32 role) private view returns (address) {
        uint256 memberCount = ACL_OZ_5_2_0_Lib._getRoleMemberCount(role);
        if (memberCount == 0) {
            return address(0);
        }
        return ACL_OZ_5_2_0_Lib._getRoleMember(role, 0);
    }

    /**
     * @dev Revokes a role from all its members
     * @param role The role to revoke from all members
     * @param sender The address performing the revocation
     */
    function _revokeRoleFromAllMembers(bytes32 role, address sender) private {
        uint256 memberCount = ACL_OZ_5_2_0_Lib._getRoleMemberCount(role);

        // Iterate backwards to avoid index shifting issues when removing members
        // Note: EnumerableSet removes by swapping with last element, so we iterate backwards
        for (uint256 i = memberCount; i > 0; i--) {
            address member = ACL_OZ_5_2_0_Lib._getRoleMember(role, i - 1);
            ACL_OZ_5_2_0_Lib._revokeRole(role, member, sender);
        }
    }
}

