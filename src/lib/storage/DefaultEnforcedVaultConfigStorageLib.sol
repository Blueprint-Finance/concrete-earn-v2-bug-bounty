// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDefaultEnforcedVaultConfiguration} from "../../interface/IDefaultEnforcedVaultConfiguration.sol";

/**
 * @title DefaultEnforcedVaultConfigStorageLib
 * @notice EIP-7201 namespaced storage for default vault configuration enforced by the factory.
 * @dev Separate storage namespace to allow future extensions without collision with ConcreteFactoryBaseStorage.
 */
library DefaultEnforcedVaultConfigStorageLib {
    // keccak256(abi.encode(uint256(keccak256("concrete.storage.DefaultEnforcedVaultConfig")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 constant STORAGE_SLOT = 0xcec7717545173d904c258c2640e9630f3a9519a1225b81fa4d9a89ebaeb81100;

    function fetch()
        internal
        pure
        returns (IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration storage config)
    {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            config.slot := slot
        }
    }
}
