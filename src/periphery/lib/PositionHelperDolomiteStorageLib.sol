// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

library PositionHelperDolomiteStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.PositionHelperDolomiteStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DolomiteStorageLocation =
        0xd87da29cd614c1c856e3e8dcb9fd2679cef36d9564a9833fc9335e8b2a04c100;

    /// @custom:storage-location erc7201:concrete.storage.PositionHelperDolomiteStorage
    struct DolomiteStorage {
        /// @dev Dolomite-whitelisted exchange wrapper used for native self-liquidation.
        ///      When non-zero, `selfLiquidateDolomiteNative` and `selfLiquidateDolomiteNativeToLtv`
        ///      sell collateral directly via Dolomite's intrinsic `Sell` action instead of
        ///      routing through the flash-loan + swap module path.
        address dolomiteExchangeWrapper;
    }

    /// @dev Returns the EIP-7201 storage struct for this library.
    function fetch() internal pure returns (DolomiteStorage storage $) {
        assembly {
            $.slot := DolomiteStorageLocation
        }
    }
}
