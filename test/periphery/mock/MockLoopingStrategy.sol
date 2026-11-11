// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {BaseLoopingStrategy} from "../../../src/periphery/strategies/BaseLoopingStrategy.sol";
import {TokenPair} from "../../../src/periphery/interface/ILoopingPrimitive.sol";
import {IStrategyTemplate, StrategyType} from "../../../src/interface/IStrategyTemplate.sol";
import {BaseStrategyStorageLib} from "../../../src/periphery/lib/BaseStrategyStorageLib.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";

contract MockLoopingStrategy is BaseLoopingStrategy {
    function initialize(address admin, address vault_, address lenderModule) external virtual initializer {
        __BaseStrategy_init(admin, vault_, address(0));
        __BaseLoopingStrategy_init(lenderModule);
    }

    function strategyType() public pure override returns (StrategyType) {
        return StrategyType.ATOMIC;
    }

    function ID() public pure override returns (uint64) {
        // contractType=2 (strategy), flavour=999 (mock looping strategy), version=1.1.0 (major=1, minor=1, patch=0)
        return uint64(299910100); // ContractIdEncoding.encode(2, 999, 1, 01, 00);
    }
}
