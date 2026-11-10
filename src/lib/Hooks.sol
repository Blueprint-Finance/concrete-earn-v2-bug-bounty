// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks, IHook} from "../interface/IHook.sol";

error FlagIndexOutOfBounds(uint8 flagIndex);

/// @title HooksLibV2
/// @dev Hooks library for user action hooks (pre/post deposit, mint, withdraw, redeem),
///      strategy hooks (pre-add-strategy, pre-remove-strategy),
///      transfer hooks (pre/post transfer),
///      and the multi-asset pre-deposit hook.
library HooksLibV2 {
    uint8 constant PRE_DEPOSIT = 1;
    uint8 constant POST_DEPOSIT = 2;
    uint8 constant PRE_MINT = 3;
    uint8 constant POST_MINT = 4;
    uint8 constant PRE_WITHDRAW = 5;
    uint8 constant POST_WITHDRAW = 6;
    uint8 constant PRE_REDEEM = 7;
    uint8 constant POST_REDEEM = 8;

    uint8 constant PRE_ADD_STRATEGY = 9;
    uint8 constant PRE_REMOVE_STRATEGY = 10;

    uint8 constant PRE_TRANSFER = 11;
    uint8 constant POST_TRANSFER = 12;

    /// @dev Non-base deposits on multi-asset deposit vaults only; other vault flavours never
    ///      raise this flag.
    uint8 constant PRE_MULTI_DEPOSIT = 13;

    /// @dev Checks if a specific flag is set in the Hooks struct
    /// @param h The Hooks storage reference
    /// @param flagIndex The flag index to check (0-95)
    /// @return True if the flag is set, false otherwise
    function flagIsSet(Hooks memory h, uint8 flagIndex) internal pure returns (bool) {
        if (flagIndex >= 96) return false;
        return (uint96(h.flags) & (1 << flagIndex)) != 0;
    }

    function setFlag(Hooks memory h, uint8 flagIndex) internal pure returns (uint96) {
        if (flagIndex >= 96) revert FlagIndexOutOfBounds(flagIndex);
        h.flags = uint96(h.flags | (1 << flagIndex));
        return h.flags;
    }

    function checkIsValid(Hooks memory h, uint8 flagIndex) internal pure returns (bool) {
        if (!flagIsSet(h, flagIndex) || h.target == address(0)) return false;
        return true;
    }

    function preDeposit(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) internal {
        IHook(h.target).preDeposit(sender, assets, shares, receiver, totalAssets);
    }

    function preMultiDeposit(
        Hooks memory h,
        address sender,
        address depositAsset,
        uint256 depositAssetAmount,
        uint256 baseAssets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) internal {
        IHook(h.target)
            .preMultiDeposit(sender, depositAsset, depositAssetAmount, baseAssets, shares, receiver, totalAssets);
    }

    function preMint(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) internal {
        IHook(h.target).preMint(sender, assets, shares, receiver, totalAssets);
    }

    function preWithdraw(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 totalAssets
    ) internal {
        IHook(h.target).preWithdraw(sender, assets, shares, receiver, owner, totalAssets);
    }

    function preRedeem(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 totalAssets
    ) internal {
        IHook(h.target).preRedeem(sender, assets, shares, receiver, owner, totalAssets);
    }

    function postDeposit(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) internal {
        IHook(h.target).postDeposit(sender, assets, shares, receiver, totalAssets);
    }

    function postMint(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) internal {
        IHook(h.target).postMint(sender, assets, shares, receiver, totalAssets);
    }

    function postWithdraw(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) internal {
        IHook(h.target).postWithdraw(sender, assets, shares, receiver, totalAssets);
    }

    function postRedeem(
        Hooks memory h,
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) internal {
        IHook(h.target).postRedeem(sender, assets, shares, receiver, totalAssets);
    }

    function preTransfer(Hooks memory h, address sender, address from, address to, uint256 shares) internal {
        IHook(h.target).preTransfer(sender, from, to, shares);
    }

    function postTransfer(Hooks memory h, address sender, address from, address to, uint256 shares) internal {
        IHook(h.target).postTransfer(sender, from, to, shares);
    }
}
