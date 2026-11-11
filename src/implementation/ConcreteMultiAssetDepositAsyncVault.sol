// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title ConcreteMultiAssetDepositAsyncVault
 * @notice Async vault variant that accepts deposits denominated in multiple assets while keeping
 *         base-asset (`asset()`) accounting. Base-asset deposits use the inherited ERC-4626 flow
 *         (idle balance + mint); whitelisted non-base deposits are priced to base value, mint the
 *         corresponding shares and are pushed straight to the configured strategy (bypassing idle
 *         vault balance), keeping `cachedTotalAssets` and the strategy `allocated` in sync.
 * @dev The two deposit paths differ in asset custody and accounting, not in hook lifecycle: both
 *      mint the same fungible shares, so `PRE_DEPOSIT` / `POST_DEPOSIT` hooks observe non-base
 *      deposits as well, at their base-equivalent value. Only `PRE_MULTI_DEPOSIT` is exclusive to
 *      the non-base path.
 * @dev `totalAssets()` / `cachedTotalAssets` for this flavour are the deposit-time base
 *      valuation of assets under strategy custody, not retrievable base-asset liquidity.
 *      A later conversion (spread, slippage) is realized via the strategy's
 *      `adjustTotalAssets`, the same as any other PnL on {MultisigStrategy}.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:oz-upgrades Use OZ Upgradeable patterns and eip7201 storage layout
 * @custom:source on request
 * @custom:audits on request
 * @custom:license AGPL-3.0
 */

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {IConcreteMultiAssetDepositAsyncVault} from "../interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal contracts
// ─────────────────────────────────────────────────────────────────────────────
import {ConcreteAsyncVaultImpl} from "./ConcreteAsyncVaultImpl.sol";
import {ConcreteStandardVaultImpl} from "./ConcreteStandardVaultImpl.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal libraries
// ─────────────────────────────────────────────────────────────────────────────
import {ContractIdEncoding} from "../lib/ContractIdEncoding.sol";
import {ConcreteV2RolesLib as RolesLib} from "../lib/Roles.sol";
import {StateSetterLib} from "../lib/StateSetterLib.sol";
import {StateSetterMASLib} from "../lib/StateSetterMASLib.sol";
import {MultiAssetVaultHelperLib} from "../lib/MultiAssetVaultHelperLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Storage layout libraries
// ─────────────────────────────────────────────────────────────────────────────
import {
    ConcreteMultiAssetDepositAsyncVaultStorageLib as MASLib
} from "../lib/storage/ConcreteMultiAssetDepositAsyncVaultStorageLib.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

contract ConcreteMultiAssetDepositAsyncVault is ConcreteAsyncVaultImpl, IConcreteMultiAssetDepositAsyncVault {
    using EnumerableSet for EnumerableSet.AddressSet;

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 8; // multi-asset deposit async vault
    }

    function ID() public pure virtual override(ConcreteAsyncVaultImpl) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 7, 0);
    }

    constructor(address factory) ConcreteAsyncVaultImpl(factory) {}

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    /// @dev Modifiers stay off this overload on purpose (code size + `nonReentrant`):
    ///      the base branch calls `super.deposit` (external), which already applies
    ///      `whenNotPaused` / `nonReentrant` / `withYieldAccrual`. Putting the same
    ///      guards here would re-enter `nonReentrant` on that self-call. The non-base
    ///      branch gets the identical guards on {_multiAssetDeposit}. Inlining the base
    ///      path to lift modifiers onto this function was skipped to save runtime size.
    function deposit(address depositAsset, uint256 assets, address receiver) public virtual returns (uint256 shares) {
        // Base-asset deposits keep using the inherited ERC-4626 flow (idle balance + mint).
        if (depositAsset == asset()) {
            return super.deposit(assets, receiver);
        }
        return _multiAssetDeposit(depositAsset, assets, receiver);
    }

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    function previewDeposit(address depositAsset, uint256 assets) public view virtual returns (uint256 shares) {
        if (depositAsset == asset()) {
            return super.previewDeposit(assets);
        }
        return MultiAssetVaultHelperLib.previewDeposit(depositAsset, assets);
    }

    /**
     * @dev Non-base deposit flow. Full pre → transfer/allocate → mint → post sequence lives in
     *      {MultiAssetVaultHelperLib} (DELEGATECALL), mirroring the standard `deposit` shape.
     *      Guards match the inherited base `deposit` (see note on the public overload).
     */
    function _multiAssetDeposit(address depositAsset, uint256 assets, address receiver)
        internal
        whenNotPaused
        nonReentrant
        withYieldAccrual
        returns (uint256 shares)
    {
        return MultiAssetVaultHelperLib.multiAssetDeposit(depositAsset, assets, receiver, totalSupply());
    }

    // ── Strategy lifecycle (STRATEGY_MANAGER) ─────────────────────────────────

    /// @dev Overridden to route through {StateSetterMASLib}, which performs the same registry work
    ///      and then clears `MASLib.strategy` if the removed strategy was the designated non-base
    ///      deposit destination. Deliberately does not call `super`: the overlay replaces the base
    ///      implementation rather than wrapping it, so no second dispatch path exists.
    function removeStrategy(address strategy)
        public
        virtual
        override(ConcreteStandardVaultImpl, IConcreteStandardVaultImpl)
        whenNotPaused
        nonReentrant
        onlyRole(RolesLib.STRATEGY_MANAGER)
    {
        StateSetterMASLib.removeStrategy(strategy);
    }

    /// @dev Overridden to route through {StateSetterMASLib}, which additionally moves
    ///      `MASLib.strategy` onto `toStrategy` when the reconciled strategy was the designated
    ///      non-base deposit destination (or clears it on the `address(0)` loss write-off branch).
    ///      Keeps the base contract's "callable while paused" incident-response semantics.
    function reconcileHaltedStrategy(address fromStrategy, address toStrategy)
        public
        virtual
        override(ConcreteStandardVaultImpl, IConcreteStandardVaultImpl)
        nonReentrant
        onlyRole(RolesLib.STRATEGY_MANAGER)
    {
        StateSetterMASLib.reconcileHaltedStrategy(fromStrategy, toStrategy);
    }

    // ── Multi-asset admin (VAULT_MANAGER) ─────────────────────────────────────

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    function configureMultiAsset(MultiAssetVaultManagerConfig configType, bytes calldata data)
        external
        virtual
        afterDelay
        onlyRole(RolesLib.VAULT_MANAGER)
        withYieldAccrual
    {
        StateSetterLib.configureMultiAsset(configType, data);
    }

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    /// @dev No `afterDelay` and no `withYieldAccrual`: delisting must remain reachable even
    ///      if a strategy's accounting view would revert.
    function removeWhitelistedAsset(address asset) external virtual onlyRole(RolesLib.VAULT_MANAGER) {
        StateSetterLib.removeWhitelistedAsset(asset);
    }

    // ── Multi-asset views ─────────────────────────────────────────────────────

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    function isWhitelistedAsset(address depositAsset) external view virtual returns (bool) {
        return MASLib.fetch().whitelistedAssets.contains(depositAsset);
    }

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    function getWhitelistedAssets() external view virtual returns (address[] memory) {
        return MASLib.fetch().whitelistedAssets.values();
    }

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    function getMultiAssetPricer() external view virtual returns (address) {
        return MASLib.fetch().pricer;
    }

    /// @inheritdoc IConcreteMultiAssetDepositAsyncVault
    function getMultiAssetStrategy() external view virtual returns (address) {
        return MASLib.fetch().strategy;
    }
}
