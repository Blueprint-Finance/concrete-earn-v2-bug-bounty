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
    Math,
    SafeERC20
} from "@openzeppelin-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {Address} from "@openzeppelin-contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {IContractId} from "../interface/IContractId.sol";
import {IUpgradeableVault} from "../interface/IUpgradeableVault.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
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
import {Hooks, HooksLibV1 as HooksLib} from "../lib/Hooks.sol";
import {ConcreteV2RolesLib as RolesLib} from "../lib/Roles.sol";
import {StateInitLib} from "../lib/StateInitLib.sol";
import {StateSetterLib} from "../lib/StateSetterLib.sol";
import {ContractIdEncoding} from "../lib/ContractIdEncoding.sol";
import {WithdrawLib} from "../lib/WithdrawLib.sol";
import {YieldAccrualLib} from "../lib/YieldAccrualLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Storage layout libraries
// ─────────────────────────────────────────────────────────────────────────────
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "../lib/storage/ConcreteCachedVaultStateStorageLib.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "../lib/storage/ConcreteStandardVaultImplStorageLib.sol";
import {RoleMigrationLib} from "../lib/RoleMigrationLib.sol";

contract ConcreteStandardVaultImpl is
    IContractId,
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

    event HooksSet(Hooks hooks);

    function ID() public pure virtual override(IContractId, UpgradeableVault) returns (uint64) {
        // contractType=0 (vault), flavour=1 (standard vault), version=1.0.0 (major=1, minor=0, patch=0)
        return uint64(110200); //ContractIdEncoding.encode(0, 1, 1, 02, 00);
    }

    /// @dev Modifier to accrue yield before function execution
    modifier withYieldAccrual() {
        _accrueYield();
        _;
    }
    /**
     * @dev Constructor
     * @param factory The address of the factory
     */

    constructor(address factory) UpgradeableVault(factory) {}

    /// @inheritdoc IConcreteStandardVaultImpl
    function allocate(bytes calldata data)
        public
        virtual
        whenNotPaused
        nonReentrant
        onlyRole(RolesLib.ALLOCATOR)
        withYieldAccrual
        whenNotPaused
    {
        // delegatecall allocate module
        allocateModule().functionDelegateCall(abi.encodeWithSelector(IAllocateModule.allocateFunds.selector, data));
        require(IERC20(asset()).balanceOf(address(this)) >= _lockedAssets(), InsufficientBalance());
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function accrueYield() external virtual whenNotPaused nonReentrant onlyRole(RolesLib.ALLOCATOR) {
        _accrueYield();
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function updateManagementFee(uint16 managementFee_)
        external
        nonReentrant
        onlyRole(RolesLib.VAULT_MANAGER)
        withYieldAccrual
    {
        StateSetterLib.updateManagementFee(managementFee_);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function updateManagementFeeRecipient(address recipient) external nonReentrant withYieldAccrual {
        require(msg.sender == Ownable(factory).owner(), InvalidFactoryOwner());

        StateSetterLib.updateManagementFeeRecipient(recipient);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function updatePerformanceFee(uint16 performanceFee_)
        external
        nonReentrant
        onlyRole(RolesLib.VAULT_MANAGER)
        withYieldAccrual
    {
        StateSetterLib.updatePerformanceFee(performanceFee_);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function updatePerformanceFeeRecipient(address recipient) external nonReentrant withYieldAccrual {
        require(msg.sender == Ownable(factory).owner(), InvalidFactoryOwner());

        StateSetterLib.updatePerformanceFeeRecipient(recipient);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function setHurdleRateOracle(IHurdleRateOracle oracle) external onlyRole(RolesLib.VAULT_MANAGER) withYieldAccrual {
        SVLib.fetch().hurdleRateOracle = oracle;
        emit HurdleRateOracleUpdated(address(oracle));
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function getHurdleRateOracle() external view returns (IHurdleRateOracle) {
        return SVLib.fetch().hurdleRateOracle;
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function setDepositLimits(uint256 minTxDepositAmount, uint256 maxGlobalDepositAmount)
        external
        onlyRole(RolesLib.VAULT_MANAGER)
    {
        StateSetterLib.setDepositLimits(minTxDepositAmount, maxGlobalDepositAmount);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function setWithdrawLimits(uint256 minTxWithdrawAmount, uint256 maxTxWithdrawAmount)
        external
        onlyRole(RolesLib.VAULT_MANAGER)
    {
        StateSetterLib.setWithdrawLimits(minTxWithdrawAmount, maxTxWithdrawAmount);
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
        require(receiver != address(0), InvalidReceiver());

        Hooks memory h = SVLib.fetch().hooks;
        uint256 totalAssetsBeforeDeposit = cachedTotalAssets();
        // invoke pre-deposit hook if enabled
        if (h.checkIsValid(HooksLib.PRE_DEPOSIT)) {
            h.preDeposit(msg.sender, assets, receiver, totalAssetsBeforeDeposit);
        }

        // Verify deposit limits using cachedTotalAssets (after yield accrual)

        uint256 maxAssets = _maxDeposit(receiver, totalAssetsBeforeDeposit);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = assets.calcConvertToShares(totalSupply(), totalAssetsBeforeDeposit, Math.Rounding.Floor, true);

        _deposit(msg.sender, receiver, assets, shares);

        // invoke post-deposit hook if enabled
        if (h.checkIsValid(HooksLib.POST_DEPOSIT)) {
            h.postDeposit(msg.sender, assets, shares, receiver, cachedTotalAssets());
        }

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
        require(receiver != address(0), InvalidReceiver());

        Hooks memory h = SVLib.fetch().hooks;
        uint256 totalAssetsBeforeDeposit = cachedTotalAssets();
        // invoke pre-mint hook if enabled
        if (h.checkIsValid(HooksLib.PRE_MINT)) {
            h.preMint(msg.sender, shares, receiver, totalAssetsBeforeDeposit);
        }
        uint256 totalSupply_ = totalSupply();

        uint256 maxShares = _maxMint(receiver, totalAssetsBeforeDeposit, totalSupply_);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = shares.calcConvertToAssets(totalSupply_, totalAssetsBeforeDeposit, Math.Rounding.Ceil, true);

        _deposit(msg.sender, receiver, assets, shares);

        // invoke post-mint hook if enabled
        if (h.checkIsValid(HooksLib.POST_MINT)) {
            h.postMint(msg.sender, assets, shares, receiver, cachedTotalAssets());
        }

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
        require(receiver != address(0), InvalidReceiver());

        Hooks memory h = SVLib.fetch().hooks;
        uint256 totalAssetsBeforeWithdrawal = cachedTotalAssets();

        if (h.checkIsValid(HooksLib.PRE_WITHDRAW)) {
            h.preWithdraw(msg.sender, assets, receiver, owner, totalAssetsBeforeWithdrawal);
        }
        // Optimistic maxAssets that does not account for the withdrawals from strategies, this is to avoid the need to call _simulateWithdraw().
        // If maxAssets is greater than the actual withdrawable amount, _executeWithdraw() will revert.
        uint256 totalSupply_ = totalSupply();
        uint256 maxAssets = _maxWithdraw(owner, totalAssetsBeforeWithdrawal, totalSupply_);

        uint256 shares = assets.calcConvertToShares(totalSupply_, totalAssetsBeforeWithdrawal, Math.Rounding.Ceil, true);
        if (assets > maxAssets || _executeWithdraw(msg.sender, receiver, owner, assets, shares) < assets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 minWithdrawAmount = SVLib.fetch().minTxWithdrawAmount;
        require(assets >= minWithdrawAmount, MinimumWithdrawAmountNotMet(msg.sender, assets, minWithdrawAmount));
        // invoke post-withdraw hook if enabled
        if (h.checkIsValid(HooksLib.POST_WITHDRAW)) {
            h.postWithdraw(msg.sender, assets, shares, receiver, cachedTotalAssets());
        }

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
        require(receiver != address(0), InvalidReceiver());

        Hooks memory h = SVLib.fetch().hooks;
        uint256 totalAssetsBeforeWithdrawal = cachedTotalAssets();

        // invoke pre-redeem hook if enabled
        if (h.checkIsValid(HooksLib.PRE_REDEEM)) {
            h.preRedeem(msg.sender, shares, receiver, owner, totalAssetsBeforeWithdrawal);
        }
        uint256 totalSupply_ = totalSupply();

        // Optimistic maxShares that does not account for the withdrawals from strategies, this is to avoid the need to call _simulateWithdraw().
        // If maxShares is greater than the actual redeemable amount, _executeWithdraw() will revert.
        uint256 maxShares = _maxRedeem(owner, totalAssetsBeforeWithdrawal, totalSupply_);
        uint256 assets =
            shares.calcConvertToAssets(totalSupply_, totalAssetsBeforeWithdrawal, Math.Rounding.Floor, true);

        if (shares > maxShares || _executeWithdraw(msg.sender, receiver, owner, assets, shares) < assets) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 minWithdrawAmount = SVLib.fetch().minTxWithdrawAmount;
        require(assets >= minWithdrawAmount, MinimumWithdrawAmountNotMet(msg.sender, assets, minWithdrawAmount));

        // invoke post-redeem hook if enabled
        if (h.checkIsValid(HooksLib.POST_REDEEM)) {
            h.postRedeem(msg.sender, assets, shares, receiver, cachedTotalAssets());
        }

        return assets;
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function setHooks(Hooks memory hooks) external virtual whenNotPaused nonReentrant onlyRole(RolesLib.HOOK_MANAGER) {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        $.hooks = hooks;

        emit HooksSet(hooks);
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function getHooks() external view returns (Hooks memory) {
        return SVLib.fetch().hooks;
    }

    /**
     * @notice overwrites the deallocation order from strategies;
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
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function addStrategy(address strategy)
        public
        virtual
        whenNotPaused
        nonReentrant
        onlyRole(RolesLib.STRATEGY_MANAGER)
    {
        require(IStrategyTemplate(strategy).asset() == asset(), InvalidStrategyAsset());
        require(IStrategyTemplate(strategy).getVault() == address(this), InvalidStrategyVault());
        StateSetterLib.addStrategy(strategy);
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
     * @notice Returns the deallocation order from strategies.
     */
    function getDeallocationOrder() external view returns (address[] memory order) {
        return SVLib.fetch().deallocationOrder;
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
        (uint256 totalAssetsPreview, uint256 totalSupply) = _previewAccrueYieldAndFees();
        return assets.calcConvertToShares(totalSupply, totalAssetsPreview, Math.Rounding.Floor, false);
    }

    /**
     * @inheritdoc IERC4626
     */
    function previewMint(uint256 shares) public view virtual override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        (uint256 totalAssetsPreview, uint256 totalSupply) = _previewAccrueYieldAndFees();

        return shares.calcConvertToAssets(totalSupply, totalAssetsPreview, Math.Rounding.Ceil, false);
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
        (uint256 totalAssetsPreview, uint256 totalSupply) = _previewAccrueYieldAndFees();

        return assets.calcConvertToShares(totalSupply, totalAssetsPreview, Math.Rounding.Ceil, false);
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
        (uint256 totalAssetsPreview, uint256 totalSupply) = _previewAccrueYieldAndFees();

        return shares.calcConvertToAssets(totalSupply, totalAssetsPreview, Math.Rounding.Floor, false);
    }

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function previewAccrueYield() public view virtual returns (uint256, uint256) {
        return _previewAccrueYieldAndFees();
    }

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
        (uint256 totalAssetsPreview,) = _previewAccrueYieldAndFees();
        return _maxDeposit(receiver, totalAssetsPreview);
    }

    function maxMint(address receiver) public view virtual override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        (uint256 totalAssetsPreview, uint256 totalSupplyPreview) = _previewAccrueYieldAndFees();
        return _maxMint(receiver, totalAssetsPreview, totalSupplyPreview);
    }

    function _maxMint(address, uint256 totalAssets_, uint256 totalSupply_) internal view virtual returns (uint256) {
        return StandardVaultHelperLib.calcMaxMint(
            SVLib.fetch().maxGlobalDepositAmount, SVLib.fetch().minTxDepositAmount, totalAssets_, totalSupply_
        );
    }

    function _maxDeposit(address, uint256 totalAssets_) internal view virtual returns (uint256) {
        return StandardVaultHelperLib.calcMaxDeposit(
            SVLib.fetch().maxGlobalDepositAmount, SVLib.fetch().minTxDepositAmount, totalAssets_
        );
    }

    /**
     * @inheritdoc IERC4626
     */
    function maxRedeem(address owner) public view virtual override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        (uint256 expectedTotalAssets, uint256 expectedTotalSupply) = _previewAccrueYieldAndFees();

        // Get max shares using the same logic as redeem() - uses corrected calcMaxRedeem (avoids double rounding)
        uint256 maxShares = _maxRedeem(owner, expectedTotalAssets, expectedTotalSupply);

        // Get available liquidity (idle + withdrawable from strategies)
        // This matches the test expectation: convertToShares(min(userAssets, availableLiquidity))
        uint256 availableLiquidity = _simulateWithdraw(type(uint256).max);

        // Convert available liquidity to shares
        uint256 availableShares = availableLiquidity.calcConvertToShares(
            expectedTotalSupply, expectedTotalAssets, Math.Rounding.Floor, false
        );

        // Return the minimum to ensure maxRedeem never reports more than what redeem() would accept
        // This prevents inconsistency where maxRedeem reports more shares than redeem accepts
        return availableShares > maxShares ? maxShares : availableShares;
    }

    function _maxRedeem(address owner, uint256 totalAssets_, uint256 totalSupply_)
        internal
        view
        virtual
        returns (uint256)
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        return StandardVaultHelperLib.calcMaxRedeem(
            balanceOf(owner), $.maxTxWithdrawAmount, $.minTxWithdrawAmount, totalAssets_, totalSupply_
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
        (maxAssets,,) = _maxWithdrawWithSimulation(owner);
    }

    function _maxWithdraw(address owner, uint256 totalAssets_, uint256 totalSupply_)
        internal
        view
        virtual
        returns (uint256)
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        return StandardVaultHelperLib.calcMaxWithdraw(
            balanceOf(owner), $.maxTxWithdrawAmount, $.minTxWithdrawAmount, totalAssets_, totalSupply_
        );
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

    /**
     * @inheritdoc IConcreteStandardVaultImpl
     */
    function allocateModule() public view returns (address) {
        return SVLib.fetch().allocateModule;
    }

    function getDepositLimits() public view returns (uint256, uint256) {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        return ($.maxGlobalDepositAmount, $.minTxDepositAmount);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function getWithdrawLimits() public view returns (uint256, uint256) {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        return ($.maxTxWithdrawAmount, $.minTxWithdrawAmount);
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function getTotalAllocated() public view returns (uint256) {
        return StandardVaultHelperLib.calcTotalAllocated();
    }

    function cachedTotalAssets() public view returns (uint256) {
        return CachedVaultStateLib.fetch().cachedTotalAssets;
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
        uint64,
        /* newVersion */
        bytes calldata /* data */
    )
        internal
        virtual
        override
        whenNotPaused
    {
        // Migrate legacy admin roles to ROLE_ADMIN
        RoleMigrationLib.migrateLegacyAdminRoles(msg.sender);
    }

    /**
     * @notice Pauses the vault, preventing critical operations
     * @dev Only PAUSER role can pause the vault
     */
    function pause() external onlyRole(RolesLib.PAUSER) {
        _pause();
    }

    /**
     * @notice Unpauses the vault, allowing critical operations
     * @dev Only PAUSER role can unpause the vault
     */
    function unpause() external onlyRole(RolesLib.PAUSER) {
        _unpause();
    }

    /**
     * @dev Internal function that executes the yield accrual operation across all active strategies.
     */
    function _accrueYield() internal virtual returns (uint256) {
        return YieldAccrualLib.accrueYield();
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
        uint256 totalWithdrawableAmount = WithdrawLib.executeWithdrawFromStrategies(asset(), assets, _lockedAssets());

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
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.

        CachedVaultStateLib.fetch().cachedTotalAssets -= assets;
        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        uint256 minDepositAmount = SVLib.fetch().minTxDepositAmount;
        require(assets >= minDepositAmount, MinimumDepositAmountNotMet(msg.sender, assets, minDepositAmount));

        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        CachedVaultStateLib.fetch().cachedTotalAssets += assets;
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
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

        uint256 maxAssets = _maxWithdraw(owner, totalAssetsPreview, totalSupplyPreview);

        return (_simulateWithdraw(maxAssets), totalAssetsPreview, totalSupplyPreview);
    }

    /// @dev Simulate withdrawing an amount of assets from the vault.
    /// @param requestedAssets Amount of assets to withdraw.
    /// @return Amount of assets filled.
    function _simulateWithdraw(uint256 requestedAssets) internal view virtual returns (uint256) {
        return WithdrawLib.simulateWithdraw(asset(), requestedAssets, _lockedAssets());
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

    function _lockedAssets() internal view virtual returns (uint256) {
        return 0;
    }
}
