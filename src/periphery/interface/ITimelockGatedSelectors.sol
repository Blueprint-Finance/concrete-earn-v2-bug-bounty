// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @file ITimelockGatedSelectors.sol
 * @notice Minimal "selector-mining" interfaces for {Timelock} seed
 *         registrations whose source contracts do **not** expose a real
 *         upstream interface.
 *
 * @dev Wherever the source contract is available, {Timelock} sources the
 *      selector directly from it — either from an upstream interface
 *      (`OwnableUpgradeable.transferOwnership.selector`,
 *      `UUPSUpgradeable.upgradeToAndCall.selector`, `IConcreteFactory.*`,
 *      `IConcreteAsyncVaultImpl.*`, etc.) or from the concrete contract
 *      itself (`PeripheryFactory.*`, `ConcreteStandardVaultImpl.unpause`,
 *      `MultisigStrategy.setMultiSig`) so the seeding cannot silently drift
 *      from the real ABI. The interfaces collected here cover only the
 *      residual cases — functions that live on contracts in the AssetCx
 *      product (out of this repo).
 *
 *      These interfaces are never implemented; their sole purpose is to let
 *      {Timelock} reference the relevant `.selector` at compile time.
 */

/// @notice Selectors on the AssetCx product's `AssetCX` ERC-20 that are
///         defined directly on the contract (no `IAssetCX` interface in
///         this repo).
interface IAssetCxInheritedSelectors {
    function setTimelock(address timelock_) external;
    function unpause() external;
}

/// @notice Selectors on the AssetCx product's `ConcreteMerchant` contract
///         (no `IConcreteMerchant` interface in this repo).
interface IConcreteMerchantInheritedSelectors {
    function setTimelock(address timelock_) external;
    function emergencyMigrateUserAccount(bytes32 userId, address newAccount) external;
    function setUserAccount(bytes32 userId, address user) external;
    function setUserVault(bytes32 userId, address vault) external;
    function removeUserVault(bytes32 userId) external;
    function setUserData(bytes32 userId, bytes calldata data) external;
    function setVaultYieldConfig(address vault, address strategy_, address yieldMultisig_) external;
    function setYieldTokenWhitelisted(address token, bool whitelisted) external;
    function unpause() external;
}

/// @notice Selectors on the AssetCx product's `RedemptionClaimToken` ERC-20
///         that are not sourced from a shared interface in this repo
///         (`setTimelock`/`upgradeToAndCall` are taken from `ITimelockProtected`
///         / `UUPSUpgradeable`). `removeFromWhitelist` is a restrictive
///         correction and is deliberately not timelocked, so it is omitted.
interface IRedemptionClaimTokenInheritedSelectors {
    function addToWhitelist(address account) external;
    function unpause() external;
}

/// @notice Selectors on the AssetCx product's liquidation module  that are not sourced from a shared
///         interface in this repo (`setTimelock`/`upgradeToAndCall` are taken
///         from `ITimelockProtected` / `UUPSUpgradeable`).
interface IAssetCxLiquidationModuleInheritedSelectors {
    function setCollateralRatio(uint256 collateralRatioWad_) external;
    function setBuffer(uint256 bufferWad_) external;
    function setLiquidatableLtv(uint256 liquidatableLtvWad_) external;
    function unpause() external;
}
