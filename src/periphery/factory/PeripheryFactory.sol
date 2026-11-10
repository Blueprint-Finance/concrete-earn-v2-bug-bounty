// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title PeripheryFactory
 * @notice Factory for deploying and managing periphery contracts:
 *         (1) Strategy proxies (TransparentUpgradeableProxy) keyed by their `ID()`.
 *             The factory owns each strategy's ProxyAdmin, enabling permissioned upgrades
 *             via `upgradeStrategy` / `batchUpgradeStrategies`.
 *         (2) Position-management-helper (PMH) clones (ClonesWithImmutableArgs) keyed by their `ID()`.
 *         (3) Hook clones (ERC-1167 minimal proxies) keyed by their `ID()`.
 *
 *         Upgradeability: UUPS, owner-controlled.
 *         No legacy version support — implementations are always registered by their own `ID()`.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:oz-upgrades Uses UUPS + EIP-7201 storage layout
 */

// ─────────────────────────────────────────────────────────────────────────────
// External dependencies
// ─────────────────────────────────────────────────────────────────────────────
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin-contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal – shared abstractions
// ─────────────────────────────────────────────────────────────────────────────
import {IContractId} from "../../interface/IContractId.sol";
import {ITimelockProtected} from "../../interface/ITimelockProtected.sol";
import {ContractIdPrimitive} from "../../common/ContractIdPrimitive.sol";
import {PeripheryRolesLib} from "../lib/PeripheryRolesLib.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {PeripheryFactoryStorageLib as PFSLib} from "../lib/PeripheryFactoryStorageLib.sol";
import {TimelockIntegrationLib} from "../../lib/TimelockIntegrationLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// PeripheryFactory
// ─────────────────────────────────────────────────────────────────────────────

contract PeripheryFactory is
    ITimelockProtected,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ContractIdPrimitive
{
    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroImplId();
    error ImplAlreadyApproved();
    error ImplNotFound();
    error ImplBlocked();
    error AlreadyBlocked();
    error NotRegistered();
    error AlreadyRegistered();
    /// @notice Thrown when unblocking an implementation that is not currently blocked.
    error NotBlocked();
    /// @notice Thrown when unsetting a migration path that is not currently open.
    error NotMigratable();
    error SameImpl();
    error CanNotMigrate();
    error InvalidDataLength();
    error NoProxyAdmin();
    error NotStrategyUpgrader();
    error Unauthorized();
    error InvalidProxyAdmin();
    error InvalidInitData();
    /// @notice Thrown when renounceOwnership is called — permanently disabled.
    error RenounceOwnershipDisabled();
    /// @notice Thrown when a FACTORY_MANAGER-gated function is called by a non-manager.
    error NotFactoryManager();

    // ── Modifiers ─────────────────────────────────────────────────────────────

    /// @dev Applied to privileged functions that require a prior {ITimelock.propose}
    ///      followed by the matured tier delay before they can execute.
    modifier afterDelay() {
        TimelockIntegrationLib.enforceDelay(msg.sig, msg.data[4:]);
        _;
    }

    /// @dev Restricts a function to the FACTORY_MANAGER role. The manager is assigned by the
    ///      owner via {setFactoryManager} and handles frequent operational functions, kept
    ///      strictly separate from the owner's high-privilege functions.
    modifier onlyFactoryManager() {
        if (msg.sender != PFSLib.fetch().factoryManager) revert NotFactoryManager();
        _;
    }

    // ── Events ────────────────────────────────────────────────────────────────

    event StrategyImplApproved(uint64 indexed implId, address indexed implementation);
    event StrategyImplBlocked(uint64 indexed implId);
    event StrategyImplUnblocked(uint64 indexed implId);
    event StrategyMigratableSet(uint64 indexed fromImplId, uint64 indexed toImplId);
    event StrategyMigratableUnset(uint64 indexed fromImplId, uint64 indexed toImplId);
    event StrategyDeployed(address indexed proxy, uint64 indexed implId, address indexed proxyAdmin);
    event StrategyRegistered(address indexed proxy, address indexed proxyAdmin);
    event StrategyUpgraded(address indexed proxy, uint64 indexed newImplId);
    event StrategyDeregistered(address indexed proxy, address indexed newProxyAdminOwner);

    event PMHImplApproved(uint64 indexed implId, address indexed implementation);
    event PMHImplBlocked(uint64 indexed implId);
    event PMHImplUnblocked(uint64 indexed implId);
    event PMHCloned(address indexed clone, uint64 indexed implId, address indexed positionOwner);

    /// @notice Emitted when the factory manager is set.
    event FactoryManagerSet(address indexed previousManager, address indexed newManager);

    /// @notice Emitted when an upgrade of the factory itself is authorized.
    /// @dev Emitted in addition to OpenZeppelin's {IERC1967.Upgraded} so that monitoring can
    ///      attribute the upgrade to the queued timelock proposal that authorized it.
    event FactoryUpgradeAuthorized(address indexed newImplementation, address indexed authorizedBy);
    event HookImplApproved(uint64 indexed implId, address indexed implementation);
    event HookImplBlocked(uint64 indexed implId);
    event HookImplUnblocked(uint64 indexed implId);
    event HookCloned(address indexed clone, uint64 indexed implId);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    // ── Initializer ───────────────────────────────────────────────────────────

    /// @param owner_    The address of the owner. Also assigned the FACTORY_MANAGER role at
    ///                  deployment; the owner can later delegate it to a separate address via
    ///                  {setFactoryManager}.
    /// @param timelock_ Address of the Timelock contract. Pass `address(0)` to
    ///                  deploy without timelock enforcement (timelock can be
    ///                  configured later once the Timelock is activated).
    function initialize(address owner_, address timelock_) external initializer {
        __Ownable_init_unchained(owner_);
        __UUPSUpgradeable_init_unchained();
        __Pausable_init_unchained();
        PFSLib.fetch().factoryManager = owner_;
        emit FactoryManagerSet(address(0), owner_);
        if (timelock_ != address(0)) TimelockIntegrationLib.setTimelock(timelock_);
    }

    // =========================================================================
    // STRATEGY — implementation registry
    // =========================================================================

    /// @notice Approve a strategy implementation. The implementation's `ID()` is used as the key.
    /// @param implementation Address of the deployed strategy implementation.
    function approveStrategyImpl(address implementation) external onlyFactoryManager afterDelay {
        if (implementation == address(0)) revert ZeroAddress();
        uint64 implId = IContractId(implementation).ID();
        if (implId == 0) revert ZeroImplId();
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.strategyImpls[implId] != address(0)) revert ImplAlreadyApproved();
        $.strategyImpls[implId] = implementation;
        emit StrategyImplApproved(implId, implementation);
    }

    /// @notice Block a strategy implementation by ID so it can no longer be deployed or migrated to.
    function blockStrategyImpl(uint64 implId) external onlyFactoryManager {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.strategyImpls[implId] == address(0)) revert ImplNotFound();
        if ($.strategyBlocked[implId]) revert AlreadyBlocked();
        $.strategyBlocked[implId] = true;
        emit StrategyImplBlocked(implId);
    }

    /// @notice Unblock a previously-blocked strategy implementation.
    /// @dev Owner-only and timelock-gated (Tier 2): unblocking re-enables deployment/migration, so it
    ///      carries the same weight as approving an implementation.
    function unblockStrategyImpl(uint64 implId) external onlyOwner afterDelay {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.strategyImpls[implId] == address(0)) revert ImplNotFound();
        if (!$.strategyBlocked[implId]) revert NotBlocked();
        $.strategyBlocked[implId] = false;
        emit StrategyImplUnblocked(implId);
    }

    /// @notice Allow a strategy to be upgraded from `fromImplId` to `toImplId`.
    /// @dev `fromImplId` must differ from `toImplId`. Both must be approved.
    function setStrategyMigratable(uint64 fromImplId, uint64 toImplId) external onlyFactoryManager afterDelay {
        if (fromImplId == toImplId) revert SameImpl();
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.strategyImpls[fromImplId] == address(0)) revert ImplNotFound();
        if ($.strategyImpls[toImplId] == address(0)) revert ImplNotFound();
        $.strategyMigratable[fromImplId][toImplId] = true;
        emit StrategyMigratableSet(fromImplId, toImplId);
    }

    /// @notice Close a previously-opened strategy migration path.
    /// @dev Factory-manager-only and NOT timelocked: closing a wrongly-opened path is a restrictive
    ///      correction, so it can be applied promptly without a queued proposal.
    function unsetStrategyMigratable(uint64 fromImplId, uint64 toImplId) external onlyFactoryManager {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if (!$.strategyMigratable[fromImplId][toImplId]) revert NotMigratable();
        $.strategyMigratable[fromImplId][toImplId] = false;
        emit StrategyMigratableUnset(fromImplId, toImplId);
    }

    // =========================================================================
    // STRATEGY — deployment & registration
    // =========================================================================

    /// @notice Deploy a strategy as a TransparentUpgradeableProxy.
    ///
    /// @dev The factory is passed as `initialOwner` of the ProxyAdmin, which means
    ///      the factory holds exclusive upgrade authority over the deployed proxy.
    ///      The ProxyAdmin address is deterministically computed from the proxy's
    ///      address (CREATE1 with nonce = 1) and stored for later use by `upgradeStrategy`
    ///      and `deregisterStrategy`.
    ///
    /// @param implId    The registered strategy implementation ID.
    /// @param initData  ABI-encoded `initialize(...)` call forwarded to the implementation.
    /// @return proxy    Address of the deployed strategy proxy.
    function deployStrategy(uint64 implId, bytes calldata initData) external whenNotPaused returns (address proxy) {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        address impl = $.strategyImpls[implId];
        if (impl == address(0)) revert ImplNotFound();
        if ($.strategyBlocked[implId]) revert ImplBlocked();

        if (initData.length == 0) revert InvalidInitData();

        // Deploy proxy with this factory as ProxyAdmin owner.
        proxy = address(new TransparentUpgradeableProxy(impl, address(this), initData));

        // TransparentUpgradeableProxy deploys ProxyAdmin as its first CREATE (nonce = 1).
        // Compute the deterministic address using RLP-encoded CREATE1 formula.
        address proxyAdmin = _computeProxyAdmin(proxy);

        $.strategies[proxy] = PFSLib.StrategyData({registered: true, proxyAdmin: proxyAdmin});

        emit StrategyDeployed(proxy, implId, proxyAdmin);
    }

    /// @notice Register a strategy proxy that was not deployed by this factory.
    ///
    /// @dev Use this to bring externally-deployed TransparentUpgradeableProxy strategies
    ///      under factory management.  Pass `address(0)` for `proxyAdmin` if the strategy
    ///      is non-upgradeable or upgrade management is not needed.
    ///
    /// @dev WARNING: If `proxyAdmin` is non-zero, the factory must already be the owner of
    ///      that ProxyAdmin before calling this function.  If ownership has not been
    ///      transferred, `upgradeStrategy` and `deregisterStrategy` (ProxyAdmin transfer)
    ///      will revert because `ProxyAdmin.upgradeAndCall` / `ProxyAdmin.transferOwnership`
    ///      are guarded by `onlyOwner`.  Transfer ownership with:
    ///          `ProxyAdmin(proxyAdmin).transferOwnership(address(factory))`
    ///      before registering, or pass `address(0)` and update via a subsequent
    ///      `registerStrategy` call once ownership has been accepted.
    ///
    /// @param proxy      Address of the existing strategy proxy.
    /// @param proxyAdmin Address of the ProxyAdmin that controls `proxy`, or address(0).
    function registerStrategy(address proxy, address proxyAdmin) external onlyFactoryManager {
        if (proxy == address(0)) revert ZeroAddress();
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.strategies[proxy].registered) revert AlreadyRegistered();
        $.strategies[proxy] = PFSLib.StrategyData({registered: true, proxyAdmin: proxyAdmin});
        emit StrategyRegistered(proxy, proxyAdmin);
    }

    /// @notice Upgrade a factory-registered strategy proxy to a new implementation.
    ///
    /// @dev Caller must hold `STRATEGY_ADMIN` or `STRATEGY_UPGRADER` on the strategy proxy.
    ///
    /// @param proxy       Address of the registered strategy proxy.
    /// @param newImplId   Target implementation ID (must be approved, unblocked, and migration-allowed).
    /// @param data        Calldata forwarded to `upgradeAndCall` (e.g. a reinitializer call).
    function upgradeStrategy(address proxy, uint64 newImplId, bytes calldata data) external whenNotPaused {
        _upgradeStrategy(proxy, newImplId, data);
    }

    /// @notice Batch-upgrade multiple strategies to the same new implementation.
    /// @dev Caller must hold `STRATEGY_ADMIN` or `STRATEGY_UPGRADER` on each strategy proxy.
    function batchUpgradeStrategies(address[] calldata proxies, uint64 newImplId, bytes[] calldata data)
        external
        whenNotPaused
    {
        if (proxies.length != data.length) revert InvalidDataLength();
        for (uint256 i = 0; i < proxies.length; ++i) {
            _upgradeStrategy(proxies[i], newImplId, data[i]);
        }
    }

    /// @notice Deregister a strategy and transfer its ProxyAdmin ownership to `newOwner`.
    ///
    /// @dev After this call the strategy is no longer managed by the factory.
    ///      If no ProxyAdmin was recorded (non-upgradeable strategy), the ownership
    ///      transfer is skipped.
    ///
    ///      Callable by the factory owner OR any account holding `STRATEGY_ADMIN` on
    ///      the proxy, giving strategy administrators the ability to reclaim their own
    ///      ProxyAdmin without requiring factory-owner intervention.
    ///
    /// @param proxy    Address of the registered strategy proxy.
    /// @param newOwner Address that will receive ownership of the ProxyAdmin.
    function deregisterStrategy(address proxy, address newOwner) external {
        if (newOwner == address(0)) revert ZeroAddress();
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if (!$.strategies[proxy].registered) revert NotRegistered();

        if (msg.sender != owner() && !IAccessControl(proxy).hasRole(PeripheryRolesLib.STRATEGY_ADMIN, msg.sender)) {
            revert Unauthorized();
        }

        address proxyAdmin = $.strategies[proxy].proxyAdmin;
        delete $.strategies[proxy];

        if (proxyAdmin != address(0)) ProxyAdmin(proxyAdmin).transferOwnership(newOwner);

        emit StrategyDeregistered(proxy, newOwner);
    }

    // ── Strategy views ────────────────────────────────────────────────────────

    function getStrategyImpl(uint64 implId) external view returns (address) {
        return PFSLib.fetch().strategyImpls[implId];
    }

    function isStrategyImplBlocked(uint64 implId) external view returns (bool) {
        return PFSLib.fetch().strategyBlocked[implId];
    }

    function isStrategyMigratable(uint64 fromImplId, uint64 toImplId) external view returns (bool) {
        return PFSLib.fetch().strategyMigratable[fromImplId][toImplId];
    }

    function isRegisteredStrategy(address proxy) external view returns (bool) {
        return PFSLib.fetch().strategies[proxy].registered;
    }

    function getStrategyProxyAdmin(address proxy) external view returns (address) {
        return PFSLib.fetch().strategies[proxy].proxyAdmin;
    }

    // =========================================================================
    // PMH CLONE — registration
    // =========================================================================

    /// @notice Approve a position-management-helper implementation. The implementation's `ID()` is used as the key.
    /// @param implementation Address of the deployed PMH implementation (e.g. PositionHelperAaveV3).
    function approvePMHImpl(address implementation) external onlyFactoryManager afterDelay {
        if (implementation == address(0)) revert ZeroAddress();
        uint64 implId = IContractId(implementation).ID();
        if (implId == 0) revert ZeroImplId();
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.pmhImpls[implId] != address(0)) revert ImplAlreadyApproved();
        $.pmhImpls[implId] = implementation;
        emit PMHImplApproved(implId, implementation);
    }

    /// @notice Block a PMH implementation by ID so it can no longer be cloned.
    function blockPMHImpl(uint64 implId) external onlyFactoryManager {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.pmhImpls[implId] == address(0)) revert ImplNotFound();
        if ($.pmhBlocked[implId]) revert AlreadyBlocked();
        $.pmhBlocked[implId] = true;
        emit PMHImplBlocked(implId);
    }

    /// @notice Unblock a previously-blocked PMH implementation.
    /// @dev Owner-only and timelock-gated (Tier 2): unblocking re-enables cloning, so it
    ///      carries the same weight as approving an implementation.
    function unblockPMHImpl(uint64 implId) external onlyOwner afterDelay {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.pmhImpls[implId] == address(0)) revert ImplNotFound();
        if (!$.pmhBlocked[implId]) revert NotBlocked();
        $.pmhBlocked[implId] = false;
        emit PMHImplUnblocked(implId);
    }

    // =========================================================================
    // PMH CLONE — deployment
    // =========================================================================

    /// @notice Clone a registered PMH implementation with the standard 62-byte immutable arg encoding.
    ///
    /// @dev Immutable arg encoding (62 bytes):
    ///      [positionOwner (20)][collateralToken (20)][borrowToken (20)]
    ///      [collateralDecimals (1)][borrowDecimals (1)]
    ///      Decimals are read on-chain from the tokens via IERC20Metadata.
    ///
    /// @param implId          Registered PMH implementation ID.
    /// @param positionOwner   Account on whose behalf the helper operates.
    /// @param collateralToken ERC-20 collateral token address.
    /// @param borrowToken     ERC-20 borrow token address.
    /// @param initData        ABI-encoded calldata forwarded to `clone.initialize(...)`.
    /// @return clone_         Address of the deployed clone.
    function clonePMH(
        uint64 implId,
        address positionOwner,
        address collateralToken,
        address borrowToken,
        bytes calldata initData
    ) external whenNotPaused returns (address clone_) {
        if (positionOwner == address(0)) revert ZeroAddress();
        if (collateralToken == address(0)) revert ZeroAddress();
        if (borrowToken == address(0)) revert ZeroAddress();

        PFSLib.PFStorage storage $ = PFSLib.fetch();
        address impl = $.pmhImpls[implId];
        if (impl == address(0)) revert ImplNotFound();
        if ($.pmhBlocked[implId]) revert ImplBlocked();

        clone_ =
            ClonesWithImmutableArgs.clone(impl, _getImmutableArgs(positionOwner, collateralToken, borrowToken, impl));
        $.pmhClones[clone_] = true;

        if (initData.length == 0) revert InvalidInitData();

        (bool success, bytes memory returnData) = clone_.call(initData);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        emit PMHCloned(clone_, implId, positionOwner);
    }

    // ── PMH views ─────────────────────────────────────────────────────────────

    function getPMHImpl(uint64 implId) external view returns (address) {
        return PFSLib.fetch().pmhImpls[implId];
    }

    function isPMHImplBlocked(uint64 implId) external view returns (bool) {
        return PFSLib.fetch().pmhBlocked[implId];
    }

    function isRegisteredPMHClone(address clone_) external view returns (bool) {
        return PFSLib.fetch().pmhClones[clone_];
    }

    // =========================================================================
    // HOOK CLONE — registration
    // =========================================================================

    /// @notice Approve a hook implementation. The implementation's `ID()` is used as the key.
    /// @dev Hooks (e.g. HookContainer, UserDepositCapHook, DepositLockHook) are deployed as
    ///      ERC-1167 minimal-proxy clones and configured via their own `initialize(...)`.
    /// @param implementation Address of the deployed hook implementation.
    function approveHookImpl(address implementation) external onlyFactoryManager afterDelay {
        if (implementation == address(0)) revert ZeroAddress();
        uint64 implId = IContractId(implementation).ID();
        if (implId == 0) revert ZeroImplId();
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.hookImpls[implId] != address(0)) revert ImplAlreadyApproved();
        $.hookImpls[implId] = implementation;
        emit HookImplApproved(implId, implementation);
    }

    /// @notice Block a hook implementation by ID so it can no longer be cloned.
    function blockHookImpl(uint64 implId) external onlyFactoryManager {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.hookImpls[implId] == address(0)) revert ImplNotFound();
        if ($.hookBlocked[implId]) revert AlreadyBlocked();
        $.hookBlocked[implId] = true;
        emit HookImplBlocked(implId);
    }

    /// @notice Unblock a previously-blocked hook implementation.
    /// @dev Owner-only and timelock-gated (Tier 2): unblocking re-enables cloning, so it
    ///      carries the same weight as approving an implementation.
    function unblockHookImpl(uint64 implId) external onlyOwner afterDelay {
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        if ($.hookImpls[implId] == address(0)) revert ImplNotFound();
        if (!$.hookBlocked[implId]) revert NotBlocked();
        $.hookBlocked[implId] = false;
        emit HookImplUnblocked(implId);
    }

    // =========================================================================
    // HOOK CLONE — deployment
    // =========================================================================

    /// @notice Clone a registered hook implementation with vault + factory as immutable args.
    ///
    /// @dev Immutable arg encoding (40 bytes): [factory (20)][vault (20)]
    ///      Both the vault address and this factory's own address are appended to the clone's
    ///      bytecode at clone time and read back via `VAULT()` / `FACTORY()` — hooks do not store
    ///      them in mutable storage. The embedded factory address lets each hook restrict its
    ///      `initialize(...)` to calls coming from the factory, closing the clone-initialization
    ///      front-running window: only the factory encoded into the clone can initialize it, and
    ///      that initialization happens atomically in the `clone_.call(initData)` below.
    ///      Hook-specific parameters (owner/admin, etc.) are supplied via `initData`.
    ///
    /// @param implId   Registered hook implementation ID.
    /// @param vault_   Vault address bound to this hook clone.
    /// @param initData ABI-encoded calldata forwarded to `clone.initialize(...)`.
    /// @return clone_  Address of the deployed clone.
    function cloneHook(uint64 implId, address vault_, bytes calldata initData)
        external
        whenNotPaused
        returns (address clone_)
    {
        if (vault_ == address(0)) revert ZeroAddress();

        PFSLib.PFStorage storage $ = PFSLib.fetch();
        address impl = $.hookImpls[implId];
        if (impl == address(0)) revert ImplNotFound();
        if ($.hookBlocked[implId]) revert ImplBlocked();

        if (initData.length == 0) revert InvalidInitData();

        clone_ = ClonesWithImmutableArgs.clone(impl, abi.encodePacked(address(this), vault_));
        $.hookClones[clone_] = true;

        (bool success, bytes memory returnData) = clone_.call(initData);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        emit HookCloned(clone_, implId);
    }

    // ── Hook views ──────────────────────────────────────────────────────────

    function getHookImpl(uint64 implId) external view returns (address) {
        return PFSLib.fetch().hookImpls[implId];
    }

    function isHookImplBlocked(uint64 implId) external view returns (bool) {
        return PFSLib.fetch().hookBlocked[implId];
    }

    function isRegisteredHookClone(address clone_) external view returns (bool) {
        return PFSLib.fetch().hookClones[clone_];
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Builds the immutable-args blob for a PMH clone.
    ///      Always starts with the standard 62-byte header:
    ///        [positionOwner(20)][collateralToken(20)][borrowToken(20)][collateralDecimals(1)][borrowDecimals(1)]
    ///      Then attempts a static call to `impl.resolveTokenId(token)`. If the implementation
    ///      exposes that function (e.g. PositionHelperDolomite), the two market IDs are appended
    ///      as uint256 values (32 bytes each), extending the blob to 126 bytes.
    function _getImmutableArgs(address positionOwner, address collateralToken, address borrowToken, address impl)
        internal
        view
        returns (bytes memory args)
    {
        args = abi.encodePacked(
            positionOwner,
            collateralToken,
            borrowToken,
            IERC20Metadata(collateralToken).decimals(),
            IERC20Metadata(borrowToken).decimals()
        );

        (bool okCollateral, bytes memory collateralData) =
            impl.staticcall(abi.encodeWithSignature("resolveTokenInfo(address)", collateralToken));
        (bool okBorrow, bytes memory borrowData) =
            impl.staticcall(abi.encodeWithSignature("resolveTokenInfo(address)", borrowToken));

        if (okCollateral && okBorrow && collateralData.length == 32 && borrowData.length == 32) {
            args = abi.encodePacked(args, collateralData, borrowData);
        }
    }

    function _upgradeStrategy(address proxy, uint64 newImplId, bytes calldata data) internal {
        PFSLib.PFStorage storage $ = PFSLib.fetch();

        if (!$.strategies[proxy].registered) revert NotRegistered();

        // Resolve the current implementation ID. For legacy contracts that pre-date
        // IContractId, hasNoId is true and we treat the implicit ID as 1 (catch-all).
        (uint64 currentImplId, bool hasNoId) = _getIdOfContract(proxy);
        if (hasNoId) currentImplId = 1;

        if (
            !IAccessControl(proxy).hasRole(PeripheryRolesLib.STRATEGY_ADMIN, msg.sender)
                && !IAccessControl(proxy).hasRole(PeripheryRolesLib.STRATEGY_UPGRADER, msg.sender)
        ) revert NotStrategyUpgrader();

        if (currentImplId == newImplId) revert SameImpl();
        if (!$.strategyMigratable[currentImplId][newImplId]) revert CanNotMigrate();

        address newImpl = $.strategyImpls[newImplId];
        if (newImpl == address(0)) revert ImplNotFound();
        if ($.strategyBlocked[newImplId]) revert ImplBlocked();

        // Upgrade via the ProxyAdmin that this factory owns.
        address pa = $.strategies[proxy].proxyAdmin;
        if (pa == address(0)) revert NoProxyAdmin();
        ProxyAdmin(pa).upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImpl, data);

        emit StrategyUpgraded(proxy, newImplId);
    }

    /// @dev Computes the ProxyAdmin address for a freshly-deployed TransparentUpgradeableProxy.
    ///      OZ v5 TransparentUpgradeableProxy deploys ProxyAdmin as its first outgoing CREATE
    ///      (contract nonce = 1), making the address deterministic via the standard RLP formula:
    ///      keccak256(rlp([proxy_address, nonce=1]))[12:]
    function _computeProxyAdmin(address proxy) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))))));
    }

    // ── Factory manager admin ───────────────────────────────────────────────────

    /// @notice Assign the FACTORY_MANAGER role to an address.
    /// @param manager The address to grant the factory manager role.
    /// @dev Only the owner can assign the manager. Immediate (no timelock) so a compromised
    ///      manager can be rotated promptly. The owner and manager roles are strictly separate.
    function setFactoryManager(address manager) external onlyOwner {
        if (manager == address(0)) revert ZeroAddress();
        PFSLib.PFStorage storage $ = PFSLib.fetch();
        emit FactoryManagerSet($.factoryManager, manager);
        $.factoryManager = manager;
    }

    /// @notice Get the current factory manager address.
    /// @return The address holding the FACTORY_MANAGER role.
    function getFactoryManager() external view returns (address) {
        return PFSLib.fetch().factoryManager;
    }

    // ── Pause controls ────────────────────────────────────────────────────────

    /// @notice Pause the factory, blocking new strategy deployments and PMH clones.
    /// @dev Callable by the factory manager with no timelock delay so deployments can be
    ///      halted promptly in an emergency.
    function pause() external onlyFactoryManager {
        _pause();
    }

    /// @notice Unpause the factory, re-enabling new deployments and clones.
    /// @dev Only the owner can unpause and only behind the timelock, so resuming operations
    ///      requires a prior queued and matured proposal.
    function unpause() external onlyOwner afterDelay {
        _unpause();
    }

    // ── Timelock admin ────────────────────────────────────────────────────────

    /// @inheritdoc ITimelockProtected
    /// @dev Only callable by the owner and only before timelock enforcement is activated.
    ///      After {activateTimelock} the timelock address is permanently locked.
    function setTimelock(address timelock_) external onlyOwner afterDelay {
        if (timelock_ == address(0)) revert ZeroAddress();
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

    // ── UUPS ──────────────────────────────────────────────────────────────────

    /// @dev Gates ownership transfers behind the timelock so that factory ownership
    ///      cannot be transferred without a prior queued and matured proposal. Uses the
    ///      two-step flow: this sets the pending owner, who must then call {acceptOwnership}.
    function transferOwnership(address newOwner) public override onlyOwner afterDelay {
        super.transferOwnership(newOwner);
    }

    /// @notice Permanently disabled — renouncing ownership is not permitted.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @dev Authorizes a UUPS upgrade of the factory itself. Gated behind the timelock so the
    ///      upgrade requires a prior queued and matured proposal. Emits {FactoryUpgradeAuthorized}
    ///      in addition to OZ's {IERC1967.Upgraded} so monitoring can attribute the upgrade to the
    ///      queued proposal that authorized it.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner afterDelay {
        emit FactoryUpgradeAuthorized(newImplementation, msg.sender);
    }
}
