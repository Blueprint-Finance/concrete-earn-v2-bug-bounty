// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IChainlinkOracle} from "../../src/periphery/oracle/OracleModule.sol";

/// @dev Minimal Chainlink aggregator mock with a settable answer, for {OracleModule} based tests.
contract ChainlinkOracleMock is IChainlinkOracle {
    uint8 private immutable _decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId += 1;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
