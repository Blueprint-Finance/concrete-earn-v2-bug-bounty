// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {LoopModality} from "../lib/Looping/LoopModalityLib.sol";

/**
 * @title IFlashModule
 * @dev Interface for the FlashModule contract that handles flash loan operations
 */
interface IFlashModule {
    function flash(address token, uint256 amount, LoopModality loopModality, bytes calldata data)
        external
        returns (bool);
    // MUST return the exact depth of flashable liquidity, no estimate or stale value.
    function depthOfFlashLiquidityExact(address token) external view returns (uint256);

    // MUST return the maximum premium percentage in wad across all sources of flash liquidity.
    // returns also whether the max is the min or whether the premium percentage depends on the requested liquidity.
    function flashPremiumMaxInWad(address token)
        external
        view
        returns (uint64 premiumInWad, bool premiumDependsOnLiquidity);

    // MUST provide the quote even if liquidity is not available
    function flashPremiumQuoteInWad(address token, uint256 requiredFlashLiquidity)
        external
        view
        returns (uint64 premiumInWad);
}
