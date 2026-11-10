// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {IERC20, IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {ConcreteV2ConversionLib as ConversionLib} from "./Conversion.sol";
import {Hooks, HooksLibV2 as HooksLib} from "./Hooks.sol";
import {StandardVaultHelperLib} from "./StandardVaultHelperLib.sol";
import {ERC20_OZ_5_2_0_Lib} from "./ERC20Lib.sol";
import {ERC4626_OZ_5_2_0_Lib} from "./ERC4626Lib.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "./storage/ConcreteCachedVaultStateStorageLib.sol";

/**
 * @title UserActionsLib
 * @notice Library that holds the pre/post logic and deposit/withdraw accounting for the four
 *         ERC-4626 user actions on {ConcreteStandardVaultImpl}: `deposit`, `mint`, `withdraw`,
 *         `redeem`.
 * @dev Public functions are linked via DELEGATECALL so the bytecode lives outside the vault
 *      contract. Mint/burn/allowance use {ERC20_OZ_5_2_0_Lib} (mints/burns already bypass
 *      transfer hooks in {ERC20UpgradeableWithTransferHook}).
 *
 *      Mirrored ERC-4626 errors (`ERC4626ExceededMax*`) are re-declared locally; selectors
 *      match the originals because they are derived from the signature, so existing
 *      `.selector`-based test matchers keep working unchanged.
 */
library UserActionsLib {
    using SafeERC20 for IERC20;
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    // ─────────────────────────────────────────────────────────────────────────
    // deposit
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Pre-deposit work: receiver check, hooks load, share conversion, pre-deposit hook,
     *      min/max-deposit enforcement.
     * @return shares The shares amount the deposit will mint.
     */
    function preDeposit(uint256 assets, address receiver, address sender, uint256 totalSupply_)
        public
        returns (uint256 shares)
    {
        require(receiver != address(0), IConcreteStandardVaultImpl.InvalidReceiver());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        Hooks memory hooks = $.hooks;
        uint256 totalAssetsBefore = CachedVaultStateLib.fetch().cachedTotalAssets;

        shares = ConversionLib.calcConvertToShares(assets, totalSupply_, totalAssetsBefore, Math.Rounding.Floor, true);

        if (HooksLib.checkIsValid(hooks, HooksLib.PRE_DEPOSIT)) {
            HooksLib.preDeposit(hooks, sender, assets, shares, receiver, totalAssetsBefore);
        }

        uint256 minDepositAmount = $.minTxDepositAmount;
        require(
            assets >= minDepositAmount,
            IConcreteStandardVaultImpl.MinimumDepositAmountNotMet(sender, assets, minDepositAmount)
        );

        uint256 maxAssets =
            StandardVaultHelperLib.calcMaxDeposit($.maxGlobalDepositAmount, minDepositAmount, totalAssetsBefore);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
    }

    /// @dev Post-deposit hook (if enabled).
    function postDeposit(uint256 assets, uint256 shares, address receiver, address sender) public {
        Hooks memory hooks = SVLib.fetch().hooks;
        if (HooksLib.checkIsValid(hooks, HooksLib.POST_DEPOSIT)) {
            HooksLib.postDeposit(hooks, sender, assets, shares, receiver, CachedVaultStateLib.fetch().cachedTotalAssets);
        }
    }

    /**
     * @dev Deposit/mint common workflow (ERC-4626 `_deposit`): pull assets, update cached total,
     *      mint shares, emit {IERC4626-Deposit}. Min-deposit is enforced in {preDeposit}/{preMint}.
     */
    function executeDeposit(address caller, address receiver, uint256 assets, uint256 shares) public {
        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        IERC20(ERC4626_OZ_5_2_0_Lib.asset()).safeTransferFrom(caller, address(this), assets);
        CachedVaultStateLib.fetch().cachedTotalAssets += assets;
        ERC20_OZ_5_2_0_Lib._mint(receiver, shares);

        emit IERC4626.Deposit(caller, receiver, assets, shares);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mint
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Pre-mint work: receiver check, hooks load, asset conversion, pre-mint hook,
     *      min/max-mint enforcement (min is on the converted asset amount).
     * @return assets The assets amount the user must transfer in.
     */
    function preMint(uint256 shares, address receiver, address sender, uint256 totalSupply_)
        public
        returns (uint256 assets)
    {
        require(receiver != address(0), IConcreteStandardVaultImpl.InvalidReceiver());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        Hooks memory hooks = $.hooks;
        uint256 totalAssetsBefore = CachedVaultStateLib.fetch().cachedTotalAssets;

        assets = ConversionLib.calcConvertToAssets(shares, totalSupply_, totalAssetsBefore, Math.Rounding.Ceil, true);

        if (HooksLib.checkIsValid(hooks, HooksLib.PRE_MINT)) {
            HooksLib.preMint(hooks, sender, assets, shares, receiver, totalAssetsBefore);
        }

        uint256 minDepositAmount = $.minTxDepositAmount;
        require(
            assets >= minDepositAmount,
            IConcreteStandardVaultImpl.MinimumDepositAmountNotMet(sender, assets, minDepositAmount)
        );

        uint256 maxShares = StandardVaultHelperLib.calcMaxMint(
            $.maxGlobalDepositAmount, minDepositAmount, totalAssetsBefore, totalSupply_
        );
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
    }

    /// @dev Post-mint hook (if enabled).
    function postMint(uint256 assets, uint256 shares, address receiver, address sender) public {
        Hooks memory hooks = SVLib.fetch().hooks;
        if (HooksLib.checkIsValid(hooks, HooksLib.POST_MINT)) {
            HooksLib.postMint(hooks, sender, assets, shares, receiver, CachedVaultStateLib.fetch().cachedTotalAssets);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // withdraw
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Pre-withdraw work: receiver check, hooks load, share conversion, pre-withdraw hook,
     *      optimistic max-withdraw cap (reverts if exceeded).
     * @param ownerBalance `balanceOf(owner)` (passed in because libraries cannot reach the
     *                     inherited ERC20 storage cleanly).
     * @return shares The shares amount that will be burned for `assets`.
     * @return maxAssets The optimistic max-withdraw cap; returned so the caller can reuse it
     *                   in the secondary defensive revert if `_executeWithdraw` short-fills.
     */
    function preWithdraw(
        uint256 assets,
        address receiver,
        address owner,
        address sender,
        uint256 totalSupply_,
        uint256 ownerBalance
    ) public returns (uint256 shares, uint256 maxAssets) {
        require(receiver != address(0), IConcreteStandardVaultImpl.InvalidReceiver());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        Hooks memory hooks = $.hooks;
        uint256 totalAssetsBefore = CachedVaultStateLib.fetch().cachedTotalAssets;

        shares = ConversionLib.calcConvertToShares(assets, totalSupply_, totalAssetsBefore, Math.Rounding.Ceil, true);

        if (HooksLib.checkIsValid(hooks, HooksLib.PRE_WITHDRAW)) {
            HooksLib.preWithdraw(hooks, sender, assets, shares, receiver, owner, totalAssetsBefore);
        }

        maxAssets = StandardVaultHelperLib.calcMaxWithdraw(
            ownerBalance, $.maxTxWithdrawAmount, $.minTxWithdrawAmount, totalAssetsBefore, totalSupply_
        );
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
    }

    /**
     * @dev Post-withdraw work: enforces the configured min-withdraw amount and invokes the
     *      post-withdraw hook (if enabled).
     */
    function postWithdraw(uint256 assets, uint256 shares, address receiver, address sender) public {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        uint256 minWithdrawAmount = $.minTxWithdrawAmount;
        require(
            assets >= minWithdrawAmount,
            IConcreteStandardVaultImpl.MinimumWithdrawAmountNotMet(sender, assets, minWithdrawAmount)
        );

        Hooks memory hooks = $.hooks;
        if (HooksLib.checkIsValid(hooks, HooksLib.POST_WITHDRAW)) {
            HooksLib.postWithdraw(
                hooks, sender, assets, shares, receiver, CachedVaultStateLib.fetch().cachedTotalAssets
            );
        }
    }

    /**
     * @dev Withdraw/redeem common workflow (ERC-4626 `_withdraw`): spend allowance if needed,
     *      burn shares, transfer assets, update cached total, emit {IERC4626-Withdraw}.
     */
    function executeWithdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) public {
        if (caller != owner) {
            ERC20_OZ_5_2_0_Lib._spendAllowance(owner, caller, shares);
        }

        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.

        CachedVaultStateLib.fetch().cachedTotalAssets -= assets;
        ERC20_OZ_5_2_0_Lib._burn(owner, shares);
        IERC20(ERC4626_OZ_5_2_0_Lib.asset()).safeTransfer(receiver, assets);

        emit IERC4626.Withdraw(caller, receiver, owner, assets, shares);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // redeem
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Pre-redeem work: receiver check, hooks load, asset conversion, pre-redeem hook,
     *      optimistic max-redeem cap (reverts if exceeded).
     * @param ownerBalance `balanceOf(owner)` (passed in because libraries cannot reach the
     *                     inherited ERC20 storage cleanly).
     * @return assets The assets amount the user will receive for `shares`.
     * @return maxShares The optimistic max-redeem cap; returned so the caller can reuse it
     *                   in the secondary defensive revert if `_executeWithdraw` short-fills.
     */
    function preRedeem(
        uint256 shares,
        address receiver,
        address owner,
        address sender,
        uint256 totalSupply_,
        uint256 ownerBalance
    ) public returns (uint256 assets, uint256 maxShares) {
        require(receiver != address(0), IConcreteStandardVaultImpl.InvalidReceiver());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        Hooks memory hooks = $.hooks;
        uint256 totalAssetsBefore = CachedVaultStateLib.fetch().cachedTotalAssets;

        assets = ConversionLib.calcConvertToAssets(shares, totalSupply_, totalAssetsBefore, Math.Rounding.Floor, true);

        if (HooksLib.checkIsValid(hooks, HooksLib.PRE_REDEEM)) {
            HooksLib.preRedeem(hooks, sender, assets, shares, receiver, owner, totalAssetsBefore);
        }

        maxShares = StandardVaultHelperLib.calcMaxRedeem(
            ownerBalance, $.maxTxWithdrawAmount, $.minTxWithdrawAmount, totalAssetsBefore, totalSupply_
        );
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
    }

    /**
     * @dev Post-redeem work: enforces the configured min-withdraw amount and invokes the
     *      post-redeem hook (if enabled).
     */
    function postRedeem(uint256 assets, uint256 shares, address receiver, address sender) public {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        uint256 minWithdrawAmount = $.minTxWithdrawAmount;
        require(
            assets >= minWithdrawAmount,
            IConcreteStandardVaultImpl.MinimumWithdrawAmountNotMet(sender, assets, minWithdrawAmount)
        );

        Hooks memory hooks = $.hooks;
        if (HooksLib.checkIsValid(hooks, HooksLib.POST_REDEEM)) {
            HooksLib.postRedeem(hooks, sender, assets, shares, receiver, CachedVaultStateLib.fetch().cachedTotalAssets);
        }
    }
}
