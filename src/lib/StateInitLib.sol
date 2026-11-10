// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ACL_OZ_5_2_0_Lib} from "./AccessControlLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "../lib/Roles.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "../lib/storage/ConcreteStandardVaultImplStorageLib.sol";
import {ConcreteAsyncVaultImplStorageLib as AVLib} from "../lib/storage/ConcreteAsyncVaultImplStorageLib.sol";
import {
    ConcretePredepositVaultImplStorageLib as PDVLib
} from "../lib/storage/ConcretePredepositVaultImplStorageLib.sol";
import {IConcreteAsyncVaultImpl} from "../interface/IConcreteAsyncVaultImpl.sol";
import {MigrationLib} from "./MigrationLib.sol";
import {Time} from "./Time.sol";

library StateInitLib {
    function stateInitStandardVaultImpl(address allocateModuleAddr, address initialVaultManager, address sender)
        public
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        $.allocateModule = allocateModuleAddr;
        $.lastManagementFeeAccrual = Time.timestamp();

        $.maxGlobalDepositAmount = type(uint256).max;
        $.minTxDepositAmount = 0;
        $.maxTxWithdrawAmount = type(uint256).max;
        $.minTxWithdrawAmount = 0;

        // Setup role admins - all roles use ROLE_ADMIN
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.VAULT_MANAGER, RolesLib.ROLE_ADMIN);
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.HOOK_MANAGER, RolesLib.ROLE_ADMIN);
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.STRATEGY_MANAGER, RolesLib.ROLE_ADMIN);
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.ALLOCATOR, RolesLib.ROLE_ADMIN);
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.PAUSER, RolesLib.ROLE_ADMIN);

        // ROLE_ADMIN is self-admin
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.ROLE_ADMIN, RolesLib.ROLE_ADMIN);

        // Grant ROLE_ADMIN to the initial vault manager
        ACL_OZ_5_2_0_Lib._grantRole(RolesLib.ROLE_ADMIN, initialVaultManager, sender);

        // Grant manager role to the initial vault manager
        ACL_OZ_5_2_0_Lib._grantRole(RolesLib.VAULT_MANAGER, initialVaultManager, sender);
    }

    function stateInitAsyncVaultImpl(address initialVaultManager, address sender) public {
        _initAsyncCoreState();
    }

    /**
     * @dev Upgrade-path helper used by `ConcreteAsyncVaultImpl._upgrade`.
     *      Performs legacy role migration unconditionally, then runs the async-specific
     *      state init iff the async storage has never been initialised
     *      (`latestEpochID == 0` is the canonical sentinel: the init sets it to 1 and
     *      it only ever increases via `closeEpoch`).
     *      Designed to be invoked via DELEGATECALL from the vault proxy; `msg.sender` is
     *      preserved across the chain and forwarded to `migrateLegacyAdminRoles`.
     */
    function stateUpgradeAsyncVaultImpl(bytes calldata) public {
        MigrationLib.migrateLegacyAdminRoles(msg.sender);

        if (AVLib.fetch().latestEpochID == 0) _initAsyncCoreState();
    }

    function stateUpgradeStandardVaultImpl(bytes calldata) public {
        MigrationLib.migrateLegacyAdminRoles(msg.sender);
    }

    function stateUpgradePredepositVaultImpl(bytes calldata) public {
        MigrationLib.migrateLegacyAdminRoles(msg.sender);
        PDVLib.fetch().selfClaimsEnabled = false;
    }

    /**
     * @dev Single source of truth for the async-specific core state setup.
     *      Sets `isQueueActive = true`, `latestEpochID = 1`, the default
     *      `unwindCostCapBP = 500` (5 %), emits `WithdrawalQueueInitialized`,
     *      and wires the role admins for `WITHDRAWAL_MANAGER` and
     *      `PRIORITY_WITHDRAWAL_EXECUTOR` to `ROLE_ADMIN`.
     *      Callers are responsible for any idempotency guard.
     */
    function _initAsyncCoreState() private {
        AVLib.ConcreteAsyncVaultImplStorage storage $ = AVLib.fetch();

        $.isQueueActive = true;
        $.latestEpochID = 1;
        $.unwindCostCapBP = 500;
        emit IConcreteAsyncVaultImpl.WithdrawalQueueInitialized(1);

        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.WITHDRAWAL_MANAGER, RolesLib.ROLE_ADMIN);
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.PRIORITY_WITHDRAWAL_EXECUTOR, RolesLib.ROLE_ADMIN);
    }
}
