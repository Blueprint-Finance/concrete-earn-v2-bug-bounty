// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title ConcreteStandardVaultImpl
 * @notice ERC-4626 upgradeable standard vault implementation for the Concrete Earn V2 protocol.
 *         Holds an underlying ERC20 asset and exposes deposit/mint/withdraw/redeem flows.
 *         Integrates with strategy modules to route assets to yield sources.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:oz-upgrades Use OZ Upgradeable patterns and eip7201 storage layout
 * @custom:source on request
 * @custom:audits on request
 * @custom:license AGPL-3.0
 */

// ─────────────────────────────────────────────────────────────────────────────
// External dependencies
// ─────────────────────────────────────────────────────────────────────────────
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    ERC4626Upgradeable,
    IERC20,
    IERC4626,
    Math
} from "@openzeppelin-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {Address} from "@openzeppelin-contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {IContractId} from "../interface/IContractId.sol";
import {IUpgradeableVault} from "../interface/IUpgradeableVault.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {ITimelockProtected} from "../interface/ITimelockProtected.sol";
import {IDefaultEnforcedVaultConfiguration} from "../interface/IDefaultEnforcedVaultConfiguration.sol";
import {IHurdleRateOracle} from "../interface/IHurdleRateOracle.sol";
import {IStrategyTemplate} from "../interface/IStrategyTemplate.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal modules/contracts
// ─────────────────────────────────────────────────────────────────────────────
import {IAllocateModule} from "../module/AllocateModule.sol";
import {UpgradeableVault} from "../common/UpgradeableVault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal libraries
// ─────────────────────────────────────────────────────────────────────────────
import {ConcreteV2ConversionLib as ConversionLib} from "../lib/Conversion.sol";
import {StandardVaultHelperLib} from "../lib/StandardVaultHelperLib.sol";
import {Hooks, HooksLibV2 as HooksLib} from "../lib/Hooks.sol";
import {IHook} from "../interface/IHook.sol";
import {ConcreteV2RolesLib as RolesLib} from "../lib/Roles.sol";
import {ERC20UpgradeableWithTransferHook} from "../common/ERC20UpgradeableWithTransferHook.sol";
import {StateInitLib} from "../lib/StateInitLib.sol";
import {StateSetterLib} from "../lib/StateSetterLib.sol";
import {ContractIdEncoding} from "../lib/ContractIdEncoding.sol";
import {WithdrawLib} from "../lib/WithdrawLib.sol";
import {YieldAccrualLib} from "../lib/YieldAccrualLib.sol";
import {UserActionsLib} from "../lib/UserActionsLib.sol";
import {TimelockIntegrationLib} from "../lib/TimelockIntegrationLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Storage layout libraries
// ─────────────────────────────────────────────────────────────────────────────
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "../lib/storage/ConcreteCachedVaultStateStorageLib.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "../lib/storage/ConcreteStandardVaultImplStorageLib.sol";
import {MigrationLib} from "../lib/MigrationLib.sol";

contract ConcreteStandardVaultImpl is
    IContractId,
    ERC20UpgradeableWithTransferHook,
    ERC4626Upgradeable,
    UpgradeableVault,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    IConcreteStandardVaultImpl
{
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;
    using ConversionLib for uint256;
    using HooksLib for Hooks;

    uint256 public constant CONTRACT_TYPE = 0; // vault

    function FLAVOUR() public pure virtual returns (uint256) {
        return 1; // standard vault
    }

    function ID() public pure virtual override(IContractId, UpgradeableVault) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 7, 0);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    /// @dev Standard vaults have no cancellation flow; async vaults override this.
    function cancellationEnabled() external view virtual returns (bool) {
        return false;
    }

    /// @dev Modifier to accrue yield before function execution
    modifier withYieldAccrual() {
        _accrueYield();
        _;
    }

    /// @dev Applied to privileged functions that require a prior {ITimelock.propose}
    ///      followed by the matured tier delay before they can execute.
    modifier afterDelay() {
        _enforceDelay();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @dev Constructor
     * @param factory The address of the factory
     */
    constructor(address factory) UpgradeableVault(factory) {}

    // ── Timelock ──────────────────────────────────────────────────────────────

    /// @inheritdoc ITimelockProtected
    function setTimelock(address timelock_) external afterDelay onlyOwner {
        TimelockIntegrationLib.setTimelock(timelock_);
        emit TimelockSet(timelock_);
    }

    /// @inheritdoc ITimelockProtected
    function activateTimelock() external onlyOwner {
        address tl = TimelockIntegrationLib.activateTimelock();
        emit TimelockActivated(tl);
    }

    /// @inheritdoc ITimelockProtected
    function getTimelock() external view returns (address timelock_, bool active_) {
        return TimelockIntegrationLib.state();
    }

    // ── Overridden access control ─────────────────────────────────────────────

    /// @notice Gates sensitive role grants behind the timelock.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (role != RolesLib.PAUSER && role != RolesLib.WITHDRAWAL_MANAGER) {
            _enforceDelay();
        }
        super.grantRole(role, account);
    }

    /// @notice Prevents removing the last ROLE_ADMIN, which would leave the vault
    ///         permanently without an admin.
    /// @dev Both {revokeRole} and {renounceRole} funnel through this hook, so this single
    ///      override blocks self-revoke, self-renounce, and admin-revokes-admin alike. With
    ///      multiple ROLE_ADMINs any one of them (including the caller) can still be removed.
    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        if (role == RolesLib.ROLE_ADMIN && getRoleMemberCount(RolesLib.ROLE_ADMIN) == 1) {
            revert CannotRemoveLastRoleAdmin();
        }
        return super._revokeRole(role, account);
    }

    /// @notice Gates ownership transfers behind the timelock.
    function transferOwnership(address newOwner) public override onlyOwner afterDelay {
        super.transferOwnership(newOwner);
    }

    /// @notice Permanently disabled — renouncing ownership is not permitted.
    function renounceOwnership() public override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // ── ERC-4626 user actions ─────────────────────────────────────────────────

    /**
     * @inheritdoc IERC4626
     */
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(IERC4626, ERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        withYieldAccrual
        returns (uint256)
    {
        uint256 shares = UserActionsLib.preDeposit(assets, receiver, msg.sender, totalSupply());

        _deposit(msg.sender, receiver, assets, shares);

        UserActionsLib.postDeposit(assets, shares, receiver, msg.sender);

        return shares;
    }

    /**
     * @inheritdoc IERC4626
     */
    function mint(uint256 shares, address receiver)
        public
        virtual
        override(IERC4626, ERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        withYieldAccrual
        returns (uint256)
    {
        uint256 assets = UserActionsLib.preMint(shares, receiver, msg.sender, totalSupply());

        _deposit(msg.sender, receiver, assets, shares);

        UserActionsLib.postMint(assets, shares, receiver, msg.sender);

        return assets;
    }

    /**
     * @inheritdoc IERC4626
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override(IERC4626, ERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        withYieldAccrual
        returns (uint256)
    {
        // `maxAssets` is returned so the secondary defensive revert below can use the same
        // error data as the original implementation.
        (uint256 shares, uint256 maxAssets) =
            UserActionsLib.preWithdraw(assets, receiver, owner, msg.sender, totalSupply(), balanceOf(owner));

        // Defensive: `_executeWithdraw` normally reverts internally with
        // `InsufficientWithdrawableAssets` first, but if it ever short-fills we surface the
        // canonical ERC-4626 error.
        if (_executeWithdraw(msg.sender, receiver, owner, assets, shares) < assets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        UserActionsLib.postWithdraw(assets, shares, receiver, msg.sender);

        return shares;
    }

    /**
     * @inheritdoc IERC4626
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override(IERC4626, ERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        withYieldAccrual
        returns (uint256)
    {
        // `maxShares` is returned so the secondary defensive revert below can use the same
        // error data as the original implementation.
        (uint256 assets, uint256 maxShares) =
            UserActionsLib.preRedeem(shares, receiver, owner, msg.sender, totalSupply(), balanceOf(owner));

        // Defensive: `_executeWithdraw` normally reverts internally with
        // `InsufficientWithdrawableAssets` first, but if it ever short-fills we surface the
        // canonical ERC-4626 error.
        if (_executeWithdraw(msg.sender, receiver, owner, assets, shares) < assets) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        UserActionsLib.postRedeem(assets, shares, receiver, msg.sender);

        return assets;
    }

    // ── ERC-4626 views ────────────────────────────────────────────────────────

    /**
     * @inheritdoc IERC4626
     */
    function totalAssets()
        public
        view
        virtual
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256 totalAssetsWithYield)
    {
        (totalAssetsWithYield,) = _previewAccrueYieldAndFees();
    }

    function maxDeposit(address receiver) public view virtual override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        if (paused()) return 0;
        (uint256 totalAssetsPreview,) = _previewAccrueYieldAndFees();
        return StandardVaultHelperLib.calcMaxDeposit(
            SVLib.fetch().maxGlobalDepositAmount, SVLib.fetch().minTxDepositAmount, totalAssetsPreview
        );
    }

    function maxMint(address receiver) public view virtual override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        if (paused()) return 0;
        (uint256 totalAssetsPreview, uint256 totalSupplyPreview) = _previewAccrueYieldAndFees();
        return StandardVaultHelperLib.calcMaxMint(
            SVLib.fetch().maxGlobalDepositAmount,
            SVLib.fetch().minTxDepositAmount,
            totalAssetsPreview,
            totalSupplyPreview
        );
    }

    /**
     * @inheritdoc IERC4626
     */
    function maxWithdraw(address owner)
        public
        view
        virtual
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256 maxAssets)
    {
        if (paused()) return 0;
        (maxAssets,,) = _maxWithdrawWithSimulation(owner);
    }

    /**
     * @inheritdoc IERC4626
     */
    function maxRedeem(address owner) public view virtual override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        if (paused()) return 0;
        (uint256 expectedTotalAssets, uint256 expectedTotalSupply) = _previewAccrueYieldAndFees();

        // Get max shares using the same logic as redeem() - uses corrected calcMaxRedeem (avoids double rounding)
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        uint256 maxShares = StandardVaultHelperLib.calcMaxRedeem(
            balanceOf(owner), $.maxTxWithdrawAmount, $.minTxWithdrawAmount, expectedTotalAssets, expectedTotalSupply
        );

        // Get available liquidity (idle + withdrawable from strategies)
        // This matches the test expectation: convertToShares(min(userAssets, availableLiquidity))
        uint256 availableLiquidity = _simulateWithdraw(type(uint256).max);

        // Convert available liquidity to shares
        uint256 availableShares = availableLiquidity.calcConvertToShares(
            expectedTotalSupply, expectedTotalAssets, Math.Rounding.Floor, false
        );
        uint256 assetsOut =
            availableShares.calcConvertToAssets(expectedTotalSupply, expectedTotalAssets, Math.Rounding.Floor, false);
        if (assetsOut < $.minTxWithdrawAmount) availableShares = 0;

        // Return the minimum to ensure maxRedeem never reports more than what redeem() would accept
        // This prevents inconsistency where maxRedeem reports more shares than redeem accepts
        return availableShares > maxShares ? maxShares : availableShares;
    }

    /**
     * @dev See {IERC4626-previewDeposit}.
     */
    function previewDeposit(uint256 assets)
        public
        view
        virtual
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256)
    {
        return StandardVaultHelperLib.previewDeposit(assets);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewMint(uint256 shares) public view virtual override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        return StandardVaultHelperLib.previewMint(shares);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256)
    {
        return StandardVaultHelperLib.previewWithdraw(assets);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewRedeem(uint256 shares)
        public
        view
        virtual
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256)
    {
        return StandardVaultHelperLib.previewRedeem(shares);
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function previewAccrueYield() public view virtual returns (uint256, uint256) {
        return _previewAccrueYieldAndFees();
    }

    function decimals()
        public
        view
        virtual
        override(ERC4626Upgradeable, ERC20Upgradeable, IERC20Metadata)
        returns (uint8)
    {
        return ERC4626Upgradeable.decimals();
    }

    // ── Vault management (VAULT_MANAGER) ──────────────────────────────────────

    /// @inheritdoc IConcreteStandardVaultImpl
    function configure(IConcreteStandardVaultImpl.VaultManagerConfig configType, bytes calldata data)
        external
        nonReentrant
        afterDelay
        onlyRole(RolesLib.VAULT_MANAGER)
        withYieldAccrual
    {
        StateSetterLib.configure(configType, data);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function updateManagementFeeRecipient(address recipient) external nonReentrant afterDelay withYieldAccrual {
        require(msg.sender == Ownable(factory).owner(), InvalidFactoryOwner());

        StateSetterLib.updateManagementFeeRecipient(recipient);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function updatePerformanceFeeRecipient(address recipient) external nonReentrant afterDelay withYieldAccrual {
        require(msg.sender == Ownable(factory).owner(), InvalidFactoryOwner());

        StateSetterLib.updatePerformanceFeeRecipient(recipient);
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function setHooks(Hooks memory hooks)
        external
        virtual
        whenNotPaused
        nonReentrant
        afterDelay
        onlyRole(RolesLib.HOOK_MANAGER)
    {
        StateSetterLib.setHooks(hooks);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function getFeeConfig()
        external
        view
        override
        returns (
            uint16 currentManagementFee,
            address currentManagementFeeRecipient,
            uint32 currentLastManagementFeeAccrual,
            uint16 currentPerformanceFee,
            address currentPerformanceFeeRecipient
        )
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        return (
            $.managementFee,
            $.managementFeeRecipient,
            $.lastManagementFeeAccrual,
            $.performanceFee,
            $.performanceFeeRecipient
        );
    }

    function getHurdleRateOracle() external view returns (IHurdleRateOracle) {
        return SVLib.fetch().hurdleRateOracle;
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function getHooks() external view returns (Hooks memory) {
        return SVLib.fetch().hooks;
    }

    // ── Allocation (ALLOCATOR) ────────────────────────────────────────────────

    /// @inheritdoc IConcreteStandardVaultImpl
    function allocate(bytes calldata data)
        public
        virtual
        whenNotPaused
        nonReentrant
        onlyRole(RolesLib.ALLOCATOR)
        withYieldAccrual
    {
        // delegatecall allocate module
        allocateModule().functionDelegateCall(abi.encodeWithSelector(IAllocateModule.allocateFunds.selector, data));
        // Reject over-allocation: the allocated total must never exceed cachedTotalAssets, otherwise
        // donated funds could be pushed into a strategy and drift the derived floating accounting.
        // Checked without clamping so a desync reverts instead of being hidden.
        require(
            CachedVaultStateLib.fetch().cachedTotalAssets >= StandardVaultHelperLib.calcTotalAllocated(),
            InsufficientBalance()
        );
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function accrueYield() external virtual whenNotPaused nonReentrant onlyRole(RolesLib.ALLOCATOR) {
        _accrueYield();
    }

    /**
     * @notice Overwrites the deallocation order from strategies.
     */
    function setDeallocationOrder(address[] calldata order)
        external
        virtual
        whenNotPaused
        nonReentrant
        onlyRole(RolesLib.ALLOCATOR)
    {
        StateSetterLib.setDeallocationOrder(order);
    }

    /**
     * @notice Returns the deallocation order from strategies.
     */
    function getDeallocationOrder() external view returns (address[] memory order) {
        return SVLib.fetch().deallocationOrder;
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function allocateModule() public view returns (address) {
        return SVLib.fetch().allocateModule;
    }

    // ── Strategy management (STRATEGY_MANAGER) ────────────────────────────────

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function addStrategy(address strategy)
        public
        virtual
        whenNotPaused
        nonReentrant
        afterDelay
        onlyRole(RolesLib.STRATEGY_MANAGER)
    {
        StateSetterLib.addStrategy(strategy, asset());
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function removeStrategy(address strategy)
        public
        virtual
        whenNotPaused
        nonReentrant
        onlyRole(RolesLib.STRATEGY_MANAGER)
    {
        StateSetterLib.removeStrategy(strategy);
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function toggleStrategyStatus(address strategy)
        public
        virtual
        whenNotPaused
        nonReentrant
        onlyRole(RolesLib.STRATEGY_MANAGER)
    {
        StateSetterLib.toggleStrategyStatus(strategy);
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    /// @dev Intentionally callable while paused: this is an incident-response tool for broken
    ///      strategies, so it must remain usable while the vault is paused during an incident.
    function reconcileHaltedStrategy(address fromStrategy, address toStrategy)
        public
        virtual
        nonReentrant
        onlyRole(RolesLib.STRATEGY_MANAGER)
    {
        StateSetterLib.reconcileHaltedStrategy(fromStrategy, toStrategy);
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function getStrategyData(address strategy) public view returns (StrategyData memory) {
        return SVLib.fetch().strategyData[strategy];
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function getStrategies() public view returns (address[] memory) {
        return SVLib.fetch().strategies.values();
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function getTotalAllocated() public view returns (uint256) {
        return StandardVaultHelperLib.calcTotalAllocated();
    }

    // ── Limits & state ────────────────────────────────────────────────────────

    function getDepositLimits() public view returns (uint256, uint256) {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        return ($.maxGlobalDepositAmount, $.minTxDepositAmount);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function getWithdrawLimits() public view returns (uint256, uint256) {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        return ($.maxTxWithdrawAmount, $.minTxWithdrawAmount);
    }

    /**
     * @notice Returns the cached total assets accounted by the vault.
     *
     * @dev ACCOUNTING INVARIANT — DO NOT OVERRIDE. `AsyncVaultHelperLib` reads
     *      these raw storage slots directly to price async epochs, so any
     *      override must be mirrored there too or the price-per-share diverges:
     *
     *        - Do NOT override `cachedTotalAssets()` (kept non-`virtual` on purpose).
     *        - Do NOT override the inherited ERC20 `totalSupply()`.
     */
    function cachedTotalAssets() public view returns (uint256) {
        return CachedVaultStateLib.fetch().cachedTotalAssets;
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function sweepDonatedTokens(address token, address recipient)
        external
        nonReentrant
        onlyRole(RolesLib.VAULT_MANAGER)
    {
        WithdrawLib.sweepDonatedTokens(token, recipient, _lockedAssets());
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    /**
     * @notice Pauses the vault, preventing critical operations
     * @dev Only PAUSER role can pause the vault. Takes effect immediately.
     */
    function pause() external onlyRole(RolesLib.PAUSER) {
        _pause();
    }

    /**
     * @notice Unpauses the vault, allowing critical operations
     * @dev Only PAUSER role can unpause the vault, and only after the timelock delay once the
     *      vault's timelock is active.
     */
    function unpause() external onlyRole(RolesLib.PAUSER) afterDelay {
        _unpause();
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Validates and consumes the matured timelock schedule entry for the
    ///      calling function. No-op while timelock enforcement is not yet active.
    function _enforceDelay() internal {
        TimelockIntegrationLib.enforceDelay(msg.sig, msg.data[4:]);
    }

    function _accrueYield() internal virtual returns (uint256) {
        return YieldAccrualLib.accrueYield();
    }

    /**
     * @dev Initialization function that will be called when a proxy vault is deployed through `ConcreteFactory`.
     */
    function _initialize(
        uint64,
        /*initialVersion*/
        address,
        /*owner*/
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata defaultEnforcedVaultConfig,
        bytes memory data
    ) internal virtual override {
        (
            address allocateModuleAddr,
            address asset,
            address initialVaultManager,
            string memory name,
            string memory symbol
        ) = abi.decode(data, (address, address, address, string, string));

        require(allocateModuleAddr != address(0), InvalidAllocateModule());
        require(asset != address(0), InvalidAsset());
        require(initialVaultManager != address(0), InvalidInitialVaultManager());
        require(bytes(name).length > 0, InvalidName());
        require(bytes(symbol).length > 0, InvalidSymbol());

        __ERC20_init_unchained(name, symbol);
        __ERC4626_init_unchained(IERC20(asset));
        __AccessControlEnumerable_init_unchained();
        __Pausable_init_unchained();

        StateSetterLib.updateManagementFeeRecipient(defaultEnforcedVaultConfig.defaultManagementFeeRecipient);
        StateSetterLib.updatePerformanceFeeRecipient(defaultEnforcedVaultConfig.defaultPerformanceFeeRecipient);

        StateInitLib.stateInitStandardVaultImpl(allocateModuleAddr, initialVaultManager, msg.sender);
    }

    /**
     * @dev Upgrade function that will be called when a proxy vault upgrades to this implementation
     */
    function _upgrade(
        uint64, /* newVersion */
        bytes calldata data
    )
        internal
        virtual
        override
        whenNotPaused
    {
        StateInitLib.stateUpgradeStandardVaultImpl(data);
    }

    /**
     * @dev Internal function that handles withdrawal operations, including strategy deallocation when needed.
     * @dev This function implements the core withdrawal logic for the vault, automatically managing
     *      fund retrieval from both idle vault balance and allocated strategies to fulfill withdrawal requests.
     * @dev Withdrawal Process:
     *      1. First attempts to use idle funds (assets sitting in the vault contract)
     *      2. If idle funds are insufficient, iterates through active strategies to deallocate funds
     *      3. For each strategy, respects the strategy's maxWithdraw() limit
     *      4. Updates strategy allocation accounting after successful deallocations
     *      5. Executes the final withdrawal by burning shares, updating cached total assets, and transferring assets to the receiver
     * @dev Requirements:
     *      - Combined idle funds and strategy liquidity must be sufficient for withdrawal amount
     *      - All deallocated strategies must be in Active status
     *      - Strategy onWithdraw() calls must succeed and return expected amounts
     * @param caller The address that initiated the withdrawal (for access control)
     * @param receiver The address that will receive the withdrawn assets
     * @param owner The address whose shares are being burned for the withdrawal
     * @param assets The amount of assets to withdraw from the vault
     * @param shares The amount of shares to burn in exchange for the assets
     */
    function _executeWithdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        returns (uint256)
    {
        uint256 totalWithdrawableAmount = WithdrawLib.executeWithdrawFromStrategies(assets, _lockedAssets());

        if (totalWithdrawableAmount < assets) {
            revert IConcreteStandardVaultImpl.InsufficientWithdrawableAssets(assets, totalWithdrawableAmount);
        }

        _withdraw(caller, receiver, owner, assets, shares);

        return totalWithdrawableAmount;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        UserActionsLib.executeWithdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        UserActionsLib.executeDeposit(caller, receiver, assets, shares);
    }

    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20UpgradeableWithTransferHook, ERC20Upgradeable)
    {
        ERC20UpgradeableWithTransferHook._update(from, to, value);
    }

    /**
     * @dev Internal function used only by the public convertToShares() function.
     * @dev This function returns share amounts NOT inclusive of management or performance fees,
     *      as required by the ERC4626 specification. The convertToShares() function should return
     *      the theoretical share amount for a given asset amount without considering fee deductions.
     * @param assets The amount of assets to convert to shares
     * @param rounding The rounding direction for the conversion
     * @return The equivalent amount of shares, NOT inclusive of fees
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual override returns (uint256) {
        (uint256 totalPositiveYield, uint256 totalNegativeYield) = _previewYieldNoFees();
        return assets.calcConvertToShares(
            totalSupply(), cachedTotalAssets() + totalPositiveYield - totalNegativeYield, rounding, false
        );
    }

    /**
     * @dev Internal function used only by the public convertToAssets() function.
     * @dev This function returns asset amounts NOT inclusive of management or performance fees,
     *      as required by the ERC4626 specification. The convertToAssets() function should return
     *      the theoretical asset amount for a given share amount without considering fee deductions.
     * @param shares The amount of shares to convert to assets
     * @param rounding The rounding direction for the conversion
     * @return The equivalent amount of assets, NOT inclusive of fees
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual override returns (uint256) {
        (uint256 totalPositiveYield, uint256 totalNegativeYield) = _previewYieldNoFees();
        return shares.calcConvertToAssets(
            totalSupply(), cachedTotalAssets() + totalPositiveYield - totalNegativeYield, rounding, false
        );
    }

    /**
     * @dev Internal function to calculate the maximum amount of assets that can be withdrawn by an owner.
     * @dev The calculation considers:
     *      - Owner's current share balance converted to equivalent assets
     *      - Current vault liquidity (idle assets + withdrawable amounts from strategies)
     *      - Strategy withdrawal limitations and availability
     * @param owner The address of the account for which to calculate maximum withdrawal.
     * @return The maximum amount of assets that can actually be withdrawn by the owner,
     *         considering both ownership rights and liquidity constraints.
     * @return totalAssets The total amount of assets in the vault after previewing the yield accrual
     */
    function _maxWithdrawWithSimulation(address owner) internal view virtual returns (uint256, uint256, uint256) {
        (uint256 totalAssetsPreview, uint256 totalSupplyPreview) = _previewAccrueYieldAndFees();

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        uint256 maxAssets = StandardVaultHelperLib.calcMaxWithdraw(
            balanceOf(owner), $.maxTxWithdrawAmount, $.minTxWithdrawAmount, totalAssetsPreview, totalSupplyPreview
        );

        return (_simulateWithdraw(maxAssets), totalAssetsPreview, totalSupplyPreview);
    }

    /// @dev Simulate withdrawing an amount of assets from the vault.
    /// @param requestedAssets Amount of assets to withdraw.
    /// @return Amount of assets filled.
    function _simulateWithdraw(uint256 requestedAssets) internal view virtual returns (uint256) {
        return WithdrawLib.simulateWithdraw(requestedAssets, _lockedAssets());
    }

    /**
     * @dev Simulates the yield accrual operation across all strategies including fees.
     * @return totalAssets The projected total assets after yield accrual (current + yield - losses)
     * @return totalSupply The projected total supply after yield accrual (current + management fee shares + performance fee shares)
     */
    function _previewAccrueYieldAndFees() internal view virtual returns (uint256, uint256) {
        return YieldAccrualLib.previewAccrueYieldAndFees(cachedTotalAssets());
    }

    /**
     * @dev Calculates total positive and negative yield across all strategies.
     * @return totalPositiveYield The sum of all positive yields from strategies
     * @return totalNegativeYield The sum of all losses from strategies
     */
    function _previewYieldNoFees()
        internal
        view
        virtual
        returns (uint256 totalPositiveYield, uint256 totalNegativeYield)
    {
        return YieldAccrualLib.previewYieldNoFees();
    }

    function _lockedAssets() internal view virtual returns (uint256) {
        return 0;
    }
}
