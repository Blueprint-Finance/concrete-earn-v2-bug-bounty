// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IConcreteAsyncVaultImpl} from "./IConcreteAsyncVaultImpl.sol";

/**
 * @title IConcreteMultiAssetDepositAsyncVault
 * @dev Interface for the multi-asset deposit async vault. It extends the async vault with a
 *      deposit entrypoint that accepts an explicit deposit asset, enabling deposits denominated
 *      in assets other than the base `asset()` while keeping base accounting.
 * @dev Base-asset deposits route to the inherited ERC-4626 flow. Whitelisted non-base deposits are
 *      priced to base value via the configured pricer, mint the corresponding shares, and are
 *      routed straight to the configured (Active) strategy which records the position in base units.
 */
interface IConcreteMultiAssetDepositAsyncVault is IConcreteAsyncVaultImpl {
    /**
     * @dev Thrown when a deposit asset is not accepted for multi-asset deposits.
     * @param asset The deposit asset that was rejected.
     */
    error AssetNotWhitelisted(address asset);

    /**
     * @dev Thrown when attempting to whitelist an asset that is already whitelisted.
     * @param asset The asset that was already whitelisted.
     */
    error AssetAlreadyWhitelisted(address asset);

    /**
     * @dev Thrown when attempting to whitelist the base `asset()`, which is implicitly accepted
     *      and always routed to the inherited ERC-4626 flow.
     */
    error CannotWhitelistBaseAsset();

    /**
     * @dev Thrown when attempting to whitelist the vault's own share token (`address(this)`).
     */
    error CannotWhitelistShareToken();

    /**
     * @dev Thrown when attempting to set an invalid pricer (address(0)).
     */
    error InvalidPricer();

    /**
     * @dev Thrown when a non-base deposit is attempted while the pricer or the multi-asset strategy
     *      has not been configured yet.
     */
    error MultiAssetNotConfigured();

    /**
     * @dev Thrown when the configured multi-asset strategy is not currently Active.
     * @param strategy The strategy that was rejected.
     */
    error MultiAssetStrategyNotActive(address strategy);

    /**
     * @dev Thrown when a non-base deposit converts to a base value of zero (dust), which would mint
     *      zero shares while still transferring assets.
     * @param depositAsset The non-base asset deposited.
     * @param assets The amount that converted to zero base value.
     */
    error ZeroBaseValue(address depositAsset, uint256 assets);

    /**
     * @dev Thrown when the strategy-reported `baseAllocated` does not equal the pricer `baseValue`.
     */
    error BaseAllocatedMismatch(uint256 baseAllocated, uint256 baseValue);

    /**
     * @dev Thrown when attempting to set a multi-asset strategy that is not a registered, Active
     *      strategy of the vault.
     * @param strategy The strategy that was rejected.
     */
    error InvalidMultiAssetStrategy(address strategy);

    /**
     * @dev Thrown when {configureMultiAsset} is called with an unsupported config type.
     */
    error InvalidMultiAssetConfig();

    /**
     * @dev Emitted when a non-base deposit asset is added to the whitelist.
     * @param asset The asset that was whitelisted.
     */
    event WhitelistedAssetAdded(address indexed asset);

    /**
     * @dev Emitted when a non-base deposit asset is removed from the whitelist.
     * @param asset The asset that was removed.
     */
    event WhitelistedAssetRemoved(address indexed asset);

    /**
     * @dev Emitted when the asset pricer is set.
     * @param pricer The new pricer address.
     */
    event MultiAssetPricerSet(address indexed pricer);

    /**
     * @dev Emitted when the multi-asset deposit strategy is set.
     * @param strategy The new strategy address.
     */
    event MultiAssetStrategySet(address indexed strategy);

    /**
     * @dev Emitted on a successful non-base multi-asset deposit.
     * @param caller The address that initiated the deposit.
     * @param receiver The address that received the minted shares.
     * @param depositAsset The non-base asset deposited.
     * @param assets The amount of `depositAsset` deposited.
     * @param baseValue The base-asset value credited to vault accounting.
     * @param shares The shares minted to `receiver`.
     */
    event MultiAssetDeposit(
        address indexed caller,
        address indexed receiver,
        address indexed depositAsset,
        uint256 assets,
        uint256 baseValue,
        uint256 shares
    );

    /**
     * @dev Enumeration of the multi-asset-vault–configurable parameters, dispatched by
     *      {configureMultiAsset}. Kept separate from {VaultManagerConfig} so the base interface
     *      stays free of multi-asset concerns. Delisting is {removeWhitelistedAsset}, not a
     *      dispatcher branch — it is a restrictive correction and must stay immediate.
     */
    enum MultiAssetVaultManagerConfig {
        AddWhitelistedAsset,
        SetPricer,
        SetMultiAssetStrategy
    }

    /**
     * @notice Multi-asset admin setter that dispatches based on `configType`. Only callable by
     *         VAULT_MANAGER, timelock-gated. A single dispatcher is used (instead of dedicated
     *         setters) to keep the vault runtime bytecode under the EIP-170 limit.
     * @param configType The parameter to configure (see {MultiAssetVaultManagerConfig}).
     * @param data ABI-encoded value for the chosen config type:
     *   - AddWhitelistedAsset:    abi.encode(address asset) — base `asset()` is rejected
     *   - SetPricer:              abi.encode(address pricer) — must be non-zero
     *   - SetMultiAssetStrategy:  abi.encode(address strategy) — must be registered and Active
     */
    function configureMultiAsset(MultiAssetVaultManagerConfig configType, bytes calldata data) external;

    /**
     * @notice Removes a non-base deposit asset from the whitelist. Only blocks new deposits;
     *         existing allocations originated from that asset stay fully accounted for.
     * @dev VAULT_MANAGER-only and intentionally NOT timelocked: delisting a mispriced or
     *      compromised asset is a restrictive correction and must stay available immediately,
     *      matching {OracleModule-removeOracle} / {IConcreteFactory-unsetMigratable}.
     * @param asset The whitelisted asset to remove.
     */
    function removeWhitelistedAsset(address asset) external;

    /**
     * @notice Returns whether `asset` is a whitelisted non-base deposit asset.
     */
    function isWhitelistedAsset(address asset) external view returns (bool);

    /**
     * @notice Returns the full set of whitelisted non-base deposit assets.
     * @dev Does not include the base `asset()`, which is always accepted via the inherited ERC-4626
     *      flow. Order is unspecified and may change when an asset is removed.
     */
    function getWhitelistedAssets() external view returns (address[] memory);

    /**
     * @notice Returns the configured asset pricer, or address(0) if unset.
     */
    function getMultiAssetPricer() external view returns (address);

    /**
     * @notice Returns the configured multi-asset deposit strategy, or address(0) if unset.
     */
    function getMultiAssetStrategy() external view returns (address);

    /**
     * @notice Deposits `assets` of `depositAsset` on behalf of `receiver`, minting vault shares.
     * @dev Multi-asset deposit entrypoint. When `depositAsset` equals the base `asset()`, the
     *      call is routed to the inherited ERC-4626 `deposit(uint256,address)` flow (idle balance +
     *      mint). A whitelisted non-base asset is priced to base value, mints the corresponding
     *      shares, and is pushed to the configured Active strategy. Reverts with
     *      {AssetNotWhitelisted} for non-whitelisted assets.
     * @param depositAsset The ERC-20 token being deposited.
     * @param assets The amount of `depositAsset` to deposit.
     * @param receiver The address that receives the minted shares.
     * @return shares The amount of shares minted to `receiver`.
     */
    function deposit(address depositAsset, uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Simulates the amount of shares minted for depositing `assets` of `depositAsset`.
     * @dev When `depositAsset` equals the base `asset()`, routes to the inherited
     *      `previewDeposit(uint256)`. A whitelisted non-base asset applies the same config,
     *      whitelist, Active-strategy and non-zero base-value checks as {deposit}, then prices to
     *      base and previews. Reverts with {AssetNotWhitelisted} for non-whitelisted assets.
     * @param depositAsset The ERC-20 token being previewed.
     * @param assets The amount of `depositAsset`.
     * @return shares The amount of shares that would be minted.
     */
    function previewDeposit(address depositAsset, uint256 assets) external view returns (uint256 shares);
}
