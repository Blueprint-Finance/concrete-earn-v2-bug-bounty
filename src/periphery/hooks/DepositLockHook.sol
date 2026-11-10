// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseOwnableHook} from "./BaseOwnableHook.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

/**
 * @title DepositLockHook
 * @notice Time-locks vault shares minted via deposit/mint: locked shares cannot be transferred, withdrawn, or redeemed
 *         until each lock's unlock timestamp. One hook deployment per vault.
 *
 * @dev Shares stay in user wallets; enforcement is via this contract's accounting + vault hooks.
 *      Minimum deposit / dust limits are expected to be enforced by the vault (or another hook), not here.
 *
 *      ## Sorted insertion — locks ordered by `unlockTimestamp`
 *
 *      `_appendLock` inserts each new lock at its sorted position so that `unlockTimestamp`
 *      values are always non-decreasing. When `depositLockDuration` is unchanged or increases,
 *      the new lock naturally goes to the end (O(1) fast path). When it decreases, the new
 *      lock is inserted earlier via a rightward shift — O(k) SSTOREs where k is the number of
 *      entries that expire after the new one, bounded by `maxLocksPerUser`.
 *
 *      Because the array is always sorted, expired locks form a contiguous prefix, enabling:
 *        - Prefix-removal in `_cleanupExpired` (no full scan needed).
 *        - Early-break in view functions (`effectiveLockCount`, `_effectiveTotalLocked`).
 *        - Earliest-expiring-first consumption in extension contracts (e.g. early unlock).
 *
 *      ## `_totalLocked` invariant
 *
 *      `_totalLocked[user]` must equal the sum of `shares` across all entries in `_locks[user]`
 *      after `_cleanupExpired` runs. It may overcount until `_cleanupExpired` is executed,
 *      because expired-but-not-yet-cleaned locks are still included. It is incremented only in
 *      `_appendLock` (lock creation) and decremented only in `_cleanupExpired` (lock expiration).
 *      No other code path may modify it. Future extensions (e.g. early unlock with fee) that
 *      consume or reduce locks must update `_totalLocked` in lockstep to preserve this invariant.
 *
 *      ## Cleanup and compaction
 *
 *      `_cleanupExpired` removes the expired prefix, subtracts their shares from
 *      `_totalLocked`, shifts active entries to index 0, and pops excess slots.
 *      After it returns, `_locks[user].length` equals the number of active (non-expired)
 *      locks sorted by `unlockTimestamp`. Between mutating calls, the stored length may
 *      still include expired-but-not-yet-cleaned entries. Cost is O(expired) reads +
 *      O(active) writes, bounded by `maxLocksPerUser`.
 *
 *      ## Config edge cases
 *
 *        - `depositLockDuration == 0`: no lock is created — shares are immediately free. This is
 *          the canonical way to disable locking for new deposits without redeploying the hook.
 *        - `hookContainer == address(0)`: only the vault itself can call mutating hooks. This is
 *          the default and is a valid configuration (no container).
 *
 *      ## Part 2 (early unlock fee)
 *
 *      `Lock.duration` is stored at creation time so a future extension can compute linear fee
 *      decay (`fee = shares * maxFee * (unlockTimestamp - now) / duration`) per lock without
 *      guessing the duration that applied when the lock was created.
 *
 *      ## Known limitations
 *
 *        - **O(n) sorted insertion:** when `depositLockDuration` is reduced, `_appendLock` may
 *          shift up to n existing entries to maintain sorted order. Cost is bounded by
 *          `maxLocksPerUser` and is O(1) when the duration is unchanged or increases.
 *        - **Not ordered by creation time:** locks are ordered by `unlockTimestamp`, not by
 *          deposit chronology. Consumers that assume creation-time ordering will see unexpected
 *          results after a `depositLockDuration` decrease.
 *        - **Cleanup dependency:** `_cleanupExpired` must run before any mutating operation
 *          that reads `_totalLocked` or iterates `_locks`. Callers that bypass cleanup will
 *          observe stale expired entries and an overcounted `_totalLocked`.
 */
contract DepositLockHook is BaseOwnableHook {
    // ─────────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────────

    /// @param shares Amount of shares covered by this lock (remaining until expiry / future partial unlock)
    /// @param unlockTimestamp Absolute time when the lock releases if no early-unlock fee path is used
    /// @param duration Snapshot of `depositLockDuration` at lock creation (Part 2 fee decay)
    struct Lock {
        uint128 shares;
        uint64 unlockTimestamp;
        uint64 duration;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error OnlyVaultOrHookContainer();
    error ZeroMaxLocks();
    error MaxLocksPerUserAboveCeiling(uint256 requested, uint256 ceiling);
    error InsufficientUnlocked(address account, uint256 requested, uint256 unlocked);
    error MaxLocksExceeded(address user, uint256 current, uint256 maxLocks);
    error UnlockTimestampOverflow();
    error SharesOverflow();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event DepositLockDurationSet(uint64 previousDuration, uint64 newDuration);
    event MaxLocksPerUserSet(uint256 previousMax, uint256 newMax);
    event HookContainerSet(address previousContainer, address newContainer);
    event LockCreated(address indexed user, uint256 shares, uint64 unlockTimestamp, uint64 duration);

    // ─────────────────────────────────────────────────────────────────────────────
    // Config
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Hard upper bound on `maxLocksPerUser` enforced by `setMaxLocksPerUser`.
    /// @dev Sized so the worst-case O(N) per-user paths (`_cleanupExpired`, `_removePrefix`,
    ///      sorted-insert in `_appendLock`) stay well under the block gas limit on every
    ///      supported chain, leaving ample margin (~30x on a 30M block — empirical worst-case
    ///      sorted-insert at this ceiling measures under 1M gas) so a user can always exit
    ///      their position in a single transaction. Also caps the cross-user griefing surface
    ///      where a third party fills a victim's lock slots via on-behalf-of deposits: even at
    ///      the ceiling, post-expiry cleanup of all N slots fits in one tx.
    uint256 public constant MAX_LOCKS_PER_USER_CEILING = 500;

    /// @notice Duration added to `block.timestamp` for new locks. 0 disables locking for new deposits.
    uint64 public depositLockDuration;

    /// @notice Maximum number of *active* (non-expired) lock records per user.
    /// @dev Expired locks are removed during `_cleanupExpired`, so only active locks count toward
    ///      this cap. Checked in `_appendLock` after cleanup. Defaults to 10. Must always be
    ///      `0 < maxLocksPerUser <= MAX_LOCKS_PER_USER_CEILING`: `setMaxLocksPerUser(0)` reverts
    ///      with `ZeroMaxLocks` to prevent unbounded array growth, and values above the ceiling
    ///      revert with `MaxLocksPerUserAboveCeiling` so the O(N) per-user lock operations stay
    ///      below the block gas limit with a comfortable safety margin.
    /// @dev Defaulted to 10 inside `initialize` (not via an inline field initializer, which would
    ///      not run for ERC-1167 clones).
    uint256 public maxLocksPerUser;

    /// @notice Address of the HookContainer that forwards vault hook calls. `address(0)` = vault-only.
    /// @dev Fully trusted: it can create locks (via `postDeposit`/`postMint`) and trigger
    ///      enforcement paths (via `preTransfer`/`preWithdraw`/`preRedeem`) with the same
    ///      authority as the vault. The owner must ensure the container preserves the same call
    ///      semantics and invariants as a direct vault invocation.
    address public hookContainer;

    // ─────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Cached sum of `shares` across all entries in `_locks[user]`. Equals the sum exactly
    ///      after `_cleanupExpired` runs; may overcount until `_cleanupExpired` is executed because
    ///      expired-but-not-yet-cleaned locks are still included. Modified only in `_appendLock`
    ///      (increment on lock creation) and `_cleanupExpired` (decrement on lock expiration).
    ///      Future extensions that consume locks (e.g. early unlock) must update this in lockstep.
    mapping(address user => uint256 totalLocked) internal _totalLocked;

    /// @dev Sorted queue of lock records (non-decreasing `unlockTimestamp`). After
    ///      `_cleanupExpired` runs the array contains only active locks starting at index 0.
    ///      Sorted order is maintained by `_appendLock` via sorted insertion.
    mapping(address user => Lock[] queue) internal _locks;

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor & initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Initializes a freshly-deployed clone of this hook.
    /// @param owner_ Address granted ownership of the hook.
    /// @param initialLockDuration_ Initial lock duration applied to new deposits. 0 disables locking.
    /// @dev Vault address is supplied as an immutable arg at clone time, not via initialize.
    function initialize(address owner_, uint64 initialLockDuration_) external virtual initializer {
        __DepositLockHook_init(owner_, initialLockDuration_);
    }

    /// @dev Shared initialization logic invoked by this contract's `initialize` and by the
    ///      initializers of derived hooks. Sets the owner, configures the initial lock duration
    ///      and applies the `maxLocksPerUser` default.
    function __DepositLockHook_init(address owner_, uint64 initialLockDuration_) internal onlyInitializing {
        __BaseOwnableHook_init(owner_);
        maxLocksPerUser = 10;
        depositLockDuration = initialLockDuration_;
        emit DepositLockDurationSet(0, initialLockDuration_);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 4; // DepositLockHook
    }

    function VERSION() public pure virtual override returns (uint256, uint256, uint256) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Updates the lock duration for deposits/mints executed after this call. Existing locks unchanged.
    function setDepositLockDuration(uint64 newDuration) external virtual onlyOwner {
        uint64 previous = depositLockDuration;
        depositLockDuration = newDuration;
        emit DepositLockDurationSet(previous, newDuration);
    }

    /// @notice Updates the cap on active lock entries per user. Reverts on `0`
    ///         (`ZeroMaxLocks`) and on values above `MAX_LOCKS_PER_USER_CEILING`
    ///         (`MaxLocksPerUserAboveCeiling`) so the per-user O(N) lock paths stay
    ///         below the block gas limit even under adversarial slot-fill scenarios.
    function setMaxLocksPerUser(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert ZeroMaxLocks();
        if (newMax > MAX_LOCKS_PER_USER_CEILING) {
            revert MaxLocksPerUserAboveCeiling(newMax, MAX_LOCKS_PER_USER_CEILING);
        }
        uint256 previous = maxLocksPerUser;
        maxLocksPerUser = newMax;
        emit MaxLocksPerUserSet(previous, newMax);
    }

    function setHookContainer(address container) external onlyOwner {
        address previous = hookContainer;
        hookContainer = container;
        emit HookContainerSet(previous, container);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views — stored (raw storage, may include expired entries)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Raw stored total locked shares. Does NOT account for expired locks.
    /// @dev Use `effectiveTotalLocked` for the post-expiry value.
    function storedTotalLocked(address user) external view returns (uint256) {
        return _totalLocked[user];
    }

    /// @notice Number of stored lock entries. May include expired-but-not-yet-cleaned entries.
    /// @dev After `_cleanupExpired` runs this equals the active count; before that it may overcount.
    function storedLockCount(address user) external view returns (uint256) {
        return _locks[user].length;
    }

    /// @notice Returns the raw stored lock at `index`. May be expired; check `unlockTimestamp`.
    function getStoredLock(address user, uint256 index) external view returns (Lock memory) {
        return _locks[user][index];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views — effective (simulate expiry in memory)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Total locked shares after discounting all expired locks.
    /// @dev Breaks at the first non-expired entry (sorted array). Intended for off-chain / UI reads.
    function effectiveTotalLocked(address user) external view returns (uint256) {
        return _effectiveTotalLocked(user);
    }

    /// @notice Number of locks that are still active (not expired).
    /// @dev Breaks at the first non-expired entry (sorted array: expired entries are a prefix).
    function effectiveLockCount(address user) external view returns (uint256) {
        Lock[] storage locks = _locks[user];
        uint256 len = locks.length;
        uint256 now_ = block.timestamp;
        uint256 expired;
        for (uint256 i; i < len;) {
            if (now_ >= locks[i].unlockTimestamp) {
                unchecked {
                    expired++;
                    i++;
                }
            } else {
                break;
            }
        }
        return len - expired;
    }

    /// @notice Effective unlocked shares after simulating expiry of all expired locks.
    /// @dev Delegates to `_effectiveTotalLocked`. Intended for off-chain / UI reads.
    function getUnlockedShares(address user) external view returns (uint256) {
        uint256 balance = IERC4626(VAULT()).balanceOf(user);
        uint256 lockedAfterExpiry = _effectiveTotalLocked(user);
        return balance > lockedAfterExpiry ? balance - lockedAfterExpiry : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // IHook — deposit / mint (state)
    // ─────────────────────────────────────────────────────────────────────────────

    function postDeposit(address, uint256, uint256 shares, address receiver, uint256)
        public
        virtual
        override
        onlyVaultOrHookContainer
    {
        _appendLock(receiver, shares);
    }

    function postMint(address, uint256, uint256 shares, address receiver, uint256)
        public
        virtual
        override
        onlyVaultOrHookContainer
    {
        _appendLock(receiver, shares);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // IHook — transfer / withdraw / redeem (checks)
    // ─────────────────────────────────────────────────────────────────────────────

    function preTransfer(address, address from, address, uint256 shares)
        public
        virtual
        override
        onlyVaultOrHookContainer
    {
        _requireUnlocked(from, shares);
    }

    function preWithdraw(address, uint256, uint256 shares, address, address owner, uint256)
        public
        virtual
        override
        onlyVaultOrHookContainer
    {
        _requireUnlocked(owner, shares);
    }

    function preRedeem(address, uint256, uint256 shares, address, address owner, uint256)
        public
        virtual
        override
        onlyVaultOrHookContainer
    {
        _requireUnlocked(owner, shares);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────────

    modifier onlyVaultOrHookContainer() {
        if (msg.sender != VAULT() && msg.sender != hookContainer) revert OnlyVaultOrHookContainer();
        _;
    }

    function _appendLock(address user, uint256 shares) internal {
        uint64 duration = depositLockDuration;
        if (shares == 0 || duration == 0) return;

        _cleanupExpired(user);

        Lock[] storage locks = _locks[user];
        uint256 pending = locks.length;
        uint256 maxLocks = maxLocksPerUser;
        if (pending >= maxLocks) {
            revert MaxLocksExceeded(user, pending, maxLocks);
        }

        if (shares > type(uint128).max) revert SharesOverflow();

        uint256 rawUnlockTs = uint256(block.timestamp) + uint256(duration);
        if (rawUnlockTs > type(uint64).max) revert UnlockTimestampOverflow();
        uint64 unlockTs = uint64(rawUnlockTs);

        Lock memory newLock = Lock({shares: uint128(shares), unlockTimestamp: unlockTs, duration: duration});

        // Sorted insertion: maintain non-decreasing unlockTimestamp order.
        // Fast path (common case): new lock expires at or after the last entry.
        if (pending == 0 || unlockTs >= locks[pending - 1].unlockTimestamp) {
            locks.push(newLock);
        } else {
            locks.push(newLock);
            uint256 j = pending;
            while (j > 0 && locks[j - 1].unlockTimestamp > unlockTs) {
                locks[j] = locks[j - 1];
                unchecked {
                    j--;
                }
            }
            locks[j] = newLock;
        }

        _totalLocked[user] += shares;
        emit LockCreated(user, shares, unlockTs, duration);
    }

    /// @dev Removes the expired prefix. Because the array is sorted by `unlockTimestamp`
    ///      (maintained by `_appendLock`), all expired entries precede all active ones.
    ///      Subtracts expired shares from `_totalLocked`, shifts active entries to index 0,
    ///      and pops excess slots. Cost is O(expired) reads + O(active) writes, bounded by
    ///      `maxLocksPerUser`.
    function _cleanupExpired(address user) internal {
        Lock[] storage locks = _locks[user];
        uint256 len = locks.length;
        if (len == 0) return;

        uint256 now_ = block.timestamp;
        uint256 firstActive;
        while (firstActive < len && now_ >= locks[firstActive].unlockTimestamp) {
            _totalLocked[user] -= locks[firstActive].shares;
            unchecked {
                firstActive++;
            }
        }

        if (firstActive == 0) return;
        _removePrefix(user, firstActive);
    }

    /// @dev Shifts entries after `prefixLen` to index 0 and pops excess slots. Deletes the
    ///      entire array when `prefixLen == length`. Used by `_cleanupExpired` (base) and
    ///      `earlyUnlock` (extension) to avoid duplicating the shift-and-pop logic.
    function _removePrefix(address user, uint256 prefixLen) internal {
        Lock[] storage locks = _locks[user];
        uint256 len = locks.length;
        uint256 active = len - prefixLen;

        if (active == 0) {
            delete _locks[user];
        } else {
            for (uint256 i; i < active;) {
                locks[i] = locks[prefixLen + i];
                unchecked {
                    i++;
                }
            }
            for (uint256 i; i < prefixLen;) {
                locks.pop();
                unchecked {
                    i++;
                }
            }
        }
    }

    function _requireUnlocked(address owner, uint256 shares) internal {
        if (shares == 0) return;
        _cleanupExpired(owner);
        uint256 balance = IERC4626(VAULT()).balanceOf(owner);
        uint256 locked_ = _totalLocked[owner];
        uint256 unlocked = balance > locked_ ? balance - locked_ : 0;
        if (shares > unlocked) revert InsufficientUnlocked(owner, shares, unlocked);
    }

    /// @dev Breaks at the first non-expired entry (sorted array: expired entries are a prefix).
    ///      No storage writes.
    function _effectiveTotalLocked(address user) internal view returns (uint256) {
        Lock[] storage locks = _locks[user];
        uint256 len = locks.length;
        uint256 locked_ = _totalLocked[user];
        uint256 now_ = block.timestamp;

        for (uint256 i; i < len;) {
            if (now_ >= locks[i].unlockTimestamp) {
                locked_ -= locks[i].shares;
                unchecked {
                    i++;
                }
            } else {
                break;
            }
        }
        return locked_;
    }
}
