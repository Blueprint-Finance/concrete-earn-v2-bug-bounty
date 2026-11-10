// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title IAssetPricer
 * @notice Converts an amount of a deposit asset into its equivalent value denominated in the
 *         vault's base asset. Used by multi-asset vaults to value non-base deposits in base units
 *         (e.g. USDC) while keeping base-asset accounting.
 * @dev Implementations may derive the conversion from decimals only (see {OneToOneAssetPricer}) or
 *      from external price feeds. Pricers are stateless with respect to a specific vault: both the
 *      source and base assets are passed explicitly so a single deployment can serve multiple
 *      vaults and assets.
 */
interface IAssetPricer {
    /**
     * @notice Converts `amount` of `depositAsset` into the equivalent amount of `baseAsset`.
     * @param depositAsset The non-base asset being valued.
     * @param baseAsset The base accounting asset to express the value in.
     * @param amount The amount of `depositAsset` to convert (in `depositAsset` units).
     * @return baseAmount The equivalent value expressed in `baseAsset` units.
     */
    function convertToBase(address depositAsset, address baseAsset, uint256 amount)
        external
        view
        returns (uint256 baseAmount);
}
