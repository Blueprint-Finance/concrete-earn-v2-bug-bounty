// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

library LoopingPrimitiveStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.LoopingPrimitive")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LoopingPrimitiveStorageLocation =
        0x3187427133d570994440e24f3226f0a32b1aca5261dc6ec2d0b87383c3013e00;

    /// @custom:storage-location erc7201:concrete.storage.LoopingPrimitiveStorage
    struct LoopingPrimitiveStorage {
        address flashModule;
        address swapModule;
    }

    /**
     * @dev Get the storage struct
     */
    function fetch() internal pure returns (LoopingPrimitiveStorage storage $) {
        assembly {
            $.slot := LoopingPrimitiveStorageLocation
        }
    }
}
