// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ACL_OZ_5_2_0_Lib} from "./AccessControlLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "./Roles.sol";
import {LegacyAdminRolesLib} from "./LegacyAdminRolesLib.sol";

library MigrationLib {
    function migrateLegacyAdminRoles(address sender) external {
        bytes32[] memory legacyRoles = LegacyAdminRolesLib.getAllLegacyAdminRoles();

        address firstVaultManagerAdmin = _getFirstRoleMember(LegacyAdminRolesLib.VAULT_MANAGER_ADMIN);

        if (firstVaultManagerAdmin != address(0)) {
            ACL_OZ_5_2_0_Lib._grantRole(RolesLib.ROLE_ADMIN, firstVaultManagerAdmin, sender);

            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.VAULT_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.HOOK_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.STRATEGY_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.ALLOCATOR, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.WITHDRAWAL_MANAGER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.PAUSER, RolesLib.ROLE_ADMIN);
            ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.ROLE_ADMIN, RolesLib.ROLE_ADMIN);

            for (uint256 i = 0; i < legacyRoles.length; i++) {
                _revokeRoleFromAllMembers(legacyRoles[i], sender);
            }
        }
    }

    function _getFirstRoleMember(bytes32 role) private view returns (address) {
        uint256 memberCount = ACL_OZ_5_2_0_Lib._getRoleMemberCount(role);
        if (memberCount == 0) return address(0);
        return ACL_OZ_5_2_0_Lib._getRoleMember(role, 0);
    }

    function _revokeRoleFromAllMembers(bytes32 role, address sender) private {
        uint256 memberCount = ACL_OZ_5_2_0_Lib._getRoleMemberCount(role);
        for (uint256 i = memberCount; i > 0; i--) {
            address member = ACL_OZ_5_2_0_Lib._getRoleMember(role, i - 1);
            ACL_OZ_5_2_0_Lib._revokeRole(role, member, sender);
        }
    }
}
