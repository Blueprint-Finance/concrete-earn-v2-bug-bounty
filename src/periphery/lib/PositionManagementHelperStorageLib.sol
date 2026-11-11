// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

library PositionManagementHelperStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.PositionManagementHelperStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PositionManagementHelperLocation =
        0x511f8edf9f5308fe45b8cf326632add5d69bb2bebe4973ea30d4474bd29a7100;

    /// @custom:storage-location erc7201:concrete.storage.PositionManagementHelperStorage
    struct PMHStorage {
        /// @dev The ERC4626 vault address where borrowed funds are deployed.
        address yieldVault;
        /// @dev Outsourced flash loan helper.
        address flashModule;
        /// @dev Outsourced swap helper.
        address swapModule;
        /// @dev Max allowed swap slippage for self-liquidation calls, in WAD (1e18 = 100%).
        uint64 maxSelfLiqSlippageInWad;
        /// @dev WAD buffer below the lender liquidation threshold that triggers self-liquidation.
        ///      e.g. 0.05e18 = 5% buffer (self-liq kicks in 5% below the liq threshold).
        uint64 selfLiqThrBufferInWad;
        /// @dev Centre of the healthy LTV band, in WAD (1e18 = 100%).
        ///      e.g. 0.6e18 = 60% LTV is the operating target.
        uint64 healthyLtvInWad;
        /// @dev Half-width of the healthy LTV band, in WAD.
        ///      LTVs in [healthyLtv − deviation, healthyLtv + deviation] are Healthy.
        uint64 healthyLtvDeviationInWad;
    }

    /// @dev Returns the EIP-7201 storage struct for this library.
    function fetch() internal pure returns (PMHStorage storage $) {
        assembly {
            $.slot := PositionManagementHelperLocation
        }
    }
}
