// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {HooksLibV2 as HooksLib, Hooks} from "../lib/Hooks.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "../lib/storage/ConcreteStandardVaultImplStorageLib.sol";

/**
 * @title ERC20UpgradeableWithTransferHook
 * @notice Mixin that injects pre/post transfer hook calls into the ERC20 `_update` flow.
 * @dev Only fires on actual transfers (both `from` and `to` are non-zero).
 *      Mints (`from == address(0)`) and burns (`to == address(0)`) bypass hooks entirely,
 *      as those operations have their own dedicated hook points in the vault.
 * @dev IMPORTANT: Reads hook configuration from ConcreteStandardVaultImplStorageLib.
 *      Only usable within the ConcreteStandardVaultImpl inheritance hierarchy.
 */
abstract contract ERC20UpgradeableWithTransferHook is ERC20Upgradeable {
    using HooksLib for Hooks;

    function _update(address from, address to, uint256 value) internal virtual override(ERC20Upgradeable) {
        if (from != address(0) && to != address(0)) {
            Hooks memory h = SVLib.fetch().hooks;
            if (h.checkIsValid(HooksLib.PRE_TRANSFER)) {
                h.preTransfer(_msgSender(), from, to, value);
            }
            ERC20Upgradeable._update(from, to, value);
            if (h.checkIsValid(HooksLib.POST_TRANSFER)) {
                h.postTransfer(_msgSender(), from, to, value);
            }
        } else {
            ERC20Upgradeable._update(from, to, value);
        }
    }
}
