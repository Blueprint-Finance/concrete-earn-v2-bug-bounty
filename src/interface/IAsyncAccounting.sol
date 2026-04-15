// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title IAsyncAccounting
 * @notice Interface for strategies that use asynchronous (off-chain) accounting.
 * @dev Strategies whose reported `totalAllocatedValue()` depends on an off-chain
 *      accounting update (e.g. a multisig-managed position) should implement this
 *      interface.  It exposes:
 *
 *      - Two overloads of `adjustTotalAssets`:
 *        • `adjustTotalAssets(int256 diff)` — vault-initiated, trusted, no validation.
 *        • `adjustTotalAssets(int256 diff, uint256 nonce)` — operator-initiated with
 *          nonce / threshold / cooldown validation.
 *
 *      - `unpauseAndAdjustTotalAssets` — admin emergency recovery.
 *
 *      - Configuration setters for the accounting validation parameters.
 *
 *      - Read-only getters for the current accounting configuration.
 */
interface IAsyncAccounting {
    // ─── Adjust functions ────────────────────────────────────────────────

    /**
     * @notice Vault-initiated accounting adjustment (e.g. recording an unwind cost).
     * @dev MUST only be callable by the bound vault.  Bypasses nonce / threshold /
     *      cooldown checks because the vault is a trusted caller.  MUST bump the
     *      accounting nonce to prevent race conditions with operator adjustments.
     * @param diff Signed delta to apply to the strategy's internal position value.
     */
    function adjustTotalAssets(int256 diff) external;

    /**
     * @notice Operator-initiated accounting adjustment with validation.
     * @dev Subject to nonce ordering, cooldown period, and max-change-threshold
     *      checks.  If validation fails the strategy SHOULD pause itself.
     * @param diff  Signed delta to apply.
     * @param nonce The expected next accounting nonce (prevents replay / ordering issues).
     */
    function adjustTotalAssets(int256 diff, uint256 nonce) external;

    /**
     * @notice Emergency admin function: unpause the strategy and apply an adjustment
     *         in a single transaction, bypassing threshold / cooldown checks.
     * @param diff Signed delta to apply after unpausing.
     */
    function unpauseAndAdjustTotalAssets(int256 diff) external;

    // ─── Configuration setters ───────────────────────────────────────────

    /**
     * @notice Set the maximum allowed single-adjustment change as a fraction of the
     *         current position, expressed in basis points (10 000 = 100 %).
     * @param maxAccountingChangeThreshold New threshold in basis points.
     */
    function setMaxAccountingChangeThreshold(uint64 maxAccountingChangeThreshold) external;

    /**
     * @notice Set the validity window for accounting data.  If no adjustment is
     *         made within this period the strategy's `totalAllocatedValue` will
     *         revert, signalling stale data.
     * @param accountingValidityPeriod New validity period in seconds.
     */
    function setAccountingValidityPeriod(uint64 accountingValidityPeriod) external;

    /**
     * @notice Set the minimum time that must elapse between two successive
     *         operator-initiated adjustments.
     * @param cooldownPeriod New cooldown period in seconds.
     */
    function setCooldownPeriod(uint64 cooldownPeriod) external;

    // ─── Getters ─────────────────────────────────────────────────────────

    /**
     * @notice Returns the next expected accounting nonce.
     */
    function getNextAccountingNonce() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the most recent accounting adjustment.
     */
    function getLastUpdatedTimestamp() external view returns (uint64);

    /**
     * @notice Returns the current max-change threshold in basis points.
     */
    function getMaxAccountingChangeThreshold() external view returns (uint64);

    /**
     * @notice Returns the current accounting validity period in seconds.
     */
    function getAccountingValidityPeriod() external view returns (uint64);

    /**
     * @notice Returns the current cooldown period in seconds.
     */
    function getCooldownPeriod() external view returns (uint64);
}
