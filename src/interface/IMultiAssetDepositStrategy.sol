// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title IMultiAssetDepositStrategy
 * @notice Opt-in extension implemented by strategies that can receive multi-asset deposits, i.e.
 *         deposits denominated in an asset other than the vault's base `asset()`.
 * @dev The bound vault converts the deposit to base units (via its configured pricer) and calls
 *      {allocateFundsMultiAsset}, passing the authoritative `baseValue`. The strategy pulls the raw
 *      non-base asset from the vault and records the position in base units, so its
 *      `totalAllocatedValue()` moves in lockstep with the vault's recorded `allocated`. This keeps
 *      the vault's accounting consistent and avoids phantom yield/loss on the next accrual.
 */
interface IMultiAssetDepositStrategy {
    /**
     * @notice Receives a non-base deposit from the bound vault and records it in base units.
     * @dev MUST be callable only by the bound vault. The caller (vault) MUST have approved this
     *      strategy to transfer `depositAmount` of `depositAsset`. The strategy MUST record exactly
     *      `baseValue` in its base-denominated accounting so that its `totalAllocatedValue()`
     *      increases by `baseValue`.
     * @param depositAsset The non-base ERC-20 asset being deposited.
     * @param depositAmount The amount of `depositAsset` to pull from the vault.
     * @param baseValue The base-asset value of the deposit, as computed by the vault's pricer.
     * @return baseAllocated The base value recorded by the strategy (MUST equal `baseValue`).
     */
    function allocateFundsMultiAsset(address depositAsset, uint256 depositAmount, uint256 baseValue)
        external
        returns (uint256 baseAllocated);
}
