// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title HookContainerStorageLib
 * @notice ERC-7201 namespaced storage for HookContainer
 */
library HookContainerStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.HookContainerStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant HookContainerStorageLocation =
        0xfdd720fa508e8cbe419a97da87511257764a4d18bd1a80e760ede6a32bd1ee00;

    /// @custom:storage-location erc7201:concrete.storage.HookContainerStorage
    struct HookContainerStorage {
        /// @dev Array of registered hook addresses
        address[] hooks;
        /// @dev Mapping to check if a hook is registered
        mapping(address hook => bool isRegistered) isHookRegistered;
    }

    /**
     * @dev Get the storage struct
     */
    function fetch() internal pure returns (HookContainerStorage storage $) {
        assembly {
            $.slot := HookContainerStorageLocation
        }
    }
}
