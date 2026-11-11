// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/**
 * @title AccessControlDefaultAdminRulesEnumerableUpgradeable
 * @notice Abstract upgradeable contract combining AccessControlDefaultAdminRules and AccessControlEnumerable
 * @dev Provides both:
 *      - Default admin rules with 2-step transfer and configurable delays (AccessControlDefaultAdminRules)
 *      - Role enumeration capabilities (AccessControlEnumerable)
 */
abstract contract AccessControlDefaultAdminRulesEnumerableUpgradeable is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    AccessControlEnumerableUpgradeable
{
    /**
     * @dev Initializes the contract with a default admin and transfer delay.
     * @param initialDelay The initial delay for admin transfers
     * @param initialDefaultAdmin The initial default admin address
     */
    function __AccessControlDefaultAdminRulesEnumerable_init(uint48 initialDelay, address initialDefaultAdmin)
        internal
        onlyInitializing
    {
        __AccessControlDefaultAdminRules_init(initialDelay, initialDefaultAdmin);
        __AccessControlEnumerable_init();
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return AccessControlDefaultAdminRulesUpgradeable.supportsInterface(interfaceId)
            || AccessControlEnumerableUpgradeable.supportsInterface(interfaceId);
    }

    /**
     * @dev See {AccessControl-grantRole}.
     */
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlUpgradeable, IAccessControl)
    {
        super.grantRole(role, account);
    }

    /**
     * @dev See {AccessControl-revokeRole}.
     */
    function revokeRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlUpgradeable, IAccessControl)
    {
        super.revokeRole(role, account);
    }

    /**
     * @dev See {AccessControl-renounceRole}.
     */
    function renounceRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlUpgradeable, IAccessControl)
    {
        super.renounceRole(role, account);
    }

    /**
     * @dev See {AccessControl-_setRoleAdmin}.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole)
        internal
        virtual
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlUpgradeable)
    {
        super._setRoleAdmin(role, adminRole);
    }

    /**
     * @dev See {AccessControl-_grantRole}.
     */
    function _grantRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlEnumerableUpgradeable)
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
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super._revokeRole(role, account);
    }
}
