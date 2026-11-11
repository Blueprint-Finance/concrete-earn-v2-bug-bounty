// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {AccessControl} from "@openzeppelin-contracts/access/AccessControl.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin-contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {AccessControlEnumerable} from "@openzeppelin-contracts/access/extensions/AccessControlEnumerable.sol";

/**
 * @title AccessControlDefaultAdminRulesEnumerable
 * @notice Abstract contract combining AccessControlDefaultAdminRules and AccessControlEnumerable
 * @dev Provides both:
 *      - Default admin rules with 2-step transfer and configurable delays (AccessControlDefaultAdminRules)
 *      - Role enumeration capabilities (AccessControlEnumerable)
 */
abstract contract AccessControlDefaultAdminRulesEnumerable is AccessControlDefaultAdminRules, AccessControlEnumerable {
    /**
     * @dev Initializes the contract with a default admin and transfer delay.
     * @param initialDelay The initial delay for admin transfers
     * @param initialDefaultAdmin The initial default admin address
     */
    constructor(uint48 initialDelay, address initialDefaultAdmin)
        AccessControlDefaultAdminRules(initialDelay, initialDefaultAdmin)
    {}

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlDefaultAdminRules, AccessControlEnumerable)
        returns (bool)
    {
        return AccessControlDefaultAdminRules.supportsInterface(interfaceId)
            || AccessControlEnumerable.supportsInterface(interfaceId);
    }

    /**
     * @dev See {AccessControl-grantRole}.
     */
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlDefaultAdminRules, AccessControl, IAccessControl)
    {
        super.grantRole(role, account);
    }

    /**
     * @dev See {AccessControl-revokeRole}.
     */
    function revokeRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlDefaultAdminRules, AccessControl, IAccessControl)
    {
        super.revokeRole(role, account);
    }

    /**
     * @dev See {AccessControl-renounceRole}.
     */
    function renounceRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlDefaultAdminRules, AccessControl, IAccessControl)
    {
        super.renounceRole(role, account);
    }

    /**
     * @dev See {AccessControl-_setRoleAdmin}.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole)
        internal
        virtual
        override(AccessControlDefaultAdminRules, AccessControl)
    {
        super._setRoleAdmin(role, adminRole);
    }

    /**
     * @dev See {AccessControl-_grantRole}.
     */
    function _grantRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlDefaultAdminRules, AccessControlEnumerable)
        returns (bool)
    {
        return super._grantRole(role, account);
    }

    /**
     * @dev See {AccessControl-_revokeRole}.
     */
    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlDefaultAdminRules, AccessControlEnumerable)
        returns (bool)
    {
        return super._revokeRole(role, account);
    }
}
