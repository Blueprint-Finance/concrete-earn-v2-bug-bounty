// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

abstract contract AssetTraits {
    function _asset() internal view virtual returns (address);
}
