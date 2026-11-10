// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

library PeripheryFactoryStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.PeripheryFactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PeripheryFactoryStorageLocation =
        0xc57b9181734711449c6174643141c6b5854d4e37846989b9214d7aff93543d00;

    /// @dev Packed registration record for a strategy proxy.
    ///      `bool registered` and `address proxyAdmin` fit in a single 32-byte slot.
    ///      proxyAdmin is address(0) for strategies registered without upgrade capability.
    struct StrategyData {
        bool registered;
        address proxyAdmin;
    }

    /// @custom:storage-location erc7201:concrete.storage.PeripheryFactoryStorage
    struct PFStorage {
        // ── Strategy registry ─────────────────────────────────────────────
        /// @dev implId → approved strategy implementation address
        mapping(uint64 => address) strategyImpls;
        /// @dev implId → blocked
        mapping(uint64 => bool) strategyBlocked;
        /// @dev fromImplId → toImplId → allowed
        mapping(uint64 => mapping(uint64 => bool)) strategyMigratable;
        /// @dev proxy address → registration record (registered=false means not tracked)
        mapping(address => StrategyData) strategies;
        // ── PMH clone registry ────────────────────────────────────────────
        /// @dev implId → approved PMH implementation address
        mapping(uint64 => address) pmhImpls;
        /// @dev implId → blocked
        mapping(uint64 => bool) pmhBlocked;
        /// @dev clone address → registered (cloned by this factory)
        mapping(address => bool) pmhClones;
        // ── Hook clone registry ───────────────────────────────────────────
        /// @dev implId → approved hook implementation address
        mapping(uint64 => address) hookImpls;
        /// @dev implId → blocked
        mapping(uint64 => bool) hookBlocked;
        /// @dev clone address → registered (cloned by this factory)
        mapping(address => bool) hookClones;
        // ── Access control ────────────────────────────────────────────────
        /// @dev Holder of the FACTORY_MANAGER role, handling frequent operational
        ///      functions kept strictly separate from the owner's high-privilege functions.
        address factoryManager;
    }

    /// @dev Returns the EIP-7201 storage struct for this library.
    function fetch() internal pure returns (PFStorage storage $) {
        assembly {
            $.slot := PeripheryFactoryStorageLocation
        }
    }
}
