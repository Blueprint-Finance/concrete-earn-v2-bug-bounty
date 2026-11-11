// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

library ConcreteFactoryBaseStorageLib {
    struct ConcreteFactoryBaseStorage {
        /// @dev Set of approved implementation addresses that can be used to deploy new vaults
        // This Factory depends on EnumerableSet ordering.
        // MUST NOT call `remove`, as the order is only reliable when elements are never removed.
        EnumerableSet.AddressSet legacyImplementationSet;
        /// @dev Mapping of implementation addresses to boolean values indicating if the implementation is blocked
        mapping(uint64 vaultImpl => bool blocked) blocked;
        /// @dev Mapping indicating if a vault ID is migratable to another vault ID
        mapping(uint64 fromVaultImpl => mapping(uint64 toVaultImpl => bool)) migratable;
        /// @dev Mapping to track deployed vaults from this factory
        mapping(address => bool) vaults;
        /// @dev Mapping of vault IDs to implementation addresses
        mapping(uint64 vaultImpl => address implementation) vaultImplToImplementation;
        /// @dev Address holding the FACTORY_MANAGER role, assignable only by the owner
        address factoryManager;
    }

    // keccak256(abi.encode(uint256(keccak256("concrete.storage.ConcreteFactoryBaseStorage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 constant CONCRETE_FACTORY_STORAGE_SLOT = 0x8e455bed11907189c537a36ae6131c14495d217d4f7af335ce892f553df45a00;

    function fetch() internal pure returns (ConcreteFactoryBaseStorage storage concreteFactoryBaseStorage) {
        bytes32 slot = CONCRETE_FACTORY_STORAGE_SLOT;
        assembly {
            concreteFactoryBaseStorage.slot := slot
        }
    }
}
