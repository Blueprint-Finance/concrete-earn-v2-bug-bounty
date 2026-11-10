// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {IDolomiteMargin, DolomiteAccount, DolomiteActions, DolomiteTypes} from "../interface/IDolomiteMargin.sol";

/// @title  DolomiteAccountActionLib
/// @notice Solidity ^0.8 copy of `AccountActionLib` from @dolomite-exchange/dolomite-margin.
///         The upstream library targets Solidity ^0.5.7 and cannot be imported into ^0.8 code,
///         so this file mirrors its patterns using the ^0.8 type aliases in IDolomiteMargin.sol.
///
/// @dev ActionArgs field notes:
///   • `accountId`        — index into the `accounts[]` array passed to `operate()`, NOT a
///                          Dolomite sub-account number. Always 0 for single-account operations.
///   • `secondaryMarketId`— only meaningful for two-market actions (Buy/Sell/Trade). Ignored
///                          by the protocol for Deposit and Withdraw; set to 0.
///   • `otherAccountId`   — accounts[] index for the counterparty in two-account actions.
///                          Unused for Deposit/Withdraw; set to 0.
///
/// @dev `deposit`/`withdraw`/`transfer`/`sell` are `public` rather than `internal` (each called
///      multiple times across the Dolomite flavours) so this library is deployed once and called
///      via `DELEGATECALL` instead of being duplicated into every caller's runtime bytecode — the
///      same technique `DolomitePositionViewLib` uses, and for the same EIP-170 size reason. Every
///      function here just encodes an `operate()` call from explicit params, with no dependency on
///      the caller's own storage, so behaviour under `DELEGATECALL` is identical to inlining.
///      `liquidate` stays `internal`: it currently has no caller.
library DolomiteAccountActionLib {
    /// @dev Mirrors AccountActionLib.deposit.
    ///      Deposits `amountWei` of `marketId` into `(accountOwner, accountNumber)`.
    ///      Tokens are pulled from `fromAddress`, which must have approved DolomiteMargin.
    function deposit(
        IDolomiteMargin dolomiteMargin,
        address accountOwner,
        uint256 accountNumber,
        uint256 marketId,
        uint256 amountWei,
        address fromAddress
    ) public {
        DolomiteAccount.Info[] memory accounts = new DolomiteAccount.Info[](1);
        accounts[0] = DolomiteAccount.Info({owner: accountOwner, number: accountNumber});

        DolomiteActions.ActionArgs[] memory actions = new DolomiteActions.ActionArgs[](1);
        actions[0] = DolomiteActions.ActionArgs({
            actionType: DolomiteActions.ActionType.Deposit,
            accountId: 0, // index into accounts[], always 0 for single-account ops
            amount: DolomiteTypes.AssetAmount({
                sign: true,
                denomination: DolomiteTypes.AssetDenomination.Wei,
                ref: DolomiteTypes.AssetReference.Delta,
                value: amountWei
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0, // unused for Deposit
            otherAddress: fromAddress,
            otherAccountId: 0,
            data: new bytes(0)
        });

        dolomiteMargin.operate(accounts, actions);
    }

    /// @dev Mirrors AccountActionLib.withdraw.
    ///      Withdraws `amountWei` of `marketId` from `(accountOwner, accountNumber)`.
    ///      Withdrawn tokens are sent to `toAddress`.
    ///      Pass `type(uint256).max` as `amountWei` to withdraw the full balance
    ///      (translates to AssetReference.Target with value 0, i.e. "bring balance to zero").
    function withdraw(
        IDolomiteMargin dolomiteMargin,
        address accountOwner,
        uint256 accountNumber,
        uint256 marketId,
        uint256 amountWei,
        address toAddress
    ) public {
        bool isMax = amountWei == type(uint256).max;

        DolomiteAccount.Info[] memory accounts = new DolomiteAccount.Info[](1);
        accounts[0] = DolomiteAccount.Info({owner: accountOwner, number: accountNumber});

        DolomiteActions.ActionArgs[] memory actions = new DolomiteActions.ActionArgs[](1);
        actions[0] = DolomiteActions.ActionArgs({
            actionType: DolomiteActions.ActionType.Withdraw,
            accountId: 0, // index into accounts[], always 0 for single-account ops
            amount: DolomiteTypes.AssetAmount({
                sign: false,
                denomination: DolomiteTypes.AssetDenomination.Wei,
                // Target(0) with sign=false means "bring balance to 0" = full withdrawal
                ref: isMax ? DolomiteTypes.AssetReference.Target : DolomiteTypes.AssetReference.Delta,
                value: isMax ? 0 : amountWei
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0, // unused for Withdraw
            otherAddress: toAddress,
            otherAccountId: 0,
            data: new bytes(0)
        });

        dolomiteMargin.operate(accounts, actions);
    }

    /// @dev Mirrors AccountActionLib.transfer (internal sub-account transfer).
    ///      Transfers `amountWei` of `marketId` from `(fromOwner, fromAccountNumber)`
    ///      to `(toOwner, toAccountNumber)`. Both accounts can belong to the same owner.
    ///      Pass `type(uint256).max` as `amountWei` to transfer the full balance
    ///      (translates to AssetReference.Target with value 0, i.e. "bring from-balance to zero").
    function transfer(
        IDolomiteMargin dolomiteMargin,
        address fromOwner,
        uint256 fromAccountNumber,
        address toOwner,
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amountWei
    ) public {
        bool isMax = amountWei == type(uint256).max;

        DolomiteAccount.Info[] memory accounts = new DolomiteAccount.Info[](2);
        accounts[0] = DolomiteAccount.Info({owner: fromOwner, number: fromAccountNumber});
        accounts[1] = DolomiteAccount.Info({owner: toOwner, number: toAccountNumber});

        DolomiteActions.ActionArgs[] memory actions = new DolomiteActions.ActionArgs[](1);
        actions[0] = DolomiteActions.ActionArgs({
            actionType: DolomiteActions.ActionType.Transfer,
            accountId: 0, // from = accounts[0]
            amount: DolomiteTypes.AssetAmount({
                sign: false,
                denomination: DolomiteTypes.AssetDenomination.Wei,
                // Target(0) with sign=false means "bring from-balance to 0" = transfer all
                ref: isMax ? DolomiteTypes.AssetReference.Target : DolomiteTypes.AssetReference.Delta,
                value: isMax ? 0 : amountWei
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0, // unused for Transfer
            otherAddress: address(0),
            otherAccountId: 1, // to = accounts[1]
            data: new bytes(0)
        });

        dolomiteMargin.operate(accounts, actions);
    }

    /// @dev Liquidates `(accountOwner, liquidatedAccountNr)` using `(accountOwner, liquidatorAccountNr)`.
    ///      `owedWei` is the amount of `secondaryMarketId` (debt) to repay; pass `type(uint256).max`
    ///      to repay the full outstanding debt (uses AssetReference.Target → 0).
    ///      `primaryMarketId` is the collateral market the liquidator receives at a discount.
    function liquidate(
        IDolomiteMargin dolomiteMargin,
        address accountOwner,
        uint256 liquidatorAccountNr,
        uint256 liquidatedAccountNr,
        uint256 primaryMarketId,
        uint256 secondaryMarketId,
        uint256 owedWei
    ) internal {
        bool isMax = owedWei == type(uint256).max;

        DolomiteAccount.Info[] memory accounts = new DolomiteAccount.Info[](2);
        accounts[0] = DolomiteAccount.Info({owner: accountOwner, number: liquidatorAccountNr});
        accounts[1] = DolomiteAccount.Info({owner: accountOwner, number: liquidatedAccountNr});

        DolomiteActions.ActionArgs[] memory actions = new DolomiteActions.ActionArgs[](1);
        actions[0] = DolomiteActions.ActionArgs({
            actionType: DolomiteActions.ActionType.Liquidate,
            accountId: 0, // liquidator = accounts[0]
            amount: DolomiteTypes.AssetAmount({
                sign: true, // sign=true → amount is in secondaryMarket (owedMarket/debt) units
                denomination: DolomiteTypes.AssetDenomination.Wei,
                ref: isMax ? DolomiteTypes.AssetReference.Target : DolomiteTypes.AssetReference.Delta,
                value: isMax ? 0 : owedWei
            }),
            primaryMarketId: primaryMarketId, // heldMarket — collateral liquidator receives
            secondaryMarketId: secondaryMarketId, // owedMarket — debt that gets repaid
            otherAddress: address(0),
            otherAccountId: 1, // liquidated = accounts[1]
            data: new bytes(0)
        });

        dolomiteMargin.operate(accounts, actions);
    }

    /// @dev Sells `amountWei` of `primaryMarketId` for `secondaryMarketId` via `exchangeWrapper`.
    ///      Pass `type(uint256).max` as `amountWei` to sell the entire balance
    ///      (translates to AssetReference.Target with value 0).
    ///      `exchangeData` is forwarded verbatim to the wrapper's `exchange(...)` function.
    function sell(
        IDolomiteMargin dolomiteMargin,
        address accountOwner,
        uint256 accountNr,
        uint256 primaryMarketId,
        uint256 secondaryMarketId,
        uint256 amountWei,
        address exchangeWrapper,
        bytes memory exchangeData
    ) public {
        bool isMax = amountWei == type(uint256).max;

        DolomiteAccount.Info[] memory accounts = new DolomiteAccount.Info[](1);
        accounts[0] = DolomiteAccount.Info({owner: accountOwner, number: accountNr});

        DolomiteActions.ActionArgs[] memory actions = new DolomiteActions.ActionArgs[](1);
        actions[0] = DolomiteActions.ActionArgs({
            actionType: DolomiteActions.ActionType.Sell,
            accountId: 0,
            amount: DolomiteTypes.AssetAmount({
                sign: false, // sign=false → amount is in primaryMarket (input/sold token) units
                denomination: DolomiteTypes.AssetDenomination.Wei,
                ref: isMax ? DolomiteTypes.AssetReference.Target : DolomiteTypes.AssetReference.Delta,
                value: isMax ? 0 : amountWei
            }),
            primaryMarketId: primaryMarketId, // token being sold
            secondaryMarketId: secondaryMarketId, // token received
            otherAddress: exchangeWrapper,
            otherAccountId: 0,
            data: exchangeData
        });

        dolomiteMargin.operate(accounts, actions);
    }
}
