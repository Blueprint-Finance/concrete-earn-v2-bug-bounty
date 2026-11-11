// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title Timelock
 * @notice External tiered timelock contract that gates privileged calls on
 *         registered protected contracts (vault, factory, strategy, etc.).
 *         Designed to serve many vault and strategy instances as a single
 *         central delay hub.
 *
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:oz-upgrades Uses UUPS + eip7201 storage layout
 */

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin
// ─────────────────────────────────────────────────────────────────────────────
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {ITimelock} from "../interface/ITimelock.sol";
import {TimelockStorageLib} from "../lib/TimelockStorageLib.sol";
import {TimelockRolesLib} from "../lib/TimelockRolesLib.sol";
import {TimelockConfigurationLib as Config} from "../lib/TimelockConfigurationLib.sol";

contract Timelock is ITimelock, AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    // Role identifiers come from {TimelockRolesLib}; tier codes / defaults
    // and the artifact-registry seeding come from {TimelockConfigurationLib}.
    // The handful of constants below are pure runtime parameters and stay on
    // the contract so they remain part of its public ABI.

    // ── Delay bounds for {updateTierDelay} ───────────────────────────────────

    uint256 public constant MIN_DELAY = 6 hours;
    uint256 public constant MAX_DELAY = 30 days;

    // ── Staleness window for matured schedule entries ────────────────────────

    /// @notice Maximum interval between a schedule entry maturing (`readyAt`)
    ///         and {checkDelayExpired} consuming it. Past this window the
    ///         entry becomes {ActionStale} and can no longer be consumed —
    ///         only {cancel}ed or revived through {overrideTimelock}.
    uint256 public constant STALENESS_WINDOW = 2 weeks;

    // ── Errors ───────────────────────────────────────────────────────────────

    /// @notice Thrown by skeleton stubs that have no implementation body yet.
    error NotImplemented();

    /// @notice Thrown by {initialize} when supplied a zero admin address.
    error ZeroAdmin();

    /// @notice Thrown when a revoke/renounce would remove the last
    ///         `DEFAULT_ADMIN_ROLE` holder, leaving the timelock permanently
    ///         without an admin.
    error CannotRemoveLastAdmin();

    // ── Modifiers ────────────────────────────────────────────────────────────

    /// @dev Mirror of the modifier expected to live on protected contracts.
    ///      Used here to self-timelock the timelock's own administrative
    ///      functions (notably {upgradeToAndCall}). The external self-call
    ///      makes `msg.sender` of {checkDelayExpired} equal to `address(this)`,
    ///      which is bound to {CT_TIMELOCK} during {initialize}.
    modifier afterDelay() {
        this.checkDelayExpired(msg.sig, msg.data[4:]);
        _;
    }

    // ── Constructor / initializer ────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the timelock with default tier delays, self-binds to
     *         {CT_TIMELOCK}, registers the self-timelocked admin selectors
     *         (`upgradeToAndCall`, `bindContract`, `unbindContract`), and
     *         seeds the role graph.
     * @param admin Initial holder of `DEFAULT_ADMIN_ROLE` (and bootstrap holder
     *              of all other roles until they are reassigned to dedicated
     *              multisigs).
     */
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAdmin();

        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();

        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();

        // Deploy-time configuration lives in {TimelockConfigurationLib}; the
        // helpers below are `internal` so they inline directly into this
        // initializer (no DELEGATECALL overhead).
        Config.seedTierDelayDefaults($);
        Config.seedTimelockSelfArtifacts($, address(this));
        Config.seedConcreteStandardVaultArtifacts($);
        Config.seedConcreteFactoryArtifacts($);
        Config.seedBaseStrategyArtifacts($);
        Config.seedPeripheryFactoryArtifacts($);
        Config.seedAssetCxArtifacts($);
        Config.seedConcreteMerchantArtifacts($);
        Config.seedRedemptionClaimTokenArtifacts($);
        Config.seedAssetCxLiquidationModuleArtifacts($);
        Config.seedHookContainerArtifacts($);
        Config.seedOracleModuleArtifacts($);

        // admin is a very high-threshold governance multisig
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TimelockRolesLib.PROPOSER_ROLE, admin);
        _grantRole(TimelockRolesLib.GUARDIAN_ROLE, admin);
        _grantRole(TimelockRolesLib.CONFIG_ROLE, admin);
        _grantRole(TimelockRolesLib.OVERRIDE_ROLE, admin);
        _grantRole(TimelockRolesLib.UPGRADER_ROLE, admin);
        _grantRole(TimelockRolesLib.JANITOR_ROLE, admin);
    }

    /**
     * @notice Re-runs the {TimelockConfigurationLib} artifact-registry seeding on
     *         an already-deployed timelock so its on-chain registry matches the
     *         current code. Intended to be invoked (typically via
     *         `upgradeToAndCall`) after new protected contract types or selectors
     *         are added in code.
     * @dev Bumps the initializer version to 3, so it can run exactly once per
     *      version. Re-seeding is idempotent: each helper only writes
     *      `(contractType, artifact) -> tier` entries (and the timelock's own
     *      self-binding), so re-running overwrites them with the current code
     *      values without touching schedules, contract bindings, role
     *      membership, or the `active` flag. Gated to `UPGRADER_ROLE`.
     */
    function reinitializeV3() external reinitializer(3) onlyRole(TimelockRolesLib.UPGRADER_ROLE) {
        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();

        Config.seedTimelockSelfArtifacts($, address(this));
        Config.seedConcreteStandardVaultArtifacts($);
        Config.seedConcreteFactoryArtifacts($);
        Config.seedBaseStrategyArtifacts($);
        Config.seedPeripheryFactoryArtifacts($);
        Config.seedAssetCxArtifacts($);
        Config.seedConcreteMerchantArtifacts($);
        Config.seedRedemptionClaimTokenArtifacts($);
        Config.seedAssetCxLiquidationModuleArtifacts($);
        Config.seedHookContainerArtifacts($);
        Config.seedOracleModuleArtifacts($);
    }

    // ── Canonical mutating functions ─────────────────────────────────────────

    /// @inheritdoc ITimelock
    function propose(address target, bytes4 selector, bytes calldata args)
        external
        onlyRole(TimelockRolesLib.PROPOSER_ROLE)
        returns (bytes32 actionId)
    {
        if (target == address(0)) revert ZeroAddress();

        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();

        bytes4 contractType = $.contractTypeOf[target];
        if (contractType == bytes4(0)) revert TargetNotBound(target);

        bytes32 artifact = _artifactFor(selector, args);
        bytes4 tier = $.artifactDelayTier[contractType][artifact];

        if (tier == bytes4(0)) revert ArtifactNotRegistered(contractType, artifact);

        actionId = _computeActionId(target, selector, args);
        if ($.schedules[actionId] != 0) revert DuplicateAction(actionId);

        uint256 readyAt_ = block.timestamp + $.tierDelay[tier];
        $.schedules[actionId] = readyAt_;

        emit Proposed(actionId, target, contractType, selector, artifact, args, tier, readyAt_);
    }

    /// @inheritdoc ITimelock
    function pruneStale(bytes32 actionId) external onlyRole(TimelockRolesLib.JANITOR_ROLE) {
        // No `afterDelay`: removing an already-unconsumable entry has no
        // attack surface. A stale entry cannot be executed, so deleting it
        // purely cleans up storage.
        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();

        uint256 readyAt_ = $.schedules[actionId];
        if (readyAt_ == 0) revert UnknownAction(actionId);

        uint256 staleAt = readyAt_ + STALENESS_WINDOW;
        if (block.timestamp <= staleAt) revert ActionNotYetStale(actionId, staleAt, block.timestamp);

        delete $.schedules[actionId];

        emit Pruned(actionId);
    }

    /// @inheritdoc ITimelock
    function cancel(bytes32 actionId) external onlyRole(TimelockRolesLib.GUARDIAN_ROLE) {
        // Defensive action: intentionally NOT self-timelocked.
        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();
        if ($.schedules[actionId] == 0) revert UnknownAction(actionId);

        delete $.schedules[actionId];

        emit Canceled(actionId);
    }

    /// @inheritdoc ITimelock
    function updateTierDelay(bytes4 tier, uint256 delay) external onlyRole(TimelockRolesLib.CONFIG_ROLE) afterDelay {
        _requireKnownTier(tier);
        if (delay < MIN_DELAY || delay > MAX_DELAY) {
            revert DelayOutOfBounds(delay, MIN_DELAY, MAX_DELAY);
        }

        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();
        uint256 oldDelay = $.tierDelay[tier];
        $.tierDelay[tier] = delay;

        if (
            $.tierDelay[Config.TIER_3] >= $.tierDelay[Config.TIER_2]
                || $.tierDelay[Config.TIER_2] >= $.tierDelay[Config.TIER_1]
        ) {
            revert TierOrderViolation();
        }

        emit TierDelayUpdated(tier, oldDelay, delay);
    }

    /// @inheritdoc ITimelock
    function overrideTimelock(bytes32 actionId) external onlyRole(TimelockRolesLib.OVERRIDE_ROLE) {
        // Intentionally NOT self-timelocked: override is the break-glass lever
        // for emergencies and is gated solely by `OVERRIDE_ROLE`
        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();
        if ($.schedules[actionId] == 0) revert UnknownAction(actionId);

        $.schedules[actionId] = block.timestamp;

        emit Overridden(actionId, block.timestamp);
    }

    /// @inheritdoc ITimelock
    function addArtifact(bytes4 contractType, bytes32 artifact, bytes4 tier)
        external
        onlyRole(TimelockRolesLib.CONFIG_ROLE)
    {
        _requireKnownTier(tier);

        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();
        if ($.artifactDelayTier[contractType][artifact] != bytes4(0)) {
            revert ArtifactAlreadyRegistered(contractType, artifact);
        }

        $.artifactDelayTier[contractType][artifact] = tier;

        emit ArtifactRegistered(contractType, artifact, tier);
    }

    /// @inheritdoc ITimelock
    function changeTier(bytes4 contractType, bytes32 artifact, bytes4 newTier)
        external
        onlyRole(TimelockRolesLib.CONFIG_ROLE)
        afterDelay
    {
        _requireKnownTier(newTier);

        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();
        bytes4 previousTier = $.artifactDelayTier[contractType][artifact];
        if (previousTier == bytes4(0)) revert ArtifactNotRegistered(contractType, artifact);

        $.artifactDelayTier[contractType][artifact] = newTier;

        emit ArtifactTierChanged(contractType, artifact, previousTier, newTier);
    }

    /// @inheritdoc ITimelock
    function checkDelayExpired(bytes4 selector, bytes calldata args) external {
        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();

        // While `active` is false, every {afterDelay}-protected call passes
        // through unchecked. This lets the bootstrap operator deploy,
        // configure, and bind protected contracts before flipping the one-way
        // {activateTimelock} switch.
        if (!$.active) return;

        // Trust gate: only a bound protected contract may consume a schedule
        // entry. Defense-in-depth on top of the `msg.sender`-in-`actionId`
        // binding below.
        bytes4 contractType = $.contractTypeOf[msg.sender];
        if (contractType == bytes4(0)) revert TargetNotBound(msg.sender);

        // Recompute `actionId` with `msg.sender` as the `target` — symmetric to
        // {propose}. The artifact registry is intentionally NOT consulted here:
        // every `afterDelay`-protected call unconditionally requires a matured
        // schedule entry, regardless of whether its selector is registered.
        // The registry only governs `propose`-time tier resolution.
        bytes32 actionId = _computeActionId(msg.sender, selector, args);
        uint256 readyAt_ = $.schedules[actionId];
        if (readyAt_ == 0) revert UnknownAction(actionId);
        if (block.timestamp < readyAt_) revert ActionNotReady(actionId, readyAt_, block.timestamp);

        // Bounded consumption window: a matured action that lingers past
        // {STALENESS_WINDOW} becomes {ActionStale} and can no longer be
        // consumed.
        // Guardians can {cancel} stale entries; {overrideTimelock} can revive
        // one by re-stamping `readyAt` to "now".
        uint256 staleAt = readyAt_ + STALENESS_WINDOW;
        if (block.timestamp > staleAt) revert ActionStale(actionId, staleAt, block.timestamp);

        delete $.schedules[actionId];
        emit Consumed(actionId);
    }

    // ── Admin / registry ─────────────────────────────────────────────────────

    /// @inheritdoc ITimelock
    function activateTimelock() external onlyRole(DEFAULT_ADMIN_ROLE) {
        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();
        if ($.active) revert AlreadyActive();

        $.active = true;

        emit TimelockActivated();
    }

    /// @inheritdoc ITimelock
    function bindContract(address protectedContract, bytes4 contractType)
        external
        onlyRole(TimelockRolesLib.CONFIG_ROLE)
    {
        if (protectedContract == address(0)) revert ZeroAddress();

        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();

        bytes4 existing = $.contractTypeOf[protectedContract];
        if (existing != bytes4(0)) revert TargetAlreadyBound(protectedContract, existing);

        $.contractTypeOf[protectedContract] = contractType;

        emit ContractBound(protectedContract, contractType);
    }

    /// @inheritdoc ITimelock
    function unbindContract(address protectedContract) external onlyRole(TimelockRolesLib.CONFIG_ROLE) afterDelay {
        if (protectedContract == address(0)) revert ZeroAddress();

        TimelockStorageLib.TimelockStorage storage $ = TimelockStorageLib.fetch();

        bytes4 existing = $.contractTypeOf[protectedContract];
        if (existing == bytes4(0)) revert TargetNotBound(protectedContract);

        delete $.contractTypeOf[protectedContract];

        emit ContractUnbound(protectedContract, existing);
    }

    // ── Access control overrides ─────────────────────────────────────────────

    /// @notice Self-timelocks `grantRole` for the privileged configuration roles.
    /// @dev Granting {CONFIG_ROLE}, {OVERRIDE_ROLE}, or {UPGRADER_ROLE} requires
    ///      a prior matured {propose} (registered at TIER_2 under {CT_TIMELOCK}),
    ///      routed through the same external self-call as {afterDelay}.
    ///      {PROPOSER_ROLE}, {GUARDIAN_ROLE}, and {JANITOR_ROLE} grants are
    ///      intentionally exempt and execute immediately.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (
            role == TimelockRolesLib.CONFIG_ROLE || role == TimelockRolesLib.OVERRIDE_ROLE
                || role == TimelockRolesLib.UPGRADER_ROLE || role == DEFAULT_ADMIN_ROLE
        ) {
            this.checkDelayExpired(msg.sig, msg.data[4:]);
        }
        super.grantRole(role, account);
    }

    /// @notice Prevents removing the last `DEFAULT_ADMIN_ROLE`, which would
    ///         leave the timelock permanently without an admin.
    /// @dev Both {revokeRole} and {renounceRole} funnel through this hook, so
    ///      this single override blocks self-revoke, self-renounce, and
    ///      admin-revokes-admin alike. With multiple admins any one of them
    ///      (including the caller) can still be removed.
    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1) {
            revert CannotRemoveLastAdmin();
        }
        return super._revokeRole(role, account);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc ITimelock
    function tierDelay(bytes4 tier) external view returns (uint256) {
        return TimelockStorageLib.fetch().tierDelay[tier];
    }

    /// @inheritdoc ITimelock
    function artifactDelayTier(bytes4 contractType, bytes32 artifact) external view returns (bytes4) {
        return TimelockStorageLib.fetch().artifactDelayTier[contractType][artifact];
    }

    /// @inheritdoc ITimelock
    function readyAt(bytes32 actionId) external view returns (uint256) {
        return TimelockStorageLib.fetch().schedules[actionId];
    }

    /// @inheritdoc ITimelock
    function contractTypeOf(address protectedContract) external view returns (bytes4) {
        return TimelockStorageLib.fetch().contractTypeOf[protectedContract];
    }

    /// @inheritdoc ITimelock
    function isActive() external view returns (bool) {
        return TimelockStorageLib.fetch().active;
    }

    /// @inheritdoc ITimelock
    function computeActionId(address target, bytes4 selector, bytes calldata args) external pure returns (bytes32) {
        return _computeActionId(target, selector, args);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    /**
     * @dev Computes the canonical `actionId` for a `(target, selector, args)`
     *      tuple. Used by {propose} when writing the schedule entry and by
     *      {computeActionId} for off-chain consumers; {checkDelayExpired}
     *      recomputes the same hash with `msg.sender` as `target`.
     */
    function _computeActionId(address target, bytes4 selector, bytes calldata args) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, selector, args));
    }

    /**
     * @dev Resolves the `artifact` key for a `(selector, args)` pair.
     *
     *      - For `IAccessControl.grantRole(bytes32 role, address account)`:
     *        decodes `role` from `args` and returns it as the artifact, so that
     *        per-role tiers are looked up at
     *        `artifactDelayTier[contractType][role]`. `abi.decode` reverts if
     *        `args` is not the well-formed `(bytes32, address)` calldata tail.
     *      - For any other selector: returns `bytes32(bytes4(selector))` —
     *        the selector left-aligned into the high 4 bytes, low 28 bytes
     *        zero. Collision with a role identifier is negligible (~2^-224).
     */
    function _artifactFor(bytes4 selector, bytes calldata args) internal pure returns (bytes32) {
        if (selector == IAccessControl.grantRole.selector) {
            (bytes32 role,) = abi.decode(args, (bytes32, address));
            return role;
        }
        return bytes32(selector);
    }

    /**
     * @dev Reverts {UnknownTier} unless `tier` is one of the three configured
     *      tiers. The valid set is `{TIER_1, TIER_2, TIER_3}` — `bytes4(0)` is
     *      explicitly excluded so that it can keep its role of "unregistered"
     *      sentinel across the artifact registry.
     */
    function _requireKnownTier(bytes4 tier) internal pure {
        if (tier != Config.TIER_1 && tier != Config.TIER_2 && tier != Config.TIER_3) revert UnknownTier(tier);
    }

    // ── UUPS — self-timelocked upgrade ───────────────────────────────────────

    /**
     * @notice Self-timelocked UUPS authorization hook.
     * @dev {UUPSUpgradeable.upgradeToAndCall} calls this internally before
     *      performing the upgrade. Gating it with {afterDelay} routes the
     *      upgrade through the same `propose → mature → execute` flow as any
     *      other protected function: a prior
     *      `propose(address(this), upgradeToAndCall.selector, args)` must
     *      have matured. `msg.sig` and `msg.data` are set by the external
     *      `upgradeToAndCall` entry point and are unchanged by the internal
     *      hop to this hook, so the registered selector under {CT_TIMELOCK}
     *      remains `upgradeToAndCall.selector`.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(TimelockRolesLib.UPGRADER_ROLE)
        afterDelay
    {
        emit TimelockUpgradeAuthorized(newImplementation, msg.sender);
    }
}
