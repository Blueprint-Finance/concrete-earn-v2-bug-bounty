// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC4626Upgradeable} from "@openzeppelin-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

library ERC4626_OZ_5_2_0_Lib {
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC4626StorageLocation =
        0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;

    function _getERC4626Storage() private pure returns (ERC4626Upgradeable.ERC4626Storage storage $) {
        assembly {
            $.slot := ERC4626StorageLocation
        }
    }

    function asset() public view returns (address) {
        return address(_getERC4626Storage()._asset);
    }

    function underlyingDecimals() public view returns (uint8) {
        return _getERC4626Storage()._underlyingDecimals;
    }
}
