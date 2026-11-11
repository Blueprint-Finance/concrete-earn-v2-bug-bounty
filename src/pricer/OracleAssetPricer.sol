// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {IAssetPricer} from "../interface/IAssetPricer.sol";
import {OracleModule} from "../periphery/oracle/OracleModule.sol";

/**
 * @title OracleAssetPricer
 * @notice Asset pricer that values a deposit asset in base-asset units using live prices from an
 *         {OracleModule}. Both legs are quoted independently and divided, so any common quote
 *         currency (USD, ETH, ...) cancels out:
 *
 *         `baseAmount = amount * depositPrice / basePrice * 10**baseDecimals / 10**depositDecimals`
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:license AGPL-3.0
 *
 * @dev Stateless and permissionless: prices come from the immutable {OracleModule} (which enforces
 *      a single feed decimals value across all assets, so the price decimals cancel) and token
 *      decimals are read live via {IERC20Metadata-decimals}. Conversions round down, which is
 *      conservative for deposits (never over-values a deposit, favouring the vault). Assets without
 *      a configured feed, or with a stale/out-of-bounds price, revert inside the oracle module.
 * @dev Two-legged pricing: each `getPrice` is validated on its own (`maxDelay`, caps). The ratio
 *      therefore inherits the looser of the two staleness windows, and per-feed deviation bounds
 *      stack. There is no direct-pair path (e.g. stETH/ETH); both assets must share the module's
 *      quote. The base-asset feed is read on every non-base deposit — give it the tightest
 *      `maxDelay` in the module.
 */
contract OracleAssetPricer is IAssetPricer {
    /// @notice The oracle module supplying prices for both the deposit and the base asset.
    OracleModule public immutable oracleModule;

    error ZeroOracleModule();

    constructor(address oracleModule_) {
        require(oracleModule_ != address(0), ZeroOracleModule());
        oracleModule = OracleModule(oracleModule_);
    }

    /// @inheritdoc IAssetPricer
    function convertToBase(address depositAsset, address baseAsset, uint256 amount)
        external
        view
        returns (uint256 baseAmount)
    {
        if (amount == 0 || depositAsset == baseAsset) return amount;

        // Each leg is freshness/cap checked on its own; the ratio inherits the looser window.
        uint256 numerator = oracleModule.getPrice(depositAsset);
        uint256 denominator = oracleModule.getPrice(baseAsset);

        uint8 depositDecimals = IERC20Metadata(depositAsset).decimals();
        uint8 baseDecimals = IERC20Metadata(baseAsset).decimals();

        // Fold the decimal delta into the ratio so a single mulDiv keeps full 512-bit precision.
        if (baseDecimals >= depositDecimals) {
            numerator *= 10 ** (baseDecimals - depositDecimals);
        } else {
            denominator *= 10 ** (depositDecimals - baseDecimals);
        }

        baseAmount = Math.mulDiv(amount, numerator, denominator, Math.Rounding.Floor);
    }
}
