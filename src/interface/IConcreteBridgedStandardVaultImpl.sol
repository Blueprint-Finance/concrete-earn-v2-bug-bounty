// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IConcreteStandardVaultImpl} from "./IConcreteStandardVaultImpl.sol";

/**
 * @title IConcreteBridgedStandardVaultImpl
 * @notice Interface for a standard vault that serves as migration target for old vaults.
 * @dev This interface extends the standard vault functionality with the ability to mint shares without
 *      depositing underlying assets. Old vaults migrate TO this version during cross-chain migrations.
 */
interface IConcreteBridgedStandardVaultImpl is IConcreteStandardVaultImpl {
    /**
     * @dev Thrown when attempting to operate with zero amount.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when attempting to mint unbacked shares when it's not the initial mint.
     */
    error NotInitialMint();

    /**
     * @dev Thrown when attempting to mint unbacked shares when deposit limits are not zero.
     */
    error DepositLimitsNotZero();

    /**
     * @dev Emitted when unbacked shares are minted.
     * @param shares The amount of shares minted without backing assets.
     */
    event UnbackedMint(uint256 shares);

    /**
     * @notice Mints vault shares without depositing any underlying assets.
     * @dev Only callable by addresses with VAULT_MANAGER role.
     * @dev Used only for vault migration where assets backing newly minted shares
     *      are expected to be updated directly on strategy level.
     * @dev Shares are minted for later distribution to end users.
     * @param shares Amount of shares to mint for the caller.
     */
    function unbackedMint(uint256 shares) external;
}

