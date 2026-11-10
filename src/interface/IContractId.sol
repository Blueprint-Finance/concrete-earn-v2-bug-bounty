// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title IContractId
 * @notice Interface for contracts that have a contract ID identifier.
 * @dev This interface is separated from IUpgradeableVault to simplify override clauses
 *      in implementation contracts that inherit from multiple interfaces.
 */
interface IContractId {
    /**
     * @notice Get the contract's ID.
     * @return ID of the contract
     */
    function ID() external view returns (uint64);
}
