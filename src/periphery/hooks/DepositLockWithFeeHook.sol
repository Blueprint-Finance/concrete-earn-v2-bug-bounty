// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {DepositLockHook} from "./DepositLockHook.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

/**
 * @title DepositLockWithFeeHook
 * @notice Extends DepositLockHook: users may release locked shares before expiry by paying a
 *         time-decaying fee denominated in vault shares. Locks are ordered by `unlockTimestamp`
 *         (not by deposit chronology) — see `DepositLockHook` for details on sorted insertion.
 *
 * @dev ## Fee model (linear decay per lock)
 *
 *        fee = ⌈shares × maxEarlyUnlockFee × timeRemaining / (duration × FEE_BASIS)⌉
 *
 *      where `timeRemaining = unlockTimestamp − block.timestamp` and `duration` is the snapshot
 *      stored at lock creation. As the lock approaches natural expiry, `timeRemaining` → 0 and
 *      the fee decays linearly to zero. Ceiling rounding slightly favors the fee recipient.
 *
 *      ## Earliest-expiring-first consumption
 *
 *      `earlyUnlock` consumes locks front-to-back. Because the underlying array is sorted by
 *      `unlockTimestamp` (maintained by `DepositLockHook._appendLock`), this processes
 *      earliest-expiring locks first. When all locks share the same `duration` this is
 *      fee-optimal; when `depositLockDuration` has been changed, it provides a practical
 *      heuristic (see the fee-optimal ordering caveat on `earlyUnlock`). A lock may be
 *      partially consumed; its `shares` field is reduced in-place. Fully consumed locks are
 *      removed via `_removePrefix` (defined in `DepositLockHook`).
 *
 *      ## Fee collection
 *
 *      Fee shares are collected from `msg.sender` via `VAULT.transferFrom(user, feeRecipient, fee)`.
 *      The caller must have approved this contract for vault shares beforehand. The transfer
 *      triggers the vault's transfer hooks; since `_totalLocked` is already reduced before the
 *      external call (CEI), the hook's own `preTransfer` enforcement will pass.
 *
 *      ## Minimum lock period
 *
 *      `minLockPeriod` blocks early unlock during an initial window after lock creation.
 *      Creation time is derived as `unlockTimestamp − duration`. If the first lock to be
 *      consumed is still within `minLockPeriod`, the call reverts before reaching later
 *      locks — even if those later locks are themselves eligible. Natural expiry is unaffected.
 *
 *      `minLockPeriod` is a global parameter applied at unlock time. If updated after locks
 *      have already been created, older locks with shorter stored durations may become
 *      non-early-unlockable until natural expiry.
 *
 *      ## Edge cases
 *
 *        - `earlyUnlockEnabled == false`: `earlyUnlock` reverts. Toggle via `setEarlyUnlockEnabled`.
 *        - `maxEarlyUnlockFee == 0`: shares are unlocked with zero fee (free early exit).
 *          `feeRecipient` is not required in this case.
 *        - `feeRecipient == address(0)` (with `maxEarlyUnlockFee > 0`): `earlyUnlock` reverts.
 *        - `lock.duration == 0`: no lock is created when `depositLockDuration == 0`
 *          (`_appendLock` returns early), so division by zero in fee computation cannot occur.
 */
contract DepositLockWithFeeHook is DepositLockHook {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error ZeroSharesRequested();
    error NoFeeRecipient();
    error EarlyUnlockDisabled();
    error InsufficientLockedShares(address user, uint256 requested, uint256 available);
    error LockWithinMinPeriod(address user, uint256 lockIndex, uint256 timeUntilEligible);
    error MaxFeeExceedsBasis(uint256 fee, uint256 basis);
    error MinLockPeriodExceedsDuration(uint64 minPeriod, uint64 duration);
    /// @dev Raised when the inherited base `initialize(address,uint64)` is called on a
    ///      fee clone. Fee clones must be configured through the 5-arg initializer so that
    ///      the fee parameters are set; using the base overload would consume the one-shot
    ///      `initializer` slot and lock out the real initializer permanently.
    error UseDerivedInitializer();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event EarlyUnlock(address indexed user, uint256 sharesUnlocked, uint256 feeShares);
    event MaxEarlyUnlockFeeSet(uint256 previousFee, uint256 newFee);
    event MinLockPeriodSet(uint64 previousPeriod, uint64 newPeriod);
    event FeeRecipientSet(address previousRecipient, address newRecipient);
    event EarlyUnlockEnabledSet(bool enabled);

    // ─────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────

    uint256 public constant FEE_BASIS = 10_000;

    // ─────────────────────────────────────────────────────────────────────────────
    // Config
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Maximum fee in basis points (e.g. 500 = 5%). Applied at full remaining lock time.
    uint256 public maxEarlyUnlockFee;

    /// @notice Seconds after lock creation before early unlock is allowed. 0 = no restriction.
    uint64 public minLockPeriod;

    /// @notice Receives fee shares on early unlock. `address(0)` disables early unlock when `maxEarlyUnlockFee > 0`.
    address public feeRecipient;

    /// @notice Whether early unlock is enabled. When `false`, `earlyUnlock` reverts.
    bool public earlyUnlockEnabled;

    // ─────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Initializes a freshly-deployed clone of this hook.
    /// @dev See {DepositLockHook-initialize}. Adds the early-unlock fee configuration on top of
    ///      the base lock parameters.
    /// @dev Vault address is supplied as an immutable arg at clone time, not via initialize.
    function initialize(
        address owner_,
        uint64 initialLockDuration_,
        uint256 maxFee_,
        uint64 minLockPeriod_,
        address feeRecipient_
    ) external virtual initializer {
        __DepositLockHook_init(owner_, initialLockDuration_);

        if (maxFee_ > FEE_BASIS) revert MaxFeeExceedsBasis(maxFee_, FEE_BASIS);
        if (minLockPeriod_ > 0 && initialLockDuration_ > 0 && minLockPeriod_ >= initialLockDuration_) {
            revert MinLockPeriodExceedsDuration(minLockPeriod_, initialLockDuration_);
        }
        maxEarlyUnlockFee = maxFee_;
        minLockPeriod = minLockPeriod_;
        feeRecipient = feeRecipient_;
        emit MaxEarlyUnlockFeeSet(0, maxFee_);
        emit MinLockPeriodSet(0, minLockPeriod_);
        emit FeeRecipientSet(address(0), feeRecipient_);
    }

    /// @notice Disabled in the fee derivative. Use the 5-arg `initialize` instead.
    /// @dev Overrides the inherited base initializer so a clone cannot be initialized
    ///      through the base overload — which would consume the one-shot `initializer`
    ///      slot and leave the fee configuration at defaults while the real initializer
    ///      is permanently locked out. The `initializer` modifier is intentionally
    ///      dropped so the informative revert always fires.
    function initialize(address, uint64) external pure override {
        revert UseDerivedInitializer();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    function FLAVOUR() public pure virtual override(DepositLockHook) returns (uint256) {
        return 5; // DepositLockWithFeeHook
    }

    function VERSION() public pure virtual override(DepositLockHook) returns (uint256, uint256, uint256) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────────

    function setMaxEarlyUnlockFee(uint256 newFee) external onlyOwner {
        if (newFee > FEE_BASIS) revert MaxFeeExceedsBasis(newFee, FEE_BASIS);
        uint256 previous = maxEarlyUnlockFee;
        maxEarlyUnlockFee = newFee;
        emit MaxEarlyUnlockFeeSet(previous, newFee);
    }

    /// @notice Updates `minLockPeriod`.
    /// @dev The cross-parameter check `newPeriod >= depositLockDuration` is only enforced when
    ///      `depositLockDuration > 0`. While `depositLockDuration == 0` (locking disabled),
    ///      `minLockPeriod` is a no-op on lock creation, so any value is accepted.
    ///
    ///      **Re-enabling locking requires an explicit ordering when `minLockPeriod > 0`:**
    ///      if `depositLockDuration` is currently `0` and `minLockPeriod > 0`, a subsequent
    ///      `setDepositLockDuration(newDuration)` with `newDuration <= minLockPeriod` will revert
    ///      with `MinLockPeriodExceedsDuration`. To re-enable locking in that state, first call
    ///      `setMinLockPeriod(0)` (or to a value strictly less than the intended `newDuration`),
    ///      then `setDepositLockDuration(newDuration)`, then optionally `setMinLockPeriod` again.
    function setMinLockPeriod(uint64 newPeriod) external onlyOwner {
        uint64 duration = depositLockDuration;
        if (newPeriod > 0 && duration > 0 && newPeriod >= duration) {
            revert MinLockPeriodExceedsDuration(newPeriod, duration);
        }
        uint64 previous = minLockPeriod;
        minLockPeriod = newPeriod;
        emit MinLockPeriodSet(previous, newPeriod);
    }

    /// @notice Overrides base to enforce `minLockPeriod < newDuration` when both are non-zero.
    /// @dev See `setMinLockPeriod` for the re-enable-after-disable ordering constraint: if
    ///      `depositLockDuration == 0` and `minLockPeriod > 0`, this call will revert with
    ///      `MinLockPeriodExceedsDuration` for any `newDuration <= minLockPeriod`. Reset
    ///      `minLockPeriod` first in that case.
    function setDepositLockDuration(uint64 newDuration) external override onlyOwner {
        uint64 minPeriod_ = minLockPeriod;
        if (newDuration > 0 && minPeriod_ > 0 && minPeriod_ >= newDuration) {
            revert MinLockPeriodExceedsDuration(minPeriod_, newDuration);
        }
        uint64 previous = depositLockDuration;
        depositLockDuration = newDuration;
        emit DepositLockDurationSet(previous, newDuration);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        address previous = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientSet(previous, newRecipient);
    }

    function setEarlyUnlockEnabled(bool enabled) external onlyOwner {
        earlyUnlockEnabled = enabled;
        emit EarlyUnlockEnabledSet(enabled);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Early unlock
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Unlock `sharesToUnlock` locked shares before their natural expiry, paying a
    ///         time-decaying fee in vault shares. Locks are consumed earliest-expiring first; partial consumption
    ///         is supported.
    /// @dev Caller must have approved this contract for vault shares (for fee transfer).
    ///      Reverts if `feeRecipient == address(0)`, if the caller has insufficient locked
    ///      shares, or if any consumed lock is still within `minLockPeriod`.
    ///
    ///      **Fee-optimal ordering caveat:** The strictly optimal consumption order would sort
    ///      locks by fee rate (`timeRemaining / duration`) at call time, not by `unlockTimestamp`.
    ///      These orders may diverge when `depositLockDuration` has been changed, producing locks
    ///      with different durations. Sorting by fee rate is impractical on-chain because the
    ///      ranking changes with every block. The current earliest-expiring-first order is a
    ///      practical heuristic that can be maintained cheaply in storage via sorted insertion
    ///      in `_appendLock`.
    /// @param sharesToUnlock Number of *locked* shares to release.
    /// @return feeShares Total fee (in vault shares) charged and transferred to `feeRecipient`.
    function earlyUnlock(uint256 sharesToUnlock) external returns (uint256 feeShares) {
        if (sharesToUnlock == 0) revert ZeroSharesRequested();
        if (!earlyUnlockEnabled) revert EarlyUnlockDisabled();

        uint256 maxFee_ = maxEarlyUnlockFee;
        address recipient;
        if (maxFee_ > 0) {
            recipient = feeRecipient;
            if (recipient == address(0)) revert NoFeeRecipient();
        }

        address user = msg.sender;
        _cleanupExpired(user);

        uint256 locked = _totalLocked[user];
        if (sharesToUnlock > locked) {
            revert InsufficientLockedShares(user, sharesToUnlock, locked);
        }

        (uint256 totalFee, uint256 fullyConsumed) = _consumeLocks(user, sharesToUnlock);

        _totalLocked[user] -= sharesToUnlock;

        if (fullyConsumed > 0) {
            _removePrefix(user, fullyConsumed);
        }

        feeShares = totalFee;

        if (feeShares > 0) {
            IERC20(VAULT()).safeTransferFrom(user, recipient, feeShares);
        }

        emit EarlyUnlock(user, sharesToUnlock, feeShares);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Simulates `earlyUnlock` and returns the fee that would be charged.
    /// @dev O(n) over the lock queue. Reverts on the same conditions as `earlyUnlock`
    ///      (insufficient shares, min period violation). Accounts for expired-but-not-yet-cleaned
    ///      locks by skipping them.
    ///      NOTE: intended for off-chain / UI reads. Gas cost scales linearly with the number
    ///      of locks; should not be used in state-changing on-chain logic.
    function previewEarlyUnlock(address user, uint256 sharesToUnlock) external view returns (uint256 feeShares) {
        if (sharesToUnlock == 0) return 0;
        if (!earlyUnlockEnabled) revert EarlyUnlockDisabled();
        if (maxEarlyUnlockFee > 0 && feeRecipient == address(0)) revert NoFeeRecipient();

        return _previewFee(_locks[user], sharesToUnlock, block.timestamp, user);
    }

    /// @dev Read-only counterpart of `_consumeLocks`. Skips the expired prefix (sorted: all
    ///      expired entries precede active ones) and computes fees for active locks.
    ///      `activeIndex` tracks the index for `LockWithinMinPeriod` errors, consistent with
    ///      `_consumeLocks`'s post-cleanup numbering.
    function _previewFee(Lock[] storage locks, uint256 sharesToUnlock, uint256 now_, address user)
        internal
        view
        returns (uint256 totalFee)
    {
        uint256 len = locks.length;
        uint256 remaining = sharesToUnlock;
        uint256 maxFee_ = maxEarlyUnlockFee;
        uint64 minPeriod_ = minLockPeriod;

        uint256 start;
        while (start < len && now_ >= locks[start].unlockTimestamp) {
            unchecked {
                start++;
            }
        }

        uint256 activeIndex;
        for (uint256 i = start; i < len && remaining > 0;) {
            uint64 duration_ = locks[i].duration;
            uint64 unlockTs = locks[i].unlockTimestamp;
            uint128 lockShares = locks[i].shares;

            if (minPeriod_ > 0 && duration_ > 0) {
                uint256 eligibleAt = uint256(unlockTs) - uint256(duration_) + uint256(minPeriod_);
                if (now_ < eligibleAt) {
                    revert LockWithinMinPeriod(user, activeIndex, eligibleAt - now_);
                }
            }

            uint256 consumed = remaining > lockShares ? lockShares : remaining;

            // fee = ⌈consumed × maxFee × timeRemaining / (duration × FEE_BASIS)⌉
            // No intermediate overflow: maxFee ≤ FEE_BASIS (10 000) and timeRemaining ≤ uint64.max,
            // so maxFee * timeRemaining fits well within uint256. The large multiplication with
            // consumed happens inside mulDiv's 512-bit intermediate.
            if (maxFee_ > 0 && duration_ > 0) {
                uint256 timeRemaining = unlockTs > now_ ? uint256(unlockTs) - now_ : 0;
                totalFee += Math.mulDiv(
                    consumed, maxFee_ * timeRemaining, uint256(duration_) * FEE_BASIS, Math.Rounding.Ceil
                );
            }

            remaining -= consumed;
            unchecked {
                activeIndex++;
                i++;
            }
        }

        if (remaining > 0) {
            revert InsufficientLockedShares(user, sharesToUnlock, sharesToUnlock - remaining);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Iterates locks front-to-back (earliest-expiring first, since the array is sorted by
    ///      `unlockTimestamp`). Calculates per-lock fee, reduces partially consumed locks
    ///      in-place, and counts fully consumed entries.
    ///      REQUIRE: `_cleanupExpired(user)` must be called before this function.
    ///      `LockWithinMinPeriod` index is relative to the first active lock (starts at 0
    ///      post-cleanup), consistent with `_previewFee`'s `activeIndex`.
    function _consumeLocks(address user, uint256 sharesToUnlock)
        internal
        returns (uint256 totalFee, uint256 fullyConsumed)
    {
        Lock[] storage locks = _locks[user];
        uint256 len = locks.length;
        uint256 remaining = sharesToUnlock;
        uint256 now_ = block.timestamp;
        uint256 maxFee_ = maxEarlyUnlockFee;
        uint64 minPeriod_ = minLockPeriod;

        for (uint256 i = 0; i < len && remaining > 0;) {
            Lock storage lock = locks[i];
            uint64 duration_ = lock.duration;
            uint64 unlockTs = lock.unlockTimestamp;
            uint128 lockShares = lock.shares;

            if (minPeriod_ > 0 && duration_ > 0) {
                uint256 eligibleAt = uint256(unlockTs) - uint256(duration_) + uint256(minPeriod_);
                if (now_ < eligibleAt) {
                    revert LockWithinMinPeriod(user, i, eligibleAt - now_);
                }
            }

            uint256 consumed = remaining > lockShares ? lockShares : remaining;

            // fee = ⌈consumed × maxFee × timeRemaining / (duration × FEE_BASIS)⌉
            // No intermediate overflow: maxFee ≤ FEE_BASIS (10 000) and timeRemaining ≤ uint64.max,
            // so maxFee * timeRemaining fits well within uint256. The large multiplication with
            // consumed happens inside mulDiv's 512-bit intermediate.
            if (maxFee_ > 0 && duration_ > 0) {
                uint256 timeRemaining = unlockTs > now_ ? uint256(unlockTs) - now_ : 0;
                totalFee += Math.mulDiv(
                    consumed, maxFee_ * timeRemaining, uint256(duration_) * FEE_BASIS, Math.Rounding.Ceil
                );
            }

            if (consumed == uint256(lockShares)) {
                lock.shares = 0;
                fullyConsumed++;
            } else {
                lock.shares = uint128(uint256(lockShares) - consumed);
            }

            remaining -= consumed;
            unchecked {
                i++;
            }
        }

        if (remaining > 0) {
            revert InsufficientLockedShares(user, sharesToUnlock, sharesToUnlock - remaining);
        }
    }
}
