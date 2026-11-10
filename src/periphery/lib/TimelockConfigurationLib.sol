// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin
// ─────────────────────────────────────────────────────────────────────────────
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {ITimelock} from "../interface/ITimelock.sol";
import {
    IAssetCxInheritedSelectors,
    IConcreteMerchantInheritedSelectors,
    IRedemptionClaimTokenInheritedSelectors,
    IAssetCxLiquidationModuleInheritedSelectors
} from "../interface/ITimelockGatedSelectors.sol";
import {TimelockStorageLib} from "./TimelockStorageLib.sol";
import {TimelockContractTypesLib as CT} from "./TimelockContractTypesLib.sol";
import {TimelockRolesLib} from "./TimelockRolesLib.sol";
import {PeripheryRolesLib} from "./PeripheryRolesLib.sol";
import {IConcreteStandardVaultImpl} from "../../interface/IConcreteStandardVaultImpl.sol";
import {IConcreteAsyncVaultImpl} from "../../interface/IConcreteAsyncVaultImpl.sol";
import {IConcreteMultiAssetDepositAsyncVault} from "../../interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {IConcreteFactory} from "../../interface/IConcreteFactory.sol";
import {ITimelockProtected} from "../../interface/ITimelockProtected.sol";
import {IAsyncAccounting} from "../../interface/IAsyncAccounting.sol";
import {ConcreteV2RolesLib} from "../../lib/Roles.sol";
import {ConcreteStandardVaultImpl} from "../../implementation/ConcreteStandardVaultImpl.sol";
import {BaseStrategy} from "../strategies/BaseStrategy.sol";
import {MultisigStrategy} from "../strategies/MultisigStrategy.sol";
import {PeripheryFactory} from "../factory/PeripheryFactory.sol";
import {HookContainer} from "../hooks/HookContainer.sol";
import {OracleModule} from "../oracle/OracleModule.sol";

/**
 * @title TimelockConfigurationLib
 * @notice Deploy-time configuration for the {Timelock} contract: tier codes,
 *         default tier delays, and the artifact registry seeding for every
 *         protected contract type (vault, factory, strategy, AssetCX,
 *         merchant).
 *
 * @dev    Keeps configuration data out of the runtime contract. All functions
 *         are `internal` and inlined into the caller (no DELEGATECALL
 *         overhead). Seeding helpers take the {TimelockStorageLib.TimelockStorage}
 *         pointer directly and write into the shared EIP-7201 slot.
 *
 *         By convention `TIER_1` is the *highest*-risk tier and carries the
 *         *longest* delay, with `TIER_3` the lowest, i.e.
 *         `TIER_1 ≥ TIER_2 ≥ TIER_3 ≥ MIN_DELAY`. This is a deployment-time
 *         invariant — {Timelock.updateTierDelay} does not enforce it.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 */
library TimelockConfigurationLib {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // ── Tier codes ───────────────────────────────────────────────────────────
    // Non-zero so that `bytes4(0)` can be reserved to mean "unregistered" in
    // the artifact registry.

    bytes4 internal constant TIER_1 = 0x00000001;
    bytes4 internal constant TIER_2 = 0x00000002;
    bytes4 internal constant TIER_3 = 0x00000003;

    // ── Tier delay defaults ──────────────────────────────────────────────────
    // Mirrors the tier ordering above: TIER_1 (highest risk) → 48h,
    // TIER_3 (lowest risk) → 12h.

    uint256 internal constant TIER_1_DEFAULT = 48 hours;
    uint256 internal constant TIER_2_DEFAULT = 24 hours;
    uint256 internal constant TIER_3_DEFAULT = 12 hours;

    // ── Seeding helpers ──────────────────────────────────────────────────────

    /// @dev Writes the deployment-time defaults for every tier delay.
    function seedTierDelayDefaults(TimelockStorageLib.TimelockStorage storage $) internal {
        $.tierDelay[TIER_1] = TIER_1_DEFAULT;
        $.tierDelay[TIER_2] = TIER_2_DEFAULT;
        $.tierDelay[TIER_3] = TIER_3_DEFAULT;
    }

    /// @dev Self-binds the timelock to {CT_TIMELOCK} and registers its own
    ///      administrative functions as self-timelocked so they can flow
    ///      through the same `propose → mature → execute` machinery as any
    ///      other protected function.
    /// @param $ Timelock storage pointer.
    /// @param timelock_ Address of the timelock contract being initialized
    ///        (i.e. `address(this)` from the caller's frame).
    function seedTimelockSelfArtifacts(TimelockStorageLib.TimelockStorage storage $, address timelock_) internal {
        $.contractTypeOf[timelock_] = CT.CT_TIMELOCK;
        $.artifactDelayTier[CT.CT_TIMELOCK][bytes32(UUPSUpgradeable.upgradeToAndCall.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_TIMELOCK][bytes32(ITimelock.updateTierDelay.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_TIMELOCK][bytes32(ITimelock.changeTier.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_TIMELOCK][bytes32(ITimelock.unbindContract.selector)] = TIER_2;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        // Granting these privileged roles routes through the timelock at
        // TIER_2. PROPOSER / GUARDIAN / JANITOR are intentionally left
        // unregistered: their grants bypass the delay entirely, enforced by
        // the {Timelock.grantRole} override.
        $.artifactDelayTier[CT.CT_TIMELOCK][TimelockRolesLib.CONFIG_ROLE] = TIER_2;
        $.artifactDelayTier[CT.CT_TIMELOCK][TimelockRolesLib.OVERRIDE_ROLE] = TIER_1;
        $.artifactDelayTier[CT.CT_TIMELOCK][TimelockRolesLib.UPGRADER_ROLE] = TIER_1;
        $.artifactDelayTier[CT.CT_TIMELOCK][DEFAULT_ADMIN_ROLE] = TIER_1;
    }

    /// @dev Seeds the {CT_VAULT} artifact registry with every timelock-gated
    ///      function or role defined or inherited by `ConcreteStandardVaultImpl`
    ///      (and its async subclasses `ConcreteAsyncVaultImpl` /
    ///      `ConcreteMultiAssetDepositAsyncVault`). `removeWhitelistedAsset` is a
    ///      restrictive correction (instant, like {OracleModule.removeOracle}) and
    ///      is therefore not registered.
    function seedConcreteStandardVaultArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors from IConcreteStandardVaultImpl ────────────
        $.artifactDelayTier[CT.CT_VAULT][bytes32(IConcreteStandardVaultImpl.addStrategy.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][bytes32(IConcreteStandardVaultImpl.setHooks.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][bytes32(IConcreteStandardVaultImpl.configure.selector)] = TIER_2;
        // Permissive multi-asset admin (add whitelist / set pricer / set strategy).
        $.artifactDelayTier[CT.CT_VAULT][bytes32(IConcreteMultiAssetDepositAsyncVault.configureMultiAsset.selector)] =
        TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][bytes32(IConcreteStandardVaultImpl.updateManagementFeeRecipient.selector)] =
        TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][bytes32(IConcreteStandardVaultImpl.updatePerformanceFeeRecipient.selector)] =
        TIER_2;

        // ── Inherited / not-in-IConcreteStandardVaultImpl selectors ──────
        // Selectors below are pulled from the upstream interfaces wherever
        // possible so the seeding cannot silently drift from the real ABI.
        $.artifactDelayTier[CT.CT_VAULT][bytes32(OwnableUpgradeable.transferOwnership.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_VAULT][bytes32(OwnableUpgradeable.renounceOwnership.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_VAULT][bytes32(IConcreteAsyncVaultImpl.setUnwindCostCap.selector)] = TIER_2;
        // `pause()` / `unpause()` are declared directly on
        // `ConcreteStandardVaultImpl` (no upstream interface), so the selector
        // is sourced straight from the concrete contract.
        $.artifactDelayTier[CT.CT_VAULT][bytes32(ConcreteStandardVaultImpl.unpause.selector)] = TIER_3;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        // `_artifactFor` decodes the role from `args` and uses it as the
        // artifact key, so each restricted role registers under its own bytes32.
        $.artifactDelayTier[CT.CT_VAULT][ConcreteV2RolesLib.ROLE_ADMIN] = TIER_1;
        $.artifactDelayTier[CT.CT_VAULT][ConcreteV2RolesLib.VAULT_MANAGER] = TIER_1;
        $.artifactDelayTier[CT.CT_VAULT][ConcreteV2RolesLib.STRATEGY_MANAGER] = TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][ConcreteV2RolesLib.HOOK_MANAGER] = TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][ConcreteV2RolesLib.ALLOCATOR] = TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][ConcreteV2RolesLib.PRIORITY_WITHDRAWAL_EXECUTOR] = TIER_2;
        $.artifactDelayTier[CT.CT_VAULT][ConcreteV2RolesLib.PAUSER] = TIER_3;
    }

    /// @dev Seeds the {CT_FACTORY} artifact registry with every timelock-gated
    ///      function defined or inherited by `ConcreteFactory`.
    function seedConcreteFactoryArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors from IConcreteFactory ──────────────────────
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(IConcreteFactory.approveImplementation.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(IConcreteFactory.setMigratable.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(IConcreteFactory.setMigratableByAddress.selector)] = TIER_2;
        // unblockImplementation re-enables an impl, so it is timelocked like approval; unsetMigratable
        // is a restrictive correction (FM-only, not timelocked) and is therefore not registered.
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(IConcreteFactory.unblockImplementation.selector)] = TIER_2;

        $.artifactDelayTier[CT.CT_FACTORY][bytes32(IConcreteFactory.setDefaultEnforcedVaultConfiguration.selector)] =
        TIER_2;

        // unpause is owner-gated behind the timelock; pause is immediate (manager-only) and not registered
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(IConcreteFactory.unpause.selector)] = TIER_3;

        // ── Inherited from OZ / ITimelockProtected ────────────────────────
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(UUPSUpgradeable.upgradeToAndCall.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(OwnableUpgradeable.transferOwnership.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_FACTORY][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
    }

    /// @dev Seeds the {CT_STRATEGY} artifact registry with every timelock-gated
    ///      function defined or inherited by `BaseStrategy` and `MultisigStrategy`.
    function seedBaseStrategyArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── BaseStrategy selectors ────────────────────────────────────────
        $.artifactDelayTier[CT.CT_STRATEGY][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_STRATEGY][bytes32(IAsyncAccounting.setMaxAccountingChangeThreshold.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_STRATEGY][bytes32(IAsyncAccounting.setCooldownPeriod.selector)] = TIER_3;
        // `pause()` is instant by design (no artifact); `unpause()` is gated so
        // the strategy can't silently come back online without review.
        $.artifactDelayTier[CT.CT_STRATEGY][bytes32(BaseStrategy.unpause.selector)] = TIER_3;

        // ── MultisigStrategy-specific selectors ───────────────────────────
        $.artifactDelayTier[CT.CT_STRATEGY][bytes32(MultisigStrategy.setMultiSig.selector)] = TIER_1;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        $.artifactDelayTier[CT.CT_STRATEGY][PeripheryRolesLib.ROLE_ADMIN] = TIER_1;
        $.artifactDelayTier[CT.CT_STRATEGY][PeripheryRolesLib.STRATEGY_ADMIN] = TIER_2;
        $.artifactDelayTier[CT.CT_STRATEGY][PeripheryRolesLib.STRATEGY_UPGRADER] = TIER_2;
    }

    /// @dev Seeds the {CT_PERIPHERY_FACTORY} artifact registry with every
    ///      timelock-gated function defined on `PeripheryFactory`.
    function seedPeripheryFactoryArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors ────────────────────────────────────────────
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.approveStrategyImpl.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.setStrategyMigratable.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.approvePMHImpl.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.approveHookImpl.selector)] = TIER_2;

        // unblock* re-enables an impl, so it is timelocked like approval; unsetStrategyMigratable is a
        // restrictive correction (FM-only, not timelocked) and is therefore not registered.
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.unblockStrategyImpl.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.unblockPMHImpl.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.unblockHookImpl.selector)] = TIER_2;

        // unpause is owner-gated behind the timelock; pause is immediate (manager-only) and not registered
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(PeripheryFactory.unpause.selector)] = TIER_3;

        // ── Inherited from OZ / ITimelockProtected ────────────────────────
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(UUPSUpgradeable.upgradeToAndCall.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(OwnableUpgradeable.transferOwnership.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_PERIPHERY_FACTORY][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
    }

    /// @dev Seeds the {CT_ASSETCX} artifact registry with every timelock-gated
    ///      function or role on the AssetCX ERC-20 (defined in the AssetCx
    ///      product, layered on top of earn-v2-core).
    function seedAssetCxArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors ────────────────────────────────────────────
        $.artifactDelayTier[CT.CT_ASSETCX][bytes32(UUPSUpgradeable.upgradeToAndCall.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_ASSETCX][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
        // `pause()` is instant by design (no artifact); `unpause()` is gated
        // so the system can't silently come back online without review.
        $.artifactDelayTier[CT.CT_ASSETCX][bytes32(IAssetCxInheritedSelectors.unpause.selector)] = TIER_3;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        // `keccak256("MERCHANT_ROLE")` — sourced from `AssetCxRolesLib.MERCHANT_ROLE`
        // in the AssetCx product. Held by the `ConcreteMerchant` contract;
        // logic-class blast (unbounded AssetCX mint), so highest tier.
        $.artifactDelayTier[CT.CT_ASSETCX][DEFAULT_ADMIN_ROLE] = TIER_1;
        $.artifactDelayTier[CT.CT_ASSETCX][keccak256("MERCHANT_ROLE")] = TIER_1;
    }

    /// @dev Seeds the {CT_MERCHANT} artifact registry with every timelock-gated
    ///      function or role on `ConcreteMerchant` (defined in the AssetCx
    ///      product). `OPERATOR_ROLE` administrative grants flow through the
    ///      registry too, but the operational functions gated by `OPERATOR_ROLE`
    ///      themselves (`mintAndDeposit`, `finalize*`) are deliberately NOT
    ///      registered — they run at hot-key cadence and bypass the timelock.
    function seedConcreteMerchantArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors ────────────────────────────────────────────
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(UUPSUpgradeable.upgradeToAndCall.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
        $.artifactDelayTier[
            CT.CT_MERCHANT
        ][bytes32(IConcreteMerchantInheritedSelectors.emergencyMigrateUserAccount.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(IConcreteMerchantInheritedSelectors.setUserAccount.selector)] =
        TIER_3;
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(IConcreteMerchantInheritedSelectors.setUserVault.selector)] = TIER_3;
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(IConcreteMerchantInheritedSelectors.removeUserVault.selector)] =
        TIER_3;
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(IConcreteMerchantInheritedSelectors.setUserData.selector)] = TIER_3;
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(IConcreteMerchantInheritedSelectors.setVaultYieldConfig.selector)] =
            TIER_2;
        $.artifactDelayTier[
            CT.CT_MERCHANT
        ][bytes32(IConcreteMerchantInheritedSelectors.setYieldTokenWhitelisted.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_MERCHANT][bytes32(IConcreteMerchantInheritedSelectors.unpause.selector)] = TIER_3;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        // `keccak256("MERCHANT_MANAGER_ROLE")` and `keccak256("OPERATOR_ROLE")`
        // are sourced from the constants on `ConcreteMerchant`.
        $.artifactDelayTier[CT.CT_MERCHANT][DEFAULT_ADMIN_ROLE] = TIER_1;
        $.artifactDelayTier[CT.CT_MERCHANT][keccak256("MERCHANT_MANAGER_ROLE")] = TIER_1;
        $.artifactDelayTier[CT.CT_MERCHANT][keccak256("OPERATOR_ROLE")] = TIER_2;
    }

    /// @dev Seeds the {CT_REDEMPTION_CLAIM_TOKEN} artifact registry with every
    ///      timelock-gated function or role on the `RedemptionClaimToken` ERC-20
    ///      (defined in the AssetCx product, layered on top of earn-v2-core).
    function seedRedemptionClaimTokenArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors ────────────────────────────────────────────
        $.artifactDelayTier[CT.CT_REDEMPTION_CLAIM_TOKEN][bytes32(UUPSUpgradeable.upgradeToAndCall.selector)] = TIER_1;
        $.artifactDelayTier[CT.CT_REDEMPTION_CLAIM_TOKEN][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
        // `addToWhitelist` widens the closed-ecosystem transfer set (a new address
        // may custody the token), so it is gated; `removeFromWhitelist` is a
        // restrictive correction (instant, not timelocked) and is not registered.
        $.artifactDelayTier[
            CT.CT_REDEMPTION_CLAIM_TOKEN
        ][bytes32(IRedemptionClaimTokenInheritedSelectors.addToWhitelist.selector)] = TIER_2;
        // `pause()` is instant by design; `unpause()` is gated so the token
        // can't silently come back online without review.
        $.artifactDelayTier[
            CT.CT_REDEMPTION_CLAIM_TOKEN
        ][bytes32(IRedemptionClaimTokenInheritedSelectors.unpause.selector)] = TIER_3;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        // `keccak256("LIQUIDATION_MODULE_ROLE")` / `keccak256("WHITELIST_MANAGER_ROLE")`
        // are sourced from `AssetCxRolesLib` in the AssetCx product. `PAUSER_ROLE`
        // grants intentionally bypass the delay (enforced in the token's
        // `grantRole` override) and so are left unregistered.
        // LIQUIDATION_MODULE_ROLE is the sole mint/burn authority (logic-class
        // blast), so it carries the highest tier.
        $.artifactDelayTier[CT.CT_REDEMPTION_CLAIM_TOKEN][DEFAULT_ADMIN_ROLE] = TIER_1;
        $.artifactDelayTier[CT.CT_REDEMPTION_CLAIM_TOKEN][keccak256("LIQUIDATION_MODULE_ROLE")] = TIER_1;
        $.artifactDelayTier[CT.CT_REDEMPTION_CLAIM_TOKEN][keccak256("WHITELIST_MANAGER_ROLE")] = TIER_2;
    }

    /// @dev Seeds the {CT_ASSETCX_LIQUIDATION_MODULE} artifact registry with
    ///      every timelock-gated function or role on the AssetCx liquidation
    ///      module (defined in the AssetCx
    ///      product). The operational entrypoints gated by `LIQUIDATOR_ROLE`
    ///      (`initiateLiquidationCollateralSwap` / `finalizeLiquidationAndRepay`)
    ///      run at hot-key cadence and are deliberately NOT registered.
    function seedAssetCxLiquidationModuleArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors ────────────────────────────────────────────
        $.artifactDelayTier[CT.CT_ASSETCX_LIQUIDATION_MODULE][bytes32(UUPSUpgradeable.upgradeToAndCall.selector)] =
        TIER_1;
        $.artifactDelayTier[CT.CT_ASSETCX_LIQUIDATION_MODULE][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
        // Liquidation-sizing economics: RCT minted per unit of debt and the
        // collateral over-withdrawal buffer. Config-class, so mid tier.
        $.artifactDelayTier[
            CT.CT_ASSETCX_LIQUIDATION_MODULE
        ][bytes32(IAssetCxLiquidationModuleInheritedSelectors.setCollateralRatio.selector)] = TIER_3;
        $.artifactDelayTier[
            CT.CT_ASSETCX_LIQUIDATION_MODULE
        ][bytes32(IAssetCxLiquidationModuleInheritedSelectors.setBuffer.selector)] = TIER_3;
        // LTV band a plain `LIQUIDATOR_ROLE` caller is confined to. Lowering it widens the set of
        // positions a hot key can act on, so it sits a tier above the sizing knobs.
        $.artifactDelayTier[
            CT.CT_ASSETCX_LIQUIDATION_MODULE
        ][bytes32(IAssetCxLiquidationModuleInheritedSelectors.setLiquidatableLtv.selector)] = TIER_2;
        // `pause()` is instant by design; `unpause()` is gated.
        $.artifactDelayTier[
            CT.CT_ASSETCX_LIQUIDATION_MODULE
        ][bytes32(IAssetCxLiquidationModuleInheritedSelectors.unpause.selector)] = TIER_3;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        // `keccak256("LIQUIDATOR_ROLE")` is sourced from `AssetCxRolesLib` in the
        // AssetCx product. `PAUSER_ROLE` grants intentionally bypass the delay
        // (enforced in the module's `grantRole` override) and are left
        // unregistered.
        $.artifactDelayTier[CT.CT_ASSETCX_LIQUIDATION_MODULE][DEFAULT_ADMIN_ROLE] = TIER_1;
        $.artifactDelayTier[CT.CT_ASSETCX_LIQUIDATION_MODULE][keccak256("LIQUIDATOR_ROLE")] = TIER_2;
    }

    /// @dev Seeds the {CT_HOOK_CONTAINER} artifact registry with every
    ///      timelock-gated function on `HookContainer`.
    function seedHookContainerArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors ────────────────────────────────────────────
        // `addHook` / `replaceHook` widen or swap the enforced hook set, so they are
        // gated; `removeHook` lifts enforcement (functionally additive), so it is gated
        // at the same tier rather than treated as an instant kill switch.
        $.artifactDelayTier[CT.CT_HOOK_CONTAINER][bytes32(HookContainer.addHook.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_HOOK_CONTAINER][bytes32(HookContainer.replaceHook.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_HOOK_CONTAINER][bytes32(HookContainer.removeHook.selector)] = TIER_2;

        // ── Inherited from ITimelockProtected ─────────────────────────────
        $.artifactDelayTier[CT.CT_HOOK_CONTAINER][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;

        // ── Per-role artifacts for `grantRole` ────────────────────────────
        // The container's `grantRole` override routes every grant through the
        // timelock; `_artifactFor` decodes the role and looks it up here.
        // DEFAULT_ADMIN_ROLE controls the whole container (highest tier);
        // HOOK_MANAGER_ROLE gates hook management (mid tier, matching
        // addHook/replaceHook).
        $.artifactDelayTier[CT.CT_HOOK_CONTAINER][DEFAULT_ADMIN_ROLE] = TIER_1;
        $.artifactDelayTier[CT.CT_HOOK_CONTAINER][PeripheryRolesLib.HOOK_MANAGER_ROLE] = TIER_2;
    }

    /// @dev Seeds the {CT_ORACLE_MODULE} artifact registry with every
    ///      timelock-gated function on `OracleModule`. `removeOracle` is instant
    ///      by design (a restrictive correction that makes `getPrice` revert
    ///      rather than return an unvetted price) and is therefore not
    ///      registered. `OracleModule` is a plain `Ownable` deployment with no
    ///      proxy and no grantable roles, so there is no `upgradeToAndCall` or
    ///      per-role artifact to register.
    function seedOracleModuleArtifacts(TimelockStorageLib.TimelockStorage storage $) internal {
        // ── Function selectors ────────────────────────────────────────────
        // `setOracle` installs or repoints an asset's price feed and its
        // validation bounds — the value that every consuming pricer trusts — so
        // it is gated. Config-class, hence mid tier.
        $.artifactDelayTier[CT.CT_ORACLE_MODULE][bytes32(OracleModule.setOracle.selector)] = TIER_2;

        // `setSequencerOracle` installs, retunes or clears the L2 uptime gate on `getPrice`.
        // Clearing it widens what the module will serve, so it is gated in both directions.
        $.artifactDelayTier[CT.CT_ORACLE_MODULE][bytes32(OracleModule.setSequencerOracle.selector)] = TIER_2;

        // ── Ownership / timelock admin ────────────────────────────────────
        // `renounceOwnership` is permanently disabled on the module and so has
        // no artifact.
        $.artifactDelayTier[CT.CT_ORACLE_MODULE][bytes32(OracleModule.transferOwnership.selector)] = TIER_2;
        $.artifactDelayTier[CT.CT_ORACLE_MODULE][bytes32(ITimelockProtected.setTimelock.selector)] = TIER_1;
    }
}
