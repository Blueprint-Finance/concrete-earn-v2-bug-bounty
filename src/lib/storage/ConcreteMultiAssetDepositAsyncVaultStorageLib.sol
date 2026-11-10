// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

library ConcreteMultiAssetDepositAsyncVaultStorageLib {
    /// @dev cast index-erc7201 "concrete.storage.ConcreteMultiAssetDepositAsyncVaultStorage"
    bytes32 private constant ConcreteMultiAssetDepositAsyncVaultStorageLocation =
        0x9df39c6f7da6d5919e719e174ff6669521e13cfb891a2e60ff5ca276f25b7100;

    /// @custom:storage-location erc7201:concrete.storage.ConcreteMultiAssetDepositAsyncVaultStorage
    struct ConcreteMultiAssetDepositAsyncVaultStorage {
        /// @dev Set of non-base deposit assets accepted by the vault.
        EnumerableSet.AddressSet whitelistedAssets;
        /// @dev Asset pricer used to value non-base deposits in base units.
        address pricer;
        /// @dev Single strategy that receives non-base deposits (must be a registered, Active strategy).
        ///      Designated by VAULT_MANAGER through `configureMultiAsset` (timelocked), but also
        ///      maintained by the registry lifecycle via {StateSetterMASLib}: cleared to `address(0)`
        ///      when the designated strategy is removed, moved onto the successor when it is
        ///      reconciled. `address(0)` therefore means "not currently designated".
        address strategy;
    }

    function fetch() internal pure returns (ConcreteMultiAssetDepositAsyncVaultStorage storage $) {
        assembly {
            $.slot := ConcreteMultiAssetDepositAsyncVaultStorageLocation
        }
    }
}
