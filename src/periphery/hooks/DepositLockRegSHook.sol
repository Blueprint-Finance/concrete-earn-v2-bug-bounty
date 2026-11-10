// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IHook} from "../../interface/IHook.sol";
import {DepositLockHook} from "./DepositLockHook.sol";
import {IDepositLockRegSHook} from "./IDepositLockRegSHook.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

/**
 * @dev Minimal view surface used by {DepositLockRegSHook} to enforce that the bound vault does
 *      not expose a user-cancellable withdrawal-request flow. `cancellationEnabled` is declared
 *      on the base vault interface and implemented by every vault: synchronous vaults have no
 *      cancellation flow and return `false` unconditionally, while async vaults return `false`
 *      only once cancellation has been disabled via `configure`. The hook can therefore read it
 *      with a single unconditional call, with no vault-type detection required.
 */
interface IVaultCancellationConfig {
    function cancellationEnabled() external view returns (bool);
}

/**
 * @title DepositLockRegSHook
 * @notice Three-stage share-lock extension of {DepositLockHook}: in addition to the base
 *         hook's transfer/withdraw/redeem block, it carves the locked period into a
 *         **hard-lock** prefix (`[creation, creation + hardLockDuration)`) where both
 *         transfers and redeem/withdraw are blocked, and a **Reg S** middle window
 *         (`[creation + hardLockDuration, creation + hardLockDuration + REG_S_EXTENSION)`)
 *         where redeem/withdraw is allowed but transfers remain blocked. After the full
 *         duration elapses, shares are fully unlocked.
 *
 *         For every individual lock:
 *
 *           [HARD_LOCKED]      block.timestamp <  redeemUnlockTimestamp
 *               │  transfers and redeem/withdraw both blocked
 *               ▼  block.timestamp >= redeemUnlockTimestamp
 *           [REDEEM_UNLOCKED]  block.timestamp <  transferUnlockTimestamp
 *               │  redeem/withdraw allowed; transfers still blocked
 *               ▼  block.timestamp >= transferUnlockTimestamp
 *           [FULLY_UNLOCKED]   entry removed from the queue on next cleanup
 *
 * @dev    ## Inheritance strategy
 *
 *         The base's `Lock` struct, `_locks`, `_totalLocked`, sorted-insert / cleanup
 *         logic, modifier `onlyVaultOrHookContainer`, common errors and admin surface
 *         (`setMaxLocksPerUser`, `setHookContainer`) are reused verbatim. The base's
 *         `depositLockDuration` slot stores `hardLockDuration + REG_S_EXTENSION` — i.e.
 *         the **transfer** unlock duration, which is the latest of the two unlocks and
 *         therefore the value that drives lock removal during cleanup. The implicit
 *         `redeemUnlockTimestamp` of each lock is derived on demand as
 *         `Lock.unlockTimestamp - REG_S_EXTENSION`.
 *
 *         What this contract adds on top of the base:
 *           - Two-axis enforcement: `preTransfer` keeps the base's behaviour but routes
 *             through {_requireTransferUnlocked} so the optional legacy hook contribution
 *             is added; `preWithdraw`/`preRedeem` call {_enforceRedeemAndConsumeTransferLock}
 *             (single cleanup + legacy drain, redeem check, then Reg-S lock consumption).
 *           - {REG_S_EXTENSION} immutable + {hardLockDuration} getter / {setHardLockDuration}
 *             setter that validate `> 0`.
 *           - Successor / legacy migration: {legacyHook} (settable at construction time
 *             only, owner-disconnectable via {disconnectLegacyHook}), {successorHook},
 *             {drainAndGetLocked}. **Single-hop only:** before each new migration the
 *             immediate predecessor hook must have no residual locks (full
 *             `hardLockDuration + REG_S_EXTENSION` elapsed since it left the container,
 *             then {disconnectLegacyHook} so `legacyHook == address(0)` on that predecessor).
 *           - View surface oriented to the Reg S semantics
 *             (`effectiveTransferLocked`, `effectiveRedeemLocked`, etc.).
 *
 *         What this contract **closes** from the base:
 *           - {setDepositLockDuration} is overridden to always revert: the Reg-S
 *             derivative manages the underlying slot via {setHardLockDuration} so that
 *             the invariants `hardLockDuration > 0` and
 *             `depositLockDuration == hardLockDuration + REG_S_EXTENSION` are preserved
 *             by construction.
 *
 *         ## Queue ordering — sorted by `unlockTimestamp`
 *
 *         `REG_S_EXTENSION` is immutable, so for every lock `i`:
 *
 *             unlockTimestamp_i = redeemUnlockTimestamp_i + REG_S_EXTENSION   (constant)
 *
 *         Sorting by `unlockTimestamp` is therefore equivalent to sorting by the implicit
 *         `redeemUnlockTimestamp`, which guarantees that the entries still contributing
 *         to the redeem-locked aggregate form a contiguous **suffix** of `_locks[user]`, with
 *         the Reg-S middle window forming the contiguous block before the hard-lock suffix.
 *
 *         ## Inherited side-effects worth noting
 *
 *           - The base emits `DepositLockDurationSet(0, hardLockDuration + REG_S_EXTENSION)`
 *             from its constructor. In Reg-S semantics this represents the transfer-unlock
 *             total, not the hard lock. This contract additionally emits
 *             `HardLockDurationSet(0, hardLockDuration)` so off-chain indexers can consume
 *             a Reg-S-canonical event.
 *           - The base's `LockCreated(user, shares, unlockTimestamp, duration)` is emitted
 *             on every deposit/mint. Indexers can derive the redeem unlock instant as
 *             `unlockTimestamp - REG_S_EXTENSION` (the extension is queryable from the
 *             public immutable getter).
 *           - `depositLockDuration()` (inherited getter) returns `hardLockDuration + REG_S_EXTENSION`.
 *             Use {hardLockDuration} for the Reg-S-canonical value.
 */
contract DepositLockRegSHook is DepositLockHook, IDepositLockRegSHook {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors (Reg-S-specific only — common errors are inherited from the base)
    // ─────────────────────────────────────────────────────────────────────────────

    error OnlySuccessorHook();
    error ZeroHardLockDuration();
    error InsufficientTransferUnlocked(address account, uint256 requested, uint256 unlocked);
    error InsufficientRedeemUnlocked(address account, uint256 requested, uint256 unlocked);
    error LegacyHookVaultMismatch(address legacy, address legacyVault, address expected);
    /// @dev Raised when callers invoke the inherited {setDepositLockDuration}; the Reg-S
    ///      derivative requires {setHardLockDuration} as the sole entrypoint to keep the
    ///      `depositLockDuration = hardLockDuration + REG_S_EXTENSION` invariant intact.
    error UseSetHardLockDuration();
    /// @dev Raised when {disconnectLegacyHook} is invoked but the slot already holds
    ///      `address(0)` — either the contract was deployed without a legacy or the
    ///      legacy has been disconnected previously. The slot is monotonically
    ///      downgradeable, so there is no upgrade path back from the zero state.
    error NoLegacyToDisconnect();
    /// @dev Raised when the bound vault still allows cancelling pending withdrawal requests.
    ///      A vault that permits cancellation lets a user request a redeem (consuming the
    ///      Reg-S transfer lock) and then cancel it, recovering the shares now unlocked and
    ///      bypassing the transfer restriction. The hook therefore refuses to initialize or
    ///      operate unless cancellation is disabled on the vault.
    error CancellationEnabled();
    /// @dev Raised when the inherited base `initialize(address,uint64)` is called on a
    ///      Reg-S clone. Reg-S clones must be configured through the 4-arg initializer so
    ///      that `REG_S_EXTENSION` / `legacyHook` are set; using the base overload would
    ///      consume the one-shot `initializer` slot and leave that state at defaults
    ///      permanently.
    error UseDerivedInitializer();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events (Reg-S-specific only — `LockCreated`, `MaxLocksPerUserSet`,
    // `HookContainerSet`, `DepositLockDurationSet` are inherited from the base)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Emitted whenever the Reg-S hard-lock duration is set (constructor + setter).
    ///         The base also emits its own `DepositLockDurationSet` with the *transfer*
    ///         unlock total; Reg-S indexers should consume this event for the canonical
    ///         hard-lock value.
    event HardLockDurationSet(uint64 previousDuration, uint64 newDuration);
    event SuccessorHookSet(address previousSuccessor, address newSuccessor);
    event LegacyHookDrained(address indexed user, uint256 transferLocked, uint256 redeemLocked);
    /// @notice Emitted by {disconnectLegacyHook}. After this event fires, `legacyHook`
    ///         reads as `address(0)` and every enforcement / view path skips the legacy
    ///         contribution. The transition is one-way; the slot cannot be repopulated.
    event LegacyHookDisconnected(address previousLegacyHook);

    // ─────────────────────────────────────────────────────────────────────────────
    // Immutables & config
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Reg S extension applied on top of `hardLockDuration` to derive each lock's
    ///         transfer-unlock timestamp. Set once in `initialize` and never mutated afterwards
    ///         (semantically immutable) so that every lock's implicit
    ///         `redeemUnlockTimestamp = unlockTimestamp - REG_S_EXTENSION` is well defined
    ///         uniformly across the queue and the queue sort by `unlockTimestamp` doubles
    ///         as a sort by `redeemUnlockTimestamp`. Changing the Reg S window requires
    ///         deploying a new hook and migrating through the {successorHook} / {legacyHook}
    ///         pattern.
    /// @dev Lives in storage rather than as an `immutable` so the contract can be deployed
    ///      behind an ERC-1167 minimal-proxy clone, whose constructor never runs.
    uint64 public REG_S_EXTENSION;

    /// @notice Immediate predecessor hook drained on demand during migration (single hop).
    ///         `address(0)` means no predecessor or {disconnectLegacyHook} was called after
    ///         the predecessor's lock period elapsed. This slot is **not** walked recursively;
    ///         before deploying a later hook (v3), v2 must call {disconnectLegacyHook} once v1
    ///         is empty so v2 does not still point at v1.
    /// @dev    Mutability is intentionally one-way (downgrade-only): the constructor sets
    ///         the slot and {disconnectLegacyHook} is the only post-deploy write path,
    ///         and it can only move the slot to `address(0)`. This preserves the
    ///         "v1 ≡ this.legacyHook" identity contract (no silent re-routing to a
    ///         different predecessor) while letting the owner stop paying the external
    ///         call once v1 is provably drained.
    IDepositLockRegSHook public legacyHook;

    /// @notice Future hook authorized to call {drainAndGetLocked}. `address(0)` (default)
    ///         disables the drain entrypoint.
    address public successorHook;

    // ─────────────────────────────────────────────────────────────────────────────
    // Modifier
    // ─────────────────────────────────────────────────────────────────────────────

    modifier onlySuccessorHook() {
        address successor = successorHook;
        if (successor == address(0) || msg.sender != successor) revert OnlySuccessorHook();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /// @param owner_ Initial owner authorized to manage admin parameters.
    /// @dev Vault address is supplied as immutable arg at clone time, not via initialize.
    /// @param hardLockDuration_ Initial hard-lock duration (must be strictly positive).
    /// @param regSExtension_ Reg S extension added on top of the hard lock.
    /// @param legacyHook_ Predecessor `DepositLockRegSHook` to drain on enforcement, or
    ///                    `address(0)` if this is the first deployment for the vault.
    /// @dev   The base's `depositLockDuration` slot is initialised with the *transfer*
    ///        unlock total (`hardLockDuration_ + regSExtension_`). Solidity 0.8+ reverts
    ///        with a `Panic(0x11)` if the sum overflows `uint64`, so the value passed to
    ///        the base is always safe.
    /// @dev Vault address is supplied as an immutable arg at clone time, not via initialize.
    function initialize(address owner_, uint64 hardLockDuration_, uint64 regSExtension_, address legacyHook_)
        external
        virtual
        initializer
    {
        __DepositLockHook_init(owner_, hardLockDuration_ + regSExtension_);

        if (hardLockDuration_ == 0) revert ZeroHardLockDuration();

        REG_S_EXTENSION = regSExtension_;
        _validateSameVault(legacyHook_, VAULT());
        legacyHook = IDepositLockRegSHook(legacyHook_);

        _requireCancellationDisabled();

        emit HardLockDurationSet(0, hardLockDuration_);
    }

    /// @notice Disabled in the Reg-S derivative. Use the 4-arg `initialize` instead.
    /// @dev Overrides the inherited base initializer so a clone cannot be initialized
    ///      through the base overload — which would consume the one-shot `initializer`
    ///      slot and leave `REG_S_EXTENSION` / `legacyHook` at defaults permanently. The
    ///      `initializer` modifier is intentionally dropped so the informative revert
    ///      always fires instead of a generic already-initialized error.
    function initialize(address, uint64) external pure override {
        revert UseDerivedInitializer();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    function FLAVOUR() public pure virtual override(DepositLockHook) returns (uint256) {
        return 6; // DepositLockRegSHook
    }

    function VERSION() public pure virtual override(DepositLockHook) returns (uint256, uint256, uint256) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin — Reg-S-specific
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Disabled in the Reg-S derivative. Use {setHardLockDuration} instead.
    /// @dev    Always reverts with {UseSetHardLockDuration}. Overrides the base's
    ///         `external virtual onlyOwner` setter so the
    ///         `depositLockDuration == hardLockDuration + REG_S_EXTENSION` invariant
    ///         cannot be silently broken by setting the underlying slot to an arbitrary
    ///         value. The `onlyOwner` modifier is intentionally dropped so non-owner
    ///         callers see the informative revert reason instead of an access-control
    ///         error.
    function setDepositLockDuration(uint64) external pure override {
        revert UseSetHardLockDuration();
    }

    /// @notice Updates the hard-lock duration applied to *new* deposits/mints. Existing
    ///         locks are not rewritten. Must be strictly positive.
    /// @dev    Maintains the base's `depositLockDuration = hardLockDuration + REG_S_EXTENSION`
    ///         invariant. Reverts on `uint64` overflow of the sum. Emits both the inherited
    ///         {DepositLockDurationSet} (with the *transfer*-unlock total, mirroring the
    ///         base constructor) and the Reg-S-canonical {HardLockDurationSet} so indexers
    ///         consuming either event see every update.
    function setHardLockDuration(uint64 newDuration) external onlyOwner {
        if (newDuration == 0) revert ZeroHardLockDuration();
        uint64 regS = REG_S_EXTENSION;
        // Solidity 0.8+ reverts on overflow of the `uint64 + uint64` sum.
        uint64 newTotal = newDuration + regS;
        uint64 previousTotal = uint64(depositLockDuration);
        uint64 previousHard = previousTotal - regS;
        depositLockDuration = newTotal;
        emit DepositLockDurationSet(previousTotal, newTotal);
        emit HardLockDurationSet(previousHard, newDuration);
    }

    /// @notice Hard-lock duration applied to new deposits, in seconds. The full lock
    ///         duration is `hardLockDuration() + REG_S_EXTENSION`.
    function hardLockDuration() external view returns (uint64) {
        return uint64(depositLockDuration) - REG_S_EXTENSION;
    }

    /// @notice Sets the future hook authorized to call {drainAndGetLocked}.
    /// @dev    If `newSuccessor != address(0)`, the address must point at a hook bound to
    ///         the same vault.
    function setSuccessorHook(address newSuccessor) external onlyOwner {
        _validateSameVault(newSuccessor, VAULT());
        address previous = successorHook;
        successorHook = newSuccessor;
        emit SuccessorHookSet(previous, newSuccessor);
    }

    /// @notice Permanently disconnects the configured legacy hook. After the call,
    ///         enforcement and view paths skip the external call to the predecessor and
    ///         the legacy contribution reads as zero.
    /// @dev    Downgrade-only: callable only by the owner, reverts when there is nothing
    ///         to disconnect, and writes `address(0)` to the `legacyHook` slot with no
    ///         re-population path. The owner is expected to call this only after every
    ///         lock that ever existed on the predecessor has fully expired
    ///         (`hardLockDuration_v1 + regSExtension_v1` after v1's last `LockCreated`).
    ///         Disconnecting earlier silently frees any residual v1 locks for transfer /
    ///         redeem on this hook; the trade-off is explicit and logged via
    ///         {LegacyHookDisconnected}. Once a vault has reached this state, a
    ///         subsequent migration `v2 → v3` is safe to perform without cascading the
    ///         legacy aggregate through more than one hop, because v3's `legacyHook`
    ///         (== v2) no longer consults any predecessor.
    function disconnectLegacyHook() external onlyOwner {
        address previous = address(legacyHook);
        if (previous == address(0)) revert NoLegacyToDisconnect();
        legacyHook = IDepositLockRegSHook(address(0));
        emit LegacyHookDisconnected(previous);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views — Reg-S aliases (delegate to base internals or compute on the fly)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Raw stored transfer-locked aggregate. Reg-S alias for the base's
    ///         `storedTotalLocked` (same underlying mapping).
    function storedTransferLocked(address user) external view returns (uint256) {
        return _totalLocked[user];
    }

    /// @notice Derives the redeem-unlock timestamp of the lock at `index`. Equivalent to
    ///         `getStoredLock(user, index).unlockTimestamp - REG_S_EXTENSION`.
    function getStoredLockRedeemUnlockTimestamp(address user, uint256 index) external view returns (uint64) {
        return _locks[user][index].unlockTimestamp - REG_S_EXTENSION;
    }

    /// @inheritdoc IDepositLockRegSHook
    function effectiveTransferLocked(address user) external view override returns (uint256) {
        return _effectiveTotalLocked(user);
    }

    /// @inheritdoc IDepositLockRegSHook
    function effectiveRedeemLocked(address user) external view override returns (uint256) {
        return _effectiveRedeemLocked(user);
    }

    /// @notice Free-to-transfer shares for `user`, accounting for both the local effective
    ///         transfer-locked total and any contribution from the configured legacy hook.
    function getUnlockedTransferShares(address user) external view returns (uint256) {
        (uint256 legacyTransfer,) = _legacyEffective(user);
        return _unlockedShares(user, _effectiveTotalLocked(user) + legacyTransfer);
    }

    /// @notice Free-to-redeem shares for `user`, accounting for both the local effective
    ///         redeem-locked total and any contribution from the configured legacy hook.
    function getUnlockedRedeemShares(address user) external view returns (uint256) {
        (, uint256 legacyRedeem) = _legacyEffective(user);
        return _unlockedShares(user, _effectiveRedeemLocked(user) + legacyRedeem);
    }

    /// @notice Residual effective contributions read from the configured legacy hook.
    ///         Zero when no legacy hook is set.
    function legacyContribution(address user)
        external
        view
        returns (uint256 legacyTransferLocked, uint256 legacyRedeemLocked)
    {
        return _legacyEffective(user);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // IHook overrides — enforcement with optional legacy drain
    // ─────────────────────────────────────────────────────────────────────────────

    function preTransfer(address, address from, address, uint256 shares)
        public
        override(DepositLockHook, IHook)
        onlyVaultOrHookContainer
    {
        _requireTransferUnlocked(from, shares);
    }

    function preWithdraw(address, uint256, uint256 shares, address, address owner, uint256)
        public
        override(DepositLockHook, IHook)
        onlyVaultOrHookContainer
    {
        _enforceRedeemAndConsumeTransferLock(owner, shares);
    }

    function preRedeem(address, uint256, uint256 shares, address, address owner, uint256)
        public
        override(DepositLockHook, IHook)
        onlyVaultOrHookContainer
    {
        _enforceRedeemAndConsumeTransferLock(owner, shares);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Migration entrypoint
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDepositLockRegSHook
    /// @dev Runs `_cleanupExpired`, optionally {_consumeRegSRange} when `regSSharesToConsume > 0`,
    ///      then returns post-update aggregates for **this** hook only. Does **not** walk
    ///      `legacyHook.legacyHook()`. Operators must call {disconnectLegacyHook} on the
    ///      immediate predecessor once that hook's lock period has elapsed before wiring a
    ///      further migration (see file-level NatSpec / spec §6).
    function drainAndGetLocked(address user, uint256 regSSharesToConsume)
        external
        override
        onlySuccessorHook
        returns (uint256 transferLocked, uint256 redeemLocked, uint256 regSConsumed)
    {
        _cleanupExpired(user);
        regSConsumed = 0;
        if (regSSharesToConsume > 0) {
            (uint256 regSEnd,) = _activeLockSegments(user);
            regSConsumed = _consumeRegSRange(user, regSEnd, regSSharesToConsume);
        }
        transferLocked = _totalLocked[user];
        redeemLocked = _effectiveRedeemLocked(user);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal — enforcement
    // ─────────────────────────────────────────────────────────────────────────────

    function _requireTransferUnlocked(address user, uint256 shares) internal {
        if (shares == 0) return;
        _requireCancellationDisabled();
        _cleanupExpired(user);
        (uint256 legacyTransfer,,) = _legacyDrain(user, 0);
        uint256 unlocked = _unlockedShares(user, _totalLocked[user] + legacyTransfer);
        if (shares > unlocked) revert InsufficientTransferUnlocked(user, shares, unlocked);
    }

    /// @dev Redeem/withdraw: cleanup, legacy drain for check, segment scan, unlock check, consume.
    function _enforceRedeemAndConsumeTransferLock(address user, uint256 shares) internal {
        if (shares == 0) return;
        _requireCancellationDisabled();
        _cleanupExpired(user);

        uint256 legacyTransfer;
        uint256 legacyRedeem;
        if (address(legacyHook) != address(0)) {
            (legacyTransfer, legacyRedeem,) = _legacyDrain(user, 0);
        }

        (uint256 regSEnd, uint256 redeemLocked) = _activeLockSegments(user);

        uint256 balance = IERC4626(VAULT()).balanceOf(user);
        uint256 redeemLockedTotal = redeemLocked + legacyRedeem;
        uint256 redeemUnlocked = balance > redeemLockedTotal ? balance - redeemLockedTotal : 0;
        if (shares > redeemUnlocked) revert InsufficientRedeemUnlocked(user, shares, redeemUnlocked);

        // Transfer-unlocked shares are burned first; only the remainder reduces Reg-S locks.
        uint256 transferLocked = _totalLocked[user] + legacyTransfer;
        uint256 transferFree = balance > transferLocked ? balance - transferLocked : 0;
        uint256 lockBurn = shares > transferFree ? shares - transferFree : 0;
        if (lockBurn == 0) return;

        uint256 legacyConsumed;
        if (address(legacyHook) != address(0)) {
            uint256 legacyLockBurn = lockBurn > legacyTransfer ? legacyTransfer : lockBurn;
            (,, legacyConsumed) = _legacyDrain(user, legacyLockBurn);
        }

        _consumeRegSRange(user, regSEnd, lockBurn - legacyConsumed);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal — shared helpers (legacy interaction, balance math, vault check)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Reverts with {CancellationEnabled} when the bound vault still allows cancelling
    ///      pending withdrawal requests. Enforced at initialize time and on every enforcement
    ///      path (transfer / withdraw / redeem) so the hook never operates while the
    ///      request-then-cancel bypass is reachable. `cancellationEnabled()` is exposed by every
    ///      vault through the base interface — synchronous vaults have no cancellation flow and
    ///      report `false`, so the guard is a no-op for them; async vaults must have cancellation
    ///      disabled (via `configure`) for the guard to pass. No vault-type detection is needed:
    ///      a single unconditional call covers both cases safely.
    function _requireCancellationDisabled() private view {
        if (IVaultCancellationConfig(VAULT()).cancellationEnabled()) {
            revert CancellationEnabled();
        }
    }

    /// @dev Drains the legacy hook (state-changing, also advances v1 cleanup) and emits
    ///      {LegacyHookDrained}. Returns `(0, 0)` early when no legacy is configured (or
    ///      has been disconnected) so the call sites can read either axis from the
    ///      returned tuple without an additional `legacyHook == address(0)` check.
    function _legacyDrain(address user, uint256 regSSharesToConsume)
        private
        returns (uint256 legacyTransfer, uint256 legacyRedeem, uint256 regSConsumed)
    {
        IDepositLockRegSHook legacy = legacyHook;
        if (address(legacy) == address(0)) return (0, 0, 0);
        (legacyTransfer, legacyRedeem, regSConsumed) = legacy.drainAndGetLocked(user, regSSharesToConsume);
        emit LegacyHookDrained(user, legacyTransfer, legacyRedeem);
    }

    /// @dev View-only counterpart to {_legacyDrain} for read paths (`getUnlocked*Shares`,
    ///      `legacyContribution`). Single hop: the direct {legacyHook} only.
    function _legacyEffective(address user) private view returns (uint256 legacyTransfer, uint256 legacyRedeem) {
        IDepositLockRegSHook legacy = legacyHook;
        if (address(legacy) == address(0)) return (0, 0);
        legacyTransfer = legacy.effectiveTransferLocked(user);
        legacyRedeem = legacy.effectiveRedeemLocked(user);
    }

    /// @dev Single source of truth for the free-balance computation
    ///      `max(VAULT().balanceOf(user) − locked, 0)` used by both enforcement paths and
    ///      the `getUnlocked*Shares` views.
    function _unlockedShares(address user, uint256 locked) private view returns (uint256) {
        uint256 balance = IERC4626(VAULT()).balanceOf(user);
        return balance > locked ? balance - locked : 0;
    }

    /// @dev Reverts with {LegacyHookVaultMismatch} when `hookAddr` is non-zero and is
    ///      bound to a vault other than `expectedVault`. No-op when `hookAddr` is the
    ///      zero address. Used both at construction time (legacy hook) and at runtime
    ///      (successor hook).
    function _validateSameVault(address hookAddr, address expectedVault) private view {
        if (hookAddr == address(0)) return;
        address hookVault = IDepositLockRegSHook(hookAddr).VAULT();
        if (hookVault != expectedVault) revert LegacyHookVaultMismatch(hookAddr, hookVault, expectedVault);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal — sorted queue: Reg-S prefix + hard-lock suffix
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev After `_cleanupExpired`, returns `regSEnd` (first hard-lock index) and `redeemLocked`
    ///      (hard-lock suffix share sum). Reg S is `[0, regSEnd)`.
    function _activeLockSegments(address user) private view returns (uint256 regSEnd, uint256 redeemLocked) {
        Lock[] storage locks = _locks[user];
        uint256 len = locks.length;
        if (len == 0) return (0, 0);

        uint256 regSEndTs = block.timestamp + uint256(REG_S_EXTENSION);
        uint256 i;
        while (i < len && uint256(locks[i].unlockTimestamp) <= regSEndTs) {
            unchecked {
                i++;
            }
        }
        regSEnd = i;

        for (uint256 j = regSEnd; j < len;) {
            redeemLocked += locks[j].shares;
            unchecked {
                j++;
            }
        }
    }

    /// @dev Consumes up to `shares` from `[0, regSEnd)`. REQUIRE: `_cleanupExpired(user)` already ran.
    ///      Invariant after cleanup: every lock in `[0, regSEnd)` is active with `shares > 0`, and
    ///      consumption is strictly contiguous from index 0. Therefore the loop counter `i` doubles
    ///      as the length of the fully-consumed prefix to drop — no per-entry zeroing or separate
    ///      counter is needed.
    function _consumeRegSRange(address user, uint256 regSEnd, uint256 shares) private returns (uint256 consumed) {
        if (shares == 0 || regSEnd == 0) return 0;

        Lock[] storage locks = _locks[user];
        uint256 remaining = shares;
        uint256 i;

        for (; i < regSEnd && remaining > 0;) {
            uint128 lockShares = locks[i].shares;
            uint256 take = remaining < lockShares ? remaining : uint256(lockShares);

            _totalLocked[user] -= take;
            remaining -= take;
            consumed += take;

            if (take < lockShares) {
                // Partial consumption: this entry survives and the prefix ends here.
                locks[i].shares = lockShares - uint128(take);
                break;
            }

            // Fully consumed: part of the contiguous prefix removed below.
            unchecked {
                i++;
            }
        }

        if (i > 0) {
            _removePrefix(user, i);
        }
    }

    function _effectiveRedeemLocked(address user) internal view returns (uint256) {
        (, uint256 redeemLocked) = _activeLockSegments(user);
        return redeemLocked;
    }
}
