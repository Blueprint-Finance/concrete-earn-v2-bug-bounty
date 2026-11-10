// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

library PositionHelperMorphoStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.PositionHelperMorphoStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MorphoStorageLocation = 0x52b46c32f9d2658dd06077e03174f2a64f38b54626b2253a6541731bd07ba200;

    /// @custom:storage-location erc7201:concrete.storage.PositionHelperMorphoStorage
    struct MorphoStorage {
        /// @dev Oracle address for this market (returns collateral/loan price scaled by 1e36).
        address oracle;
        /// @dev Interest Rate Model address for this market.
        address irm;
        /// @dev Liquidation LTV for this market, WAD-scaled (1e18 = 100%).
        uint256 lltv;
        /// @dev Morpho market ID, derived from MarketParams at initialize time.
        Id marketId;
    }

    /// @dev Returns the EIP-7201 storage struct for this library.
    function fetch() internal pure returns (MorphoStorage storage $) {
        assembly {
            $.slot := MorphoStorageLocation
        }
    }
}
