// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IHurdleRateOracle} from "../../src/interface/IHurdleRateOracle.sol";

contract MockHurdleRateOracle is IHurdleRateOracle {
    uint256 private immutable _precision;
    uint256 private _hurdleRate;

    constructor(uint8 decimals_) {
        _precision = 10 ** uint256(decimals_);
    }

    function setHurdleRate(uint256 rate) external {
        _hurdleRate = rate;
    }

    function precision() external view override returns (uint256) {
        return _precision;
    }

    function getHurdleRate() external view override returns (uint256) {
        return _hurdleRate;
    }
}
