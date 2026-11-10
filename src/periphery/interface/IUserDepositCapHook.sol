// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title IUserDepositCapHook
 * @notice Interface for UserDepositCapHook contract
 * @dev Exposes hook-specific administrative and view functions
 */
interface IUserDepositCapHook {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error UserDepositLimitExceeded(address user, uint256 attemptedTotal, uint256 limit);
    error InvalidLimit(uint256 limit);
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event DepositCapSet(uint256 oldCap, uint256 newCap);

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the per-user deposit cap for this vault
     * @param _depositCap The deposit cap for each user (in asset terms)
     */
    function setDepositCap(uint256 _depositCap) external;

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Gets the per-user deposit cap for this vault
     * @return The deposit cap that applies to each user
     */
    function getUserDepositCap() external view returns (uint256);

    /**
     * @notice Checks if a user can deposit a given amount into this vault
     * @param _user The user (receiver) address
     * @param _additionalAssets The amount of assets to deposit
     * @return Whether the deposit is allowed
     */
    function canUserDeposit(address _user, uint256 _additionalAssets) external view returns (bool);
}
