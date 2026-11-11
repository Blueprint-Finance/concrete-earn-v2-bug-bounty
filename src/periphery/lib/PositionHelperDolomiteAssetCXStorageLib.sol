// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

library PositionHelperDolomiteAssetCXStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.PositionHelperDolomiteAssetCXStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DolomiteAssetCXStorageLocation =
        0x4adda0e9865c99f0549ca159a8e702598a55ca0f98f93ab9c42b8e9044988700;

    /// @custom:storage-location erc7201:concrete.storage.PositionHelperDolomiteAssetCXStorage
    struct DolomiteAssetCXStorage {
        /// @dev Liquidation module used to unwind isolation-mode / asset-conversion collateral
        ///      that cannot be sold directly through a Dolomite exchange wrapper.
        address liquidationModule;
        /// @dev Second collateral type tracked by AssetCX positions, redeemable against the
        ///      primary collateral (e.g. a receipt/claim token for an underlying asset conversion).
        address redemptionClaimToken;
        /// @dev Dolomite market ID for `redemptionClaimToken`.
        uint256 redemptionClaimMarketId;
        /// @dev Receiver of redeemed collateral passed to `liquidationModule` as the
        ///      `initiateLiquidationCollateralSwap` `receiver` argument.
        address liquidator;
    }

    /// @dev Returns the EIP-7201 storage struct for this library.
    function fetch() internal pure returns (DolomiteAssetCXStorage storage $) {
        assembly {
            $.slot := DolomiteAssetCXStorageLocation
        }
    }
}
