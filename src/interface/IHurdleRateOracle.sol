// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title IHurdleRateOracle
 * @notice Oracle that returns the expected exchange rate (assets per share) that the
 *         vault must exceed before performance fees are charged.
 * @dev The hurdle rate is expressed as an exchange rate scaled to `precision()`.
 *      For example, with `precision() == 1e18`, a hurdle rate of 1.05e18 means the vault
 *      must reach 1.05 assets per share before performance fees activate.
 *      Implementations may compute this on-chain (e.g. linear/compound growth from a
 *      baseline) or relay an off-chain computed value. Each oracle instance is bound
 *      to a single vault.
 */
interface IHurdleRateOracle {
    /**
     * @notice Returns the scaling factor for the hurdle rate.
     * @dev The vault divides by this value when converting the hurdle exchange rate
     *      to asset amounts: `hurdleAssets = hurdleRate * totalSupply / precision()`.
     */
    function precision() external view returns (uint256);

    /**
     * @notice Returns the current hurdle rate at the current block timestamp.
     * @return hurdleRate The minimum assets-per-share value below which no
     *         performance fee should be charged.
     */
    function getHurdleRate() external view returns (uint256 hurdleRate);
}
