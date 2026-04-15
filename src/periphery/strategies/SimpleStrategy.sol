// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {BaseStrategyStorageLib as BaseStrategyStorage} from "../lib/BaseStrategyStorageLib.sol";
import {SimpleStrategyStorageLib as SimpleStrategyStorage} from "../lib/SimpleStrategyStorageLib.sol";
import {StrategyType} from "../../interface/IStrategyTemplate.sol";

/**
 * @title SimpleStrategy
 * @dev A simple strategy implementation that holds assets without generating yield.
 * @dev This strategy serves as a concrete implementation for strategies that simply hold assets
 *      and can be used for testing or as a fallback strategy.
 * @dev Uses EIP-7201 storage layout for upgradeability and caches deposit balance in storage.
 */
contract SimpleStrategy is BaseStrategy {
    function ID() public pure virtual override(BaseStrategy) returns (uint64) {
        // contractType=2 (strategy), flavour=1 (simple-strategy), version=1.1.0 (major=1, minor=1, patch=0)
        return uint64(200110100); // ContractIdEncoding.encode(2, 1, 1, 01, 00);
    }

    /**
     * @dev Constructor that disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev External initializer function
     * @param admin The address that will have admin role
     * @param vault_ The address of the authorized vault
     */
    function initialize(address admin, address vault_) external virtual initializer {
        __BaseStrategy_init(admin, vault_);
    }

    /**
     * @dev Implementation of _previewPosition for SimpleStrategy
     * @dev Returns the allocated amount since this strategy doesn't generate yield
     * @return The current allocated amount
     */
    function _previewPosition() internal view override returns (uint256) {
        return SimpleStrategyStorage.fetch().allocated;
    }

    /**
     * @dev Implementation of _allocateToPosition for SimpleStrategy
     * @dev Simply updates the allocated amount since this strategy just holds assets
     * @param data The data containing the amount to allocate
     * @return The actual amount allocated (same as input)
     */
    function _allocateToPosition(bytes calldata data) internal override returns (uint256) {
        uint256 amount;
        assembly {
            amount := calldataload(data.offset)
        }

        SimpleStrategyStorage.SimpleStrategyStorage storage $ = SimpleStrategyStorage.fetch();
        // @dev state update after transfer to avoid bad state in case of reentrancy
        $.allocated += amount;
        return amount;
    }

    /**
     * @dev Implementation of _deallocateFromPosition for SimpleStrategy
     * @dev Simply updates the allocated amount since this strategy just holds assets
     * @param data The data containing the amount to deallocate
     * @return The actual amount deallocated
     */
    function _deallocateFromPosition(bytes calldata data) internal override returns (uint256) {
        uint256 amount;
        assembly {
            amount := calldataload(data.offset)
        }

        SimpleStrategyStorage.SimpleStrategyStorage storage $ = SimpleStrategyStorage.fetch();

        if (amount > $.allocated) revert InsufficientAllocatedAmount();

        // @dev state update before transfer to avoid bad state in case of reentrancy
        $.allocated -= amount;
        return amount;
    }

    /**
     * @dev Implementation of _withdrawFromPosition for SimpleStrategy
     * @dev Simply updates the allocated amount since this strategy just holds assets
     * @param assets The amount of assets to withdraw
     * @return The actual amount withdrawn
     */
    function _withdrawFromPosition(uint256 assets) internal override returns (uint256) {
        SimpleStrategyStorage.SimpleStrategyStorage storage $ = SimpleStrategyStorage.fetch();

        if (assets > $.allocated) revert InsufficientAllocatedAmount();

        // @dev state update before transfer to avoid bad state in case of reentrancy
        $.allocated -= assets;
        return assets;
    }

    /**
     * @dev Override strategyType for SimpleStrategy
     * @dev SimpleStrategy is an atomic strategy that executes operations in the same transaction
     * @return ATOMIC strategy type
     */
    function strategyType() external pure override returns (StrategyType) {
        return StrategyType.ATOMIC;
    }
}
