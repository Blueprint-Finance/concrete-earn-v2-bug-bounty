// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20, IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

import {IAssetPricer} from "../interface/IAssetPricer.sol";
import {IMultiAssetDepositStrategy} from "../interface/IMultiAssetDepositStrategy.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {IConcreteMultiAssetDepositAsyncVault as IMAV} from "../interface/IConcreteMultiAssetDepositAsyncVault.sol";

import {Hooks, HooksLibV2 as HooksLib} from "./Hooks.sol";
import {UserActionsLib} from "./UserActionsLib.sol";
import {StandardVaultHelperLib} from "./StandardVaultHelperLib.sol";
import {ERC20_OZ_5_2_0_Lib} from "./ERC20Lib.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "./storage/ConcreteCachedVaultStateStorageLib.sol";
import {
    ConcreteMultiAssetDepositAsyncVaultStorageLib as MASLib
} from "./storage/ConcreteMultiAssetDepositAsyncVaultStorageLib.sol";

/**
 * @title MultiAssetVaultHelperLib
 * @notice Holds the non-base multi-asset deposit flow for {ConcreteMultiAssetDepositAsyncVault}.
 * @dev Public functions are linked via DELEGATECALL so the bytecode lives outside the vault
 *      (EIP-170). The full user-action sequence mirrors the standard vault `deposit` shape:
 *      `preDeposit` → transfer/allocate/account → mint → `postDeposit`, all inside this library.
 */
library MultiAssetVaultHelperLib {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Shared non-base validation + pricing for {multiAssetDeposit} and {previewDeposit}.
     *      Ensures both paths revert on the same config/whitelist/pricing failures.
     * @return baseValue The base-asset value of `assets` of `depositAsset`.
     * @return strategy The configured multi-asset strategy (Active).
     */
    function prepareNonBaseDeposit(address depositAsset, uint256 assets)
        public
        view
        returns (uint256 baseValue, address strategy)
    {
        MASLib.ConcreteMultiAssetDepositAsyncVaultStorage storage $mas = MASLib.fetch();
        require($mas.whitelistedAssets.contains(depositAsset), IMAV.AssetNotWhitelisted(depositAsset));

        address pricer = $mas.pricer;
        strategy = $mas.strategy;
        require(pricer != address(0) && strategy != address(0), IMAV.MultiAssetNotConfigured());

        require(
            SVLib.fetch().strategyData[strategy].status == IConcreteStandardVaultImpl.StrategyStatus.Active,
            IMAV.MultiAssetStrategyNotActive(strategy)
        );

        baseValue = IAssetPricer(pricer).convertToBase(depositAsset, IERC4626(address(this)).asset(), assets);
        require(baseValue != 0, IMAV.ZeroBaseValue(depositAsset, assets));
    }

    /**
     * @dev Executes a non-base deposit in the vault's storage context (DELEGATECALL). Mirrors the
     *      base deposit + allocate flow but routes the raw deposit asset straight to the configured
     *      strategy, keeping canonical accounting in base units. Follows the same pre → effect →
     *      post pattern as {ConcreteStandardVaultImpl-deposit}: standard pre-deposit checks, then
     *      transfer/allocation/accounting + {MultiAssetDeposit}, then mint shares and post-deposit.
     *      Hook firing order is `PRE_DEPOSIT` → `PRE_MULTI_DEPOSIT` → mint → `POST_DEPOSIT`: the base
     *      lifecycle points fire here too, carrying the base-equivalent value (see {IHook-preDeposit}).
     * @return shares The shares minted to `receiver`.
     */
    function multiAssetDeposit(address depositAsset, uint256 assets, address receiver, uint256 totalSupply_)
        external
        returns (uint256 shares)
    {
        address sender = msg.sender;
        (uint256 baseValue, address strategy) = prepareNonBaseDeposit(depositAsset, assets);

        // Same pre → effect → post shape as standard `deposit`, against the base-equivalent value.
        // Min/max deposit checks live in {UserActionsLib.preDeposit}.
        shares = UserActionsLib.preDeposit(baseValue, receiver, sender, totalSupply_);
        _preMultiDepositHook(depositAsset, assets, baseValue, shares, receiver);

        // Bypass idle vault balance: pull the raw asset in, approve, let the strategy pull it while
        // recording the base value, then reset the approval. Use the strategy-reported amount for
        // vault accounting (same pattern as {AllocateModule} with `allocateFunds`).
        IERC20(depositAsset).safeTransferFrom(sender, address(this), assets);
        IERC20(depositAsset).forceApprove(strategy, assets);
        uint256 baseAllocated =
            IMultiAssetDepositStrategy(strategy).allocateFundsMultiAsset(depositAsset, assets, baseValue);
        IERC20(depositAsset).forceApprove(strategy, 0);
        require(baseAllocated == baseValue, IMAV.BaseAllocatedMismatch(baseAllocated, baseValue));

        // Book the strategy-reported base value into the vault cached total and allocated principal.
        CachedVaultStateLib.fetch().cachedTotalAssets += baseAllocated;
        SVLib.fetch().strategyData[strategy].allocated += baseAllocated.toUint120();

        // Defensive: allocated must never exceed cachedTotalAssets.
        require(
            CachedVaultStateLib.fetch().cachedTotalAssets >= StandardVaultHelperLib.calcTotalAllocated(),
            IConcreteStandardVaultImpl.InsufficientBalance()
        );

        emit IMAV.MultiAssetDeposit(sender, receiver, depositAsset, assets, baseAllocated, shares);

        // Mint after accounting so POST_DEPOSIT (and any hook reading balances) sees final state.
        ERC20_OZ_5_2_0_Lib._mint(receiver, shares);

        // Canonical ERC-4626 issuance signal, as the base path emits it. Carries the base-equivalent
        // value; {MultiAssetDeposit} carries the raw deposit token and amount.
        emit IERC4626.Deposit(sender, receiver, baseAllocated, shares);

        UserActionsLib.postDeposit(baseAllocated, shares, receiver, sender);
    }

    /**
     * @dev Fires the multi-asset-only pre-deposit hook. Unlike `PRE_DEPOSIT` (which sees the
     *      base-equivalent value), this carries the deposit token and its raw amount so hooks can
     *      reason per token.
     */
    function _preMultiDepositHook(
        address depositAsset,
        uint256 assets,
        uint256 baseValue,
        uint256 shares,
        address receiver
    ) private {
        Hooks memory hooks = SVLib.fetch().hooks;
        if (!HooksLib.checkIsValid(hooks, HooksLib.PRE_MULTI_DEPOSIT)) return;

        HooksLib.preMultiDeposit(
            hooks,
            msg.sender,
            depositAsset,
            assets,
            baseValue,
            shares,
            receiver,
            CachedVaultStateLib.fetch().cachedTotalAssets
        );
    }

    /**
     * @dev View helper for {ConcreteMultiAssetDepositAsyncVault-previewDeposit}. Applies the same
     *      non-base validation/pricing as {multiAssetDeposit}, then returns the shares a
     *      base-equivalent deposit would mint (post yield accrual preview).
     */
    function previewDeposit(address depositAsset, uint256 assets) external view returns (uint256) {
        (uint256 baseValue,) = prepareNonBaseDeposit(depositAsset, assets);
        return StandardVaultHelperLib.previewDeposit(baseValue);
    }
}
