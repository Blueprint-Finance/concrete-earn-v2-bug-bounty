// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

library LenderModuleAaveV3StorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.LenderModuleAaveV3")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LenderModuleAaveV3StorageLocation =
        0x73666fd158f0c03607038da61a96d084d327b01e4f95e4db9ad15773bd4cb600;

    /// @custom:storage-location erc7201:concrete.storage.LenderModuleAaveV3
    struct LenderModuleAaveV3Storage {
        uint256 staged;
    }

    /**
     * @dev Get the storage struct
     */
    function fetch() internal pure returns (LenderModuleAaveV3Storage storage $) {
        assembly {
            $.slot := LenderModuleAaveV3StorageLocation
        }
    }
}
