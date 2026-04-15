// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {BaseLoopingStrategy} from "./BaseLoopingStrategy.sol";
import {StrategyType} from "../../interface/IStrategyTemplate.sol";

/**
 * @title ConcreteStandardLoopingStrategy
 * @notice A standard looping strategy for Concrete.
 */
contract ConcreteStandardLoopingStrategy is BaseLoopingStrategy {
    //--------------------------------------------------------
    // Initializer
    //--------------------------------------------------------

    function initialize(address admin, address vault_, address lenderModule) external virtual reinitializer(1) {
        __BaseStrategy_init(admin, vault_);
        __BaseLoopingStrategy_init(lenderModule);
    }

    //--------------------------------------------------------
    // Strategy Type
    //--------------------------------------------------------

    function strategyType() external pure override returns (StrategyType) {
        return StrategyType.ATOMIC;
    }

    function ID() public pure override returns (uint64) {
        // contractType=2 (strategy), flavour=3 (concrete standard looping strategy), version=1.1.0 (major=1, minor=1, patch=0)
        return uint64(200310100); // ContractIdEncoding.encode(2, 3, 1, 01, 00);
    }
}
