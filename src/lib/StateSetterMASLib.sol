// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ConcreteMultiAssetDepositAsyncVaultStorageLib as MASLib
} from "./storage/ConcreteMultiAssetDepositAsyncVaultStorageLib.sol";
import {IConcreteMultiAssetDepositAsyncVault as IMAV} from "../interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {StateSetterLib} from "./StateSetterLib.sol";

/**
 * @title StateSetterMASLib
 * @notice Multi-asset overlay on the strategy-registry lifecycle setters in {StateSetterLib}.
 *
 * @dev    {ConcreteMultiAssetDepositAsyncVault} designates one registered strategy as the
 *         destination for every non-base deposit, stored as `MASLib.strategy`. That pointer is a
 *         soft foreign key into the base vault's registry (`SVLib.strategies` /
 *         `SVLib.strategyData`), living in a different EIP-7201 namespace and validated only at
 *         write time by {StateSetterLib-setMultiAssetStrategy}.
 *
 *         The registry is mutated by a different role (STRATEGY_MANAGER), through functions that
 *         know nothing about the pointer. Two of them delete the row the pointer names, which would
 *         otherwise leave it dangling: {MultiAssetVaultHelperLib-prepareNonBaseDeposit} then reads
 *         `status == Inactive` and every non-base deposit reverts `MultiAssetStrategyNotActive`,
 *         while base-asset deposits keep working. A dangling pointer is also not inert — re-adding
 *         the same address later flips it back to `Active` and the stale pointer silently resumes
 *         routing deposits with no VAULT_MANAGER re-designation in between.
 *
 *         This library wraps those two setters so the pointer follows the lifecycle of the strategy
 *         it names. It lives apart from {StateSetterLib} so that plain (non-multi-asset) vaults
 *         never carry the overlay: they keep calling {StateSetterLib} directly, and only
 *         {ConcreteMultiAssetDepositAsyncVault} overrides its entry points to route here.
 *
 *         Each wrapper delegates the registry work to {StateSetterLib} rather than reimplementing
 *         it, so the two copies cannot drift. An external library call is itself a DELEGATECALL, so
 *         the inner call runs in the same (vault) storage context as this one.
 *
 *         {StateSetterLib-toggleStrategyStatus} is deliberately **not** wrapped. A halt is
 *         reversible and carries no delay, so halt → unhalt self-heals today; clearing the pointer
 *         there would turn a reversible blip into a mandatory 24h repair through the timelocked
 *         `configureMultiAsset`. The revert `MultiAssetStrategyNotActive(strategy)` already names
 *         the culprit.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 */
library StateSetterMASLib {
    /// @dev Removes `strategy` from the registry, then clears the non-base deposit pointer if it
    ///      named that strategy. Removal is terminal, so there is no successor to hand the flow to;
    ///      `MASLib.strategy` goes to `address(0)` and subsequent non-base deposits fail with the
    ///      explicit `MultiAssetNotConfigured` rather than dangling.
    function removeStrategy(address strategy) external {
        StateSetterLib.removeStrategy(strategy);
        _syncMultiAssetStrategy(strategy, address(0));
    }

    /// @dev Reconciles a halted strategy, then moves the non-base deposit pointer with the position
    ///      if it named `fromStrategy`. When `toStrategy` is non-zero the allocation has just been
    ///      migrated onto it and {StateSetterLib-reconcileHaltedStrategy} has already checked it is
    ///      registered and `Active` — the same predicate {StateSetterLib-setMultiAssetStrategy}
    ///      enforces — so the pointer follows it and the non-base flow stays open. The
    ///      `toStrategy == address(0)` branch is the loss write-off: no successor exists, so the
    ///      pointer is cleared.
    function reconcileHaltedStrategy(address fromStrategy, address toStrategy) external {
        StateSetterLib.reconcileHaltedStrategy(fromStrategy, toStrategy);
        _syncMultiAssetStrategy(fromStrategy, toStrategy);
    }

    /// @dev Repoints or clears `MASLib.strategy` when `removed` was the designated strategy, and
    ///      does nothing otherwise. No-op for a vault that never configured the multi-asset flow:
    ///      `MASLib.strategy` is `address(0)` there while `removed` is always a registered,
    ///      non-zero set member, so the guard cannot match.
    /// @param removed The strategy that has just left the registry.
    /// @param newStrategy The successor the position moved to, or `address(0)` when there is none.
    function _syncMultiAssetStrategy(address removed, address newStrategy) private {
        MASLib.ConcreteMultiAssetDepositAsyncVaultStorage storage $mas = MASLib.fetch();
        if ($mas.strategy != removed) return;

        $mas.strategy = newStrategy;
        emit IMAV.MultiAssetStrategySet(newStrategy);
    }
}
