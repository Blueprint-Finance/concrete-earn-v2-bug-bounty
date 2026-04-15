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
    error VaultNotConfigured(address vault);
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event VaultDepositCapSet(address indexed vault, uint256 oldCap, uint256 newCap);

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the deposit cap for a specific vault
     * @param _vault The vault address to configure
     * @param _depositCap The deposit cap for users in this vault (in asset terms)
     */
    function setVaultDepositCap(address _vault, uint256 _depositCap) external;

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Gets the per-user deposit cap for a specific vault
     * @param _vault The vault address
     * @return The deposit cap that applies to each user in this vault
     */
    function getUserDepositCap(address _vault) external view returns (uint256);

    /**
     * @notice Checks if a user can deposit a given amount into a vault
     * @param _vault The vault address to check against
     * @param _user The user (receiver) address
     * @param _additionalAssets The amount of assets to deposit
     * @return Whether the deposit is allowed
     */
    function canUserDeposit(address _vault, address _user, uint256 _additionalAssets) external view returns (bool);
}
