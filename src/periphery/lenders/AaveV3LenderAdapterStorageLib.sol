// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

library AaveV3LenderAdapterStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.AaveV3LenderAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AaveV3LenderAdapterStorageLocation =
        0x59d4d1b0310943383b96c755e3958a74c7192ae52b1923abe430f18d3eb70a00;

    /// @custom:storage-location erc7201:concrete.storage.AaveV3LenderAdapter
    struct AaveV3LenderAdapterStorage {
        uint256 interestRateMode;
        address strategy;
    }

    /**
     * @dev Get the storage struct
     */
    function fetch() internal pure returns (AaveV3LenderAdapterStorage storage $) {
        assembly {
            $.slot := AaveV3LenderAdapterStorageLocation
        }
    }
}
