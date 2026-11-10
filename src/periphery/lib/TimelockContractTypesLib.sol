// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title TimelockContractTypesLib
 * @notice Well-known `bytes4` contract-type identifiers used by the
 *         {Timelock} artifact registry.
 *
 * @dev Each protected contract is bound to one of these types via
 *      {Timelock.bindContract}; the registry then resolves
 *      `(contractType, artifact) -> tier` for `propose`-time delay lookups.
 *      All values are `bytes4(keccak256("<NAME>"))` — derived once at deploy
 *      time and treated as opaque tags thereafter.
 *
 * @custom:protocol Concrete Earn V2
 */
library TimelockContractTypesLib {
    /// @notice Contract type used to self-bind the timelock itself so that
    ///         {Timelock.upgradeToAndCall} (and other self-timelocked admin
    ///         functions) can flow through the same {Timelock.afterDelay}
    ///         machinery as any other protected function.
    /// @dev `bytes4(keccak256("TIMELOCK"))` == `0xaefebe17`.
    bytes4 internal constant CT_TIMELOCK = bytes4(keccak256("TIMELOCK"));

    /// @notice Contract type used for `ConcreteStandardVaultImpl`-based vaults
    ///         (and subclasses such as `ConcreteAsyncVaultImpl`). The artifact
    ///         registrations seeded in {Timelock.initialize} cover the
    ///         role-protected surface defined in `ConcreteStandardVaultImpl`.
    /// @dev `bytes4(keccak256("VAULT"))` == `0x68fc488e`.
    bytes4 internal constant CT_VAULT = bytes4(keccak256("VAULT"));

    /// @notice Contract type used for `ConcreteFactory` instances. The
    ///         artifact registrations seeded in {Timelock.initialize} cover
    ///         all timelock-gated functions on `ConcreteFactory`.
    /// @dev `bytes4(keccak256("FACTORY"))` == `0x547b500e`.
    bytes4 internal constant CT_FACTORY = bytes4(keccak256("FACTORY"));

    /// @notice Contract type used for `BaseStrategy`-derived strategy
    ///         instances (e.g. `MultisigStrategy`, `SimpleStrategy`). The
    ///         artifact registrations seeded in {Timelock.initialize} cover
    ///         all timelock-gated functions defined in `BaseStrategy` and
    ///         `MultisigStrategy`.
    /// @dev `bytes4(keccak256("STRATEGY"))` == `0x49e34758`.
    bytes4 internal constant CT_STRATEGY = bytes4(keccak256("STRATEGY"));

    /// @notice Contract type used for `AssetCX` ERC-20 instances deployed by
    ///         the AssetCx product. The artifact registrations seeded in
    ///         {Timelock.initialize} cover all timelock-gated functions on
    ///         `AssetCX`.
    /// @dev `bytes4(keccak256("ASSETCX"))`.
    bytes4 internal constant CT_ASSETCX = bytes4(keccak256("ASSETCX"));

    /// @notice Contract type used for `ConcreteMerchant` instances deployed
    ///         by the AssetCx product. The artifact registrations seeded in
    ///         {Timelock.initialize} cover all timelock-gated functions and
    ///         grantable roles on `ConcreteMerchant`.
    /// @dev `bytes4(keccak256("MERCHANT"))`.
    bytes4 internal constant CT_MERCHANT = bytes4(keccak256("MERCHANT"));

    /// @notice Contract type used for `PeripheryFactory` instances. The
    ///         artifact registrations seeded in {Timelock.initialize} cover
    ///         all timelock-gated functions on `PeripheryFactory`.
    /// @dev `bytes4(keccak256("PERIPHERY_FACTORY"))`.
    bytes4 internal constant CT_PERIPHERY_FACTORY = bytes4(keccak256("PERIPHERY_FACTORY"));

    /// @notice Contract type used for `RedemptionClaimToken` instances deployed
    ///         by the AssetCx product (one per collateral/debt market pair, e.g.
    ///         `rBTCcx-USD1`). The artifact registrations seeded in
    ///         {Timelock.initialize} cover all timelock-gated functions and
    ///         grantable roles on the token.
    /// @dev `bytes4(keccak256("REDEMPTION_CLAIM_TOKEN"))`.
    bytes4 internal constant CT_REDEMPTION_CLAIM_TOKEN = bytes4(keccak256("REDEMPTION_CLAIM_TOKEN"));

    /// @notice Contract type used for the AssetCx liquidation module (currently
    ///         venue-backed by `DolomiteLiquidationModule`). Named generically so
    ///         the binding stays venue-agnostic if the backing protocol changes.
    ///         The artifact registrations seeded in {Timelock.initialize} cover
    ///         all timelock-gated functions and grantable roles on the module.
    /// @dev `bytes4(keccak256("ASSETCX_LIQUIDATION_MODULE"))`.
    bytes4 internal constant CT_ASSETCX_LIQUIDATION_MODULE = bytes4(keccak256("ASSETCX_LIQUIDATION_MODULE"));

    /// @notice Contract type used for `HookContainer` clones (deployed via
    ///         ClonesWithImmutableArgs, one per vault). The artifact
    ///         registrations seeded in {Timelock.initialize} cover the
    ///         timelock-gated hook-management surface (`addHook`, `replaceHook`,
    ///         `removeHook`) and the `setTimelock` admin function.
    /// @dev `bytes4(keccak256("HOOK_CONTAINER"))`.
    bytes4 internal constant CT_HOOK_CONTAINER = bytes4(keccak256("HOOK_CONTAINER"));

    /// @notice Contract type used for `OracleModule` deployments (the price-feed
    ///         registry consumed by `OracleAssetPricer` and the periphery
    ///         position helpers). The artifact registrations seeded in
    ///         {Timelock.initialize} cover the feed-configuration surface
    ///         (`setOracle`) and the ownership / `setTimelock` admin functions.
    /// @dev `bytes4(keccak256("ORACLE_MODULE"))`.
    bytes4 internal constant CT_ORACLE_MODULE = bytes4(keccak256("ORACLE_MODULE"));
}
