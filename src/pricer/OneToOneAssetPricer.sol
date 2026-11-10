// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAssetPricer} from "../interface/IAssetPricer.sol";

/**
 * @title OneToOneAssetPricer
 * @notice MVP asset pricer that treats one unit of the deposit asset as one unit of the base asset,
 *         adjusting only for the difference in token decimals. Suitable for assets that are
 *         economically 1:1 with the base asset (e.g. same-peg stablecoins).
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:license AGPL-3.0
 *
 * @dev Stateless and permissionless: decimals are read live from each token via
 *      {IERC20Metadata-decimals}. Conversions round down, which is conservative for deposits (never
 *      over-values a deposit, favouring the vault). Tokens with mutable decimals are out of scope.
 */
contract OneToOneAssetPricer is IAssetPricer {
    /// @inheritdoc IAssetPricer
    function convertToBase(address depositAsset, address baseAsset, uint256 amount)
        external
        view
        returns (uint256 baseAmount)
    {
        if (amount == 0 || depositAsset == baseAsset) return amount;

        uint8 fromDecimals = IERC20Metadata(depositAsset).decimals();
        uint8 toDecimals = IERC20Metadata(baseAsset).decimals();

        if (fromDecimals == toDecimals) {
            return amount;
        }
        if (fromDecimals < toDecimals) {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
        return amount / (10 ** (fromDecimals - toDecimals));
    }
}
