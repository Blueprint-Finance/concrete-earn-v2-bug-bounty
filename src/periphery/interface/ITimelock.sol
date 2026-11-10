// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title ITimelock
 * @author Blueprint Finance
 * @notice Interface for the external tiered timelock contract.
 *
 * @dev The timelock is a single shared contract that gates privileged calls on
 *      registered protected contracts (vault, factory, strategy, etc.) by tier.
 *      One timelock instance can serve many vaults and strategies simultaneously
 *      as a central delay hub.
 *
 *      Workflow:
 *        1. `PROPOSER_ROLE` calls {propose} with the `target` protected contract,
 *           the `selector`, and the ABI-encoded `args`. The tier is resolved
 *           from the registered `(contractType, artifact)` pair, where
 *           `contractType = contractTypeOf[target]` and `artifact` is either the
 *           selector (for ordinary functions) or the role identifier (for
 *           `grantRole` proposals — extracted from `args`).
 *        2. Once `block.timestamp >= readyAt`, the protected contract's setter
 *           is invoked normally. Its `afterDelay` modifier calls
 *           {checkDelayExpired}, which validates and consumes the schedule
 *           entry. `msg.sender` of that call is the `target` from step 1.
 *        3. `GUARDIAN_ROLE` may {cancel} any queued action by ID.
 *        4. `OVERRIDE_ROLE` may {overrideTimelock} a queued action to make it
 *           executable from `block.timestamp` (very-high-threshold multisig).
 *
 *      All state (schedules, tier delays, artifact-to-tier mappings, role
 *      definitions, target bindings) lives in the timelock contract — protected
 *      contracts hold only the timelock address and a thin `afterDelay`
 *      modifier that delegates the check to this interface.
 *
 *      `actionId = keccak256(abi.encode(target, selector, args))`. Including
 *      `target` ensures distinct vault/strategy instances do not collide on
 *      shared selectors. The hash is removed when the action is consumed (via
 *      {checkDelayExpired}), canceled (via {cancel}), or after
 *      {overrideTimelock} when it is subsequently consumed.
 *
 *      Artifact encoding (see {addArtifact}):
 *        - Function selectors: `artifact = bytes32(bytes4(selector))`
 *          (4 bytes high, 28 bytes zero).
 *        - Role identifiers:   `artifact = role` (already `bytes32`).
 *      Collision between the two encodings is negligible (~2^-224).
 */
interface ITimelock {
    // ── Errors ───────────────────────────────────────────────────────────────

    /// @notice Thrown when an `actionId` lookup yields no schedule entry.
    error UnknownAction(bytes32 actionId);

    /// @notice Thrown when a duplicate `propose` is attempted for an existing actionId.
    error DuplicateAction(bytes32 actionId);

    /// @notice Thrown when an action's `readyAt` has not yet elapsed.
    error ActionNotReady(bytes32 actionId, uint256 readyAt, uint256 nowTs);

    /// @notice Thrown when an action has matured but was not consumed within
    ///         the staleness window (`STALENESS_WINDOW` seconds after `readyAt`).
    ///         Stale entries can be cleared by {cancel} or revived by
    ///         {overrideTimelock} (which re-stamps `readyAt` to "now").
    error ActionStale(bytes32 actionId, uint256 staleAt, uint256 nowTs);

    /// @notice Thrown when a `(contractType, artifact)` pair has no registered tier.
    error ArtifactNotRegistered(bytes4 contractType, bytes32 artifact);

    /// @notice Thrown by {addArtifact} when the `(contractType, artifact)` pair
    ///         already has a registered tier.
    error ArtifactAlreadyRegistered(bytes4 contractType, bytes32 artifact);

    /// @notice Thrown when a tier code is not a known tier.
    error UnknownTier(bytes4 tier);

    /// @notice Thrown when an `updateTierDelay` call would exceed the configured bounds.
    error DelayOutOfBounds(uint256 delay, uint256 minDelay, uint256 maxDelay);

    /// @notice Thrown when an `updateTierDelay` call would violate the required
    ///         ordering invariant TIER_1 > TIER_2 > TIER_3.
    error TierOrderViolation();

    /// @notice Thrown when {propose} or {checkDelayExpired} resolves a `target` that has no registered contract type.
    error TargetNotBound(address target);

    /// @notice Thrown when a {bindContract} call is made for an address that is already bound.
    error TargetAlreadyBound(address target, bytes4 contractType);

    /// @notice Thrown when {activateTimelock} is called and the timelock is already active.
    error AlreadyActive();

    /// @notice Thrown when a zero address is supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice Thrown by {pruneStale} when the action exists but has not yet
    ///         passed `readyAt + STALENESS_WINDOW` and is therefore not stale.
    error ActionNotYetStale(bytes32 actionId, uint256 staleAt, uint256 nowTs);

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a new schedule entry is created via {propose}.
    event Proposed(
        bytes32 indexed actionId,
        address indexed target,
        bytes4 contractType,
        bytes4 indexed selector,
        bytes32 artifact,
        bytes args,
        bytes4 tier,
        uint256 readyAt
    );

    /// @notice Emitted when a schedule entry is consumed by {checkDelayExpired}.
    event Consumed(bytes32 indexed actionId);

    /// @notice Emitted when a schedule entry is removed by {cancel}.
    event Canceled(bytes32 indexed actionId);

    /// @notice Emitted when a schedule entry's `readyAt` is compressed to the current block by {overrideTimelock}.
    event Overridden(bytes32 indexed actionId, uint256 newReadyAt);

    /// @notice Emitted when {updateTierDelay} mutates a tier's delay value.
    event TierDelayUpdated(bytes4 indexed tier, uint256 oldDelay, uint256 newDelay);

    /// @notice Emitted when {addArtifact} registers (or re-tiers) a `(contractType, artifact)` pair.
    event ArtifactRegistered(bytes4 indexed contractType, bytes32 indexed artifact, bytes4 tier);

    /// @notice Emitted when {changeTier} re-tiers an existing `(contractType, artifact)` pair.
    ///         `previousTier` is the tier the artifact was registered under prior to the change.
    event ArtifactTierChanged(
        bytes4 indexed contractType, bytes32 indexed artifact, bytes4 previousTier, bytes4 newTier
    );

    /// @notice Emitted when {bindContract} associates a protected contract address with a `contractType`.
    event ContractBound(address indexed protectedContract, bytes4 indexed contractType);

    /// @notice Emitted when {unbindContract} removes an existing binding.
    ///         `contractType` is the type the target was previously bound to.
    event ContractUnbound(address indexed protectedContract, bytes4 indexed contractType);

    /// @notice Emitted when the timelock is irreversibly activated.
    event TimelockActivated();

    /// @notice Emitted when a stale schedule entry is removed by {pruneStale}.
    ///         Distinct from {Canceled} to distinguish automated housekeeping
    ///         from deliberate Guardian intervention.
    event Pruned(bytes32 indexed actionId);

    /// @notice Emitted when an upgrade of the timelock itself is authorized.
    /// @param newImplementation address of the implementation the timelock is upgrading to
    /// @param authorizedBy address that authorized the upgrade (holder of UPGRADER_ROLE)
    /// @dev Emitted in addition to OpenZeppelin's {IERC1967.Upgraded} so that monitoring can
    ///      attribute the upgrade to the queued timelock proposal that authorized it.
    event TimelockUpgradeAuthorized(address indexed newImplementation, address indexed authorizedBy);

    // ── Mutating functions (canonical interface) ─────────────────────────────

    /**
     * @notice Schedules an action for delayed execution against a specific target.
     * @dev Only callable by `PROPOSER_ROLE`. The contract type is resolved from
     *      `contractTypeOf[target]` (reverts {TargetNotBound} if unset). The
     *      artifact is `bytes32(bytes4(selector))` for ordinary functions, or
     *      the role identifier decoded from `args` when `selector ==
     *      IAccessControl.grantRole.selector`. The tier is then looked up via
     *      `artifactDelayTier[contractType][artifact]` (reverts
     *      {ArtifactNotRegistered} if zero). Reverts {DuplicateAction} if an
     *      entry already exists for the resulting `actionId`.
     * @param target   Protected contract instance the call targets.
     * @param selector 4-byte function selector to invoke on `target`.
     * @param args     ABI-encoded arguments (calldata tail excluding the selector).
     * @return actionId `keccak256(abi.encode(target, selector, args))`.
     */
    function propose(address target, bytes4 selector, bytes calldata args) external returns (bytes32 actionId);

    /**
     * @notice Removes a schedule entry that has become stale (i.e. it matured
     *         but was not consumed within `STALENESS_WINDOW` seconds of
     *         `readyAt` and is therefore permanently unconsumable).
     * @dev Only callable by `JANITOR_ROLE`. Intended for backend automation or
     *      keeper bots that periodically sweep expired entries.
     *
     *      Unlike {cancel} (which is a deliberate Guardian intervention and
     *      works on *any* existing entry), `pruneStale` is purely mechanical:
     *      it only removes entries whose consumption window has already closed.
     *      It cannot touch pending or matured-but-fresh entries.
     *
     *      Intentionally NOT self-timelocked: deleting an already-unconsumable
     *      entry has no attack surface.
     * @param actionId The action identifier to prune. Reverts {UnknownAction}
     *                 if no entry exists, or {ActionNotYetStale} if the entry
     *                 has not yet passed `readyAt + STALENESS_WINDOW`.
     */
    function pruneStale(bytes32 actionId) external;

    /**
     * @notice Cancels a queued action.
     * @dev Only callable by `GUARDIAN_ROLE`. Deletes `schedules[actionId]`
     *      and emits {Canceled}; reverts {UnknownAction} if no entry exists
     *      (never proposed, already consumed, or already canceled).
     *
     *      Intentionally NOT self-timelocked: the Guardian must be able to
     *      invalidate a queued action before its delay matures.
     * @param actionId The action identifier returned by {propose}.
     */
    function cancel(bytes32 actionId) external;

    /**
     * @notice Updates the delay associated with a tier.
     * @dev Only callable by `CONFIG_ROLE` (high-threshold multisig) and
     *      self-timelocked under `(CT_TIMELOCK, updateTierDelay.selector)` at
     *      `TIER_1` — these delays gate every other protected action, so they
     *      get the longest review window.
     *
     *      The conventional ordering `TIER_1 ≥ TIER_2 ≥ TIER_3 ≥ MIN_DELAY`
     *      (where `TIER_1` is the highest-risk tier and carries the longest
     *      delay) is a deployment-time invariant and is *not* re-validated
     *      here: the `CONFIG_ROLE` multisig is trusted to stage migrations
     *      between consistent end states without sequencing intermediate
     *      proposals.
     * @param tier  Tier code being updated. Must be `TIER_1`, `TIER_2`, or `TIER_3`.
     * @param delay New delay in seconds, bounded by `MIN_DELAY` / `MAX_DELAY`.
     */
    function updateTierDelay(bytes4 tier, uint256 delay) external;

    /**
     * @notice Compresses a queued action's `readyAt` to `block.timestamp`.
     * @dev Only callable by `OVERRIDE_ROLE` (very-high-threshold multisig).
     *      The action must already exist; this never creates new entries. The
     *      original `onlyRole` check on the protected contract still runs at
     *      execution time, and Guardian can still {cancel} before consumption.
     * @param actionId The action identifier to override.
     */
    function overrideTimelock(bytes32 actionId) external;

    /**
     * @notice Registers a `(contractType, artifact)` pair under a delay tier.
     * @dev Only callable by `CONFIG_ROLE` and self-timelocked under
     *      `(CT_TIMELOCK, addArtifact.selector)
     *
     *      This entry point is *register-only*: re-tiering an existing entry
     *      requires a separate {changeTier} call. Removal is not supported.
     *
     *      The `artifact` encoding determines what the entry gates:
     *        - `bytes32(bytes4(selector))` — gates ordinary function calls with
     *          that selector on contracts of `contractType`.
     *        - `role` (a `keccak256` role identifier) — gates `grantRole` calls
     *          on contracts of `contractType` for that specific role.
     *
     * @param contractType Contract type the artifact belongs to.
     * @param artifact     Generic identifier (selector or role) being registered.
     * @param tier         Tier code to assign. Must be `TIER_1`, `TIER_2`, or `TIER_3`.
     */
    function addArtifact(bytes4 contractType, bytes32 artifact, bytes4 tier) external;

    /**
     * @notice Re-tiers an existing `(contractType, artifact)` registration.
     * @dev Only callable by `CONFIG_ROLE` and self-timelocked under
     *      `(CT_TIMELOCK, changeTier.selector)` at `TIER_1` — re-tiering an
     *      already-protected artifact alters its review window for every
     *      future proposal, so it carries the longest delay.
     *
     *      Already-queued schedule entries for the artifact are not affected:
     *      their `readyAt` was fixed at {propose} time using the prior tier.
     *      Only proposals made after the change pick up `newTier`.
     * @param contractType Contract type the artifact belongs to.
     * @param artifact     Generic identifier (selector or role) being re-tiered.
     * @param newTier      Tier code to assign. Must be `TIER_1`, `TIER_2`, or `TIER_3`.
     */
    function changeTier(bytes4 contractType, bytes32 artifact, bytes4 newTier) external;

    /**
     * @notice Called by protected contracts via their `afterDelay` modifier to
     *         validate and consume a matured schedule entry for the caller.
     * @dev `msg.sender` is the protected contract — i.e. the `target` used in
     *      {propose}. The function:
     *        1. Returns immediately if {isActive} is false (deploy-window no-op).
     *        2. Recomputes `actionId = keccak256(abi.encode(msg.sender, selector, args))`.
     *        3. Reverts {UnknownAction} if no schedule entry exists (no prior
     *           {propose}, or it has already been consumed / canceled).
     *        4. Reverts {ActionNotReady} if `block.timestamp < readyAt`.
     *        5. Reverts {ActionStale} if `block.timestamp > readyAt + STALENESS_WINDOW`.
     *           Matured-but-unconsumed actions therefore have a bounded
     *           consumption window: stale entries cannot quietly resurface
     *           weeks or months later. Stale entries can be cleared with
     *           {cancel} or explicitly revived through {overrideTimelock}
     *           (which re-stamps `readyAt` to "now").
     *        6. Deletes the entry and emits {Consumed}.
     *
     *      The artifact registry is intentionally NOT consulted here: every
     *      `afterDelay`-protected call unconditionally requires a matured
     *      schedule entry, regardless of whether its selector is registered.
     *      The registry governs only {propose}-time tier resolution.
     * @param selector The selector of the function being invoked on the caller.
     * @param args     The calldata tail of the function being invoked (excluding the selector).
     */
    function checkDelayExpired(bytes4 selector, bytes calldata args) external;

    // ── Admin / registry ─────────────────────────────────────────────────────

    /**
     * @notice Irreversibly activates the timelock. While inactive,
     *         {checkDelayExpired} no-ops.
     */
    function activateTimelock() external;

    /**
     * @notice Associates a protected contract address with a `contractType` so
     *         that {propose} and {checkDelayExpired} can resolve the type from
     *         the target / `msg.sender`.
     * @dev Only callable by `CONFIG_ROLE` and self-timelocked under
     *      `(CT_TIMELOCK, bindContract.selector)`. Reverts {ZeroAddress} for
     *      a zero target and {TargetAlreadyBound} if the target is already
     *      bound (use {unbindContract} first to rebind).
     * @param protectedContract Address of the deployed protected contract.
     * @param contractType      Registered contract type to assign.
     */
    function bindContract(address protectedContract, bytes4 contractType) external;

    /**
     * @notice Removes the binding for a protected contract address.
     * @dev Only callable by `CONFIG_ROLE` and self-timelocked under
     *      `(CT_TIMELOCK, unbindContract.selector)`
     *
     *      Note: unbinding does not cancel any already-queued {propose}
     *      entries against the target — they keep their `actionId` and remain
     *      consumable through {checkDelayExpired} (which does not consult the
     *      binding registry). To fully retire a binding, Guardians should
     *      also {cancel} any pending actions targeting it.
     * @param protectedContract Address of the bound contract whose binding is removed.
     */
    function unbindContract(address protectedContract) external;

    // ── Views ────────────────────────────────────────────────────────────────

    /// @notice Returns the configured delay (seconds) for a tier.
    function tierDelay(bytes4 tier) external view returns (uint256);

    /// @notice Returns the tier registered for a `(contractType, artifact)` pair, or `bytes4(0)` if unregistered.
    function artifactDelayTier(bytes4 contractType, bytes32 artifact) external view returns (bytes4);

    /// @notice Returns the `readyAt` timestamp for a queued action, or `0` if none.
    function readyAt(bytes32 actionId) external view returns (uint256);

    /// @notice Returns the `contractType` bound to a protected contract address, or `bytes4(0)` if unbound.
    function contractTypeOf(address protectedContract) external view returns (bytes4);

    /// @notice Returns whether the timelock has been activated.
    function isActive() external view returns (bool);

    /// @notice Computes the canonical action identifier for a `(target, selector, args)` tuple.
    function computeActionId(address target, bytes4 selector, bytes calldata args) external pure returns (bytes32);
}
