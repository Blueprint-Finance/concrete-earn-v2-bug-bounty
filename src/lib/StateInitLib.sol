// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ACL_OZ_5_2_0_Lib} from "./AccessControlLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "../lib/Roles.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "../lib/storage/ConcreteStandardVaultImplStorageLib.sol";
import {ConcreteAsyncVaultImplStorageLib as AVLib} from "../lib/storage/ConcreteAsyncVaultImplStorageLib.sol";
import {IConcreteAsyncVaultImpl} from "../interface/IConcreteAsyncVaultImpl.sol";
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
        AVLib.ConcreteAsyncVaultImplStorage storage $ = AVLib.fetch();

        // Set initial epoch to 1,
        $.isQueueActive = true;
        $.latestEpochID = 1;
        // @dev Default unwind cost cap is 5% (500 basis points). Admin should set appropriate value post deployment.
        $.unwindCostCapBP = 500;
        emit IConcreteAsyncVaultImpl.WithdrawalQueueInitialized($.latestEpochID);

        // Setup role admin - WITHDRAWAL_MANAGER uses ROLE_ADMIN
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.WITHDRAWAL_MANAGER, RolesLib.ROLE_ADMIN);
        ACL_OZ_5_2_0_Lib._setRoleAdmin(RolesLib.PRIORITY_WITHDRAWAL_EXECUTOR, RolesLib.ROLE_ADMIN);
    }
}
