// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// @dev Minimal ^0.8 interfaces for DolomiteMargin, mirroring the Solidity 0.5.x originals.

library DolomiteAccount {
    struct Info {
        address owner;
        uint256 number;
    }
}

library DolomiteTypes {
    enum AssetDenomination {
        Wei, // the amount is denominated in wei
        Par // the amount is denominated in par
    }

    enum AssetReference {
        Delta, // the amount is a delta from the current value
        Target // the amount is an exact number to end up at
    }

    struct AssetAmount {
        bool sign; // true if positive
        AssetDenomination denomination;
        AssetReference ref;
        uint256 value;
    }
}

library DolomiteActions {
    enum ActionType {
        Deposit, // supply tokens
        Withdraw, // borrow tokens
        Transfer, // transfer balance between accounts
        Buy, // buy an amount of some token (externally)
        Sell, // sell an amount of some token (externally)
        Trade, // trade tokens against another account
        Liquidate, // liquidate an undercollateralized or expiring account
        Vaporize, // use excess tokens to zero-out a completely negative account
        Call // send arbitrary data to an address
    }

    struct ActionArgs {
        ActionType actionType;
        uint256 accountId;
        DolomiteTypes.AssetAmount amount;
        uint256 primaryMarketId;
        uint256 secondaryMarketId;
        address otherAddress;
        uint256 otherAccountId;
        bytes data;
    }
}

interface IDolomiteMargin {
    // ── Operator management ──────────────────────────────────────────────────

    function getIsLocalOperator(address owner, address operator) external view returns (bool);
    function getIsGlobalOperator(address operator) external view returns (bool);

    // ── Market queries ────────────────────────────────────────────────────────

    function getNumMarkets() external view returns (uint256);
    function getMarketTokenAddress(uint256 marketId) external view returns (address);
    function getMarketIdByTokenAddress(address token) external view returns (uint256);

    /// @dev Returns the price of 1e18 base units of the token in USD, scaled by 1e18.
    function getMarketPrice(uint256 marketId) external view returns (uint256 value);

    /// @dev Annualised borrow interest rate, scaled by 1e18 (WAD).
    function getMarketBorrowInterestRateApr(uint256 marketId) external view returns (uint256 value);

    /// @dev Annualised supply interest rate, scaled by 1e18 (WAD).
    function getMarketSupplyInterestRateApr(uint256 marketId) external view returns (uint256 value);

    // ── Account queries ───────────────────────────────────────────────────────

    /// @dev Returns the token balance (Wei) for `account` in `marketId`.
    ///      sign=true means supply (positive), sign=false means borrow (negative).
    function getAccountWei(DolomiteAccount.Info calldata account, uint256 marketId)
        external
        view
        returns (bool sign, uint256 value);

    /// @dev Returns the number of markets with a non-zero balance (supply or debt) for `account`.
    function getAccountNumberOfMarketsWithBalances(DolomiteAccount.Info calldata account)
        external
        view
        returns (uint256);

    /// @dev Returns the number of markets with a negative balance (debt) for `account`.
    function getAccountNumberOfMarketsWithDebt(DolomiteAccount.Info calldata account) external view returns (uint256);

    /// @dev Returns the total supplied and total borrowed USD values for `account`.
    function getAccountValues(DolomiteAccount.Info calldata account)
        external
        view
        returns (uint256 supplyValue, uint256 borrowValue);

    /// @dev Returns the global minimum margin ratio in WAD (1e18 = 100%).
    function getMarginRatio() external view returns (uint256 value);

    /// @dev Returns the effective margin ratio for `account` in WAD.
    ///      Returns the per-account override if one is set, otherwise the global value.
    function getMarginRatioForAccount(DolomiteAccount.Info calldata account) external view returns (uint256 value);

    /// @dev Returns the margin premium for `marketId` in WAD.
    ///      A non-zero premium increases the required collateral for any position holding this market.
    function getMarketMarginPremium(uint256 marketId) external view returns (uint256 value);

    /// @dev Returns the global earnings rate in WAD — the fraction of borrow interest paid to suppliers.
    ///      supplyRate = borrowRate × utilization × earningsRate
    ///      This is a single protocol-wide value; it is not configurable per market.
    function getEarningsRate() external view returns (uint256 value);

    // ── Core operation ────────────────────────────────────────────────────────

    function operate(DolomiteAccount.Info[] calldata accounts, DolomiteActions.ActionArgs[] calldata actions) external;
}
