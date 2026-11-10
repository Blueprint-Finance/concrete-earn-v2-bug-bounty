// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {BaseLoopingStrategy} from "./BaseLoopingStrategy.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";
import {StrategyType} from "../../interface/IStrategyTemplate.sol";

/**
 * @title ConcreteStandardLoopingStrategy
 * @notice A standard looping strategy for Concrete.
 */
contract ConcreteStandardLoopingStrategy is BaseLoopingStrategy {
    //--------------------------------------------------------
    // Initializer
    //--------------------------------------------------------

    function initialize(address admin, address vault_, address lenderModule, address timelock_)
        external
        virtual
        reinitializer(1)
    {
        __BaseStrategy_init(admin, vault_, timelock_);
        __BaseLoopingStrategy_init(lenderModule);
    }

    //--------------------------------------------------------
    // Strategy Type
    //--------------------------------------------------------

    function strategyType() external pure override returns (StrategyType) {
        return StrategyType.ATOMIC;
    }

    function FLAVOUR() public pure virtual returns (uint256) {
        return 3; // concrete standard looping strategy
    }

    function ID() public pure override returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 6, 0);
    }
}
