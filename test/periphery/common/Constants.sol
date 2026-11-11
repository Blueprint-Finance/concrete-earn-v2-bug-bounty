// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Constants
 * @notice Centralized constants for the MultiAssetVault project
 * @dev Contains addresses for Chainlink feeds and common tokens
 */
library Constants {
    // ============ Chainlink Feeds ============

    /// @notice ETH/USD price feed on mainnet
    address public constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// @notice BTC/USD price feed on mainnet
    address public constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    /// @notice LINK/USD price feed on mainnet
    address public constant LINK_USD_FEED = 0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c;

    // ============ Token Addresses ============

    /// @notice Wrapped Ether (WETH) on mainnet
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Wrapped Bitcoin (WBTC) on mainnet
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @notice Chainlink token (LINK) on mainnet
    address public constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
}
