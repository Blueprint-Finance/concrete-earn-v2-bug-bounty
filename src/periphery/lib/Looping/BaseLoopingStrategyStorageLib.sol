import {LoopConfig} from "./LoopConfigLib.sol";
import {TokenInfo} from "../TokenInfoLib.sol";

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

library BaseLoopingStrategyStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.BaseLoopingStrategyStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BaseLoopingStrategyStorageLocation =
        0xc8e18d6e7ed4848e715d5a33d4745482aff006bdcd19d4774bc4bee181038e00;

    /// @custom:storage-location erc7201:concrete.storage.BaseLoopingStrategyStorage
    struct BaseLoopingStorage {
        LoopConfig loopConfig;
        address lenderModule;
        uint64 targetLtvInWad;
        uint64 ltvAdditiveDeviationInWad;
        uint64 maxSlippageInWad;
        uint256 flashCollateralEpsilon;
    }

    /**
     * @dev Get the storage struct
     */
    function fetch() internal pure returns (BaseLoopingStorage storage $) {
        assembly {
            $.slot := BaseLoopingStrategyStorageLocation
        }
    }
}
