// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ITimelock} from "../periphery/interface/ITimelock.sol";

/**
 * @title TimelockIntegrationLib
 * @notice Shared internal library for timelock integration across all protected
 *         contracts (factory, vault, strategy, etc.).
 *
 *         Owns a dedicated EIP-7201 storage slot for the timelock state
 *         (`address timelock` + `bool active`) that is independent of each
 *         contract's main storage struct, preventing layout conflicts across
 *         upgrades.
 *
 *         All functions are `internal` — they are inlined into the calling
 *         contract at compile time and have zero DELEGATECALL overhead.
 *         Events and errors that must appear in the contract's ABI are
 *         intentionally left to the calling contract; this library only
 *         handles storage access, validation, and the timelock external call.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 */
library TimelockIntegrationLib {
    // ── EIP-7201 storage ─────────────────────────────────────────────────────

    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.TimelockIntegration")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TIMELOCKINTEGRATION_STORAGE_LOCATION =
        0x7d38a0bb5a9fac28be21b9ad1227ab462c5c0c3d596c5b8233cc67f55672d400;

    /// @custom:storage-location erc7201:concrete.storage.TimelockIntegration
    struct TimelockState {
        /// @dev Address of the Timelock contract.
        address timelock;
        /// @dev Whether timelock enforcement is active. Irreversible once set.
        ///      Packs into the same slot as `timelock` (20 + 1 = 21 bytes).
        bool active;
    }

    function _fetch() private pure returns (TimelockState storage $) {
        assembly {
            $.slot := TIMELOCKINTEGRATION_STORAGE_LOCATION
        }
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @notice Thrown by {activateTimelock} when the timelock is already active.
    error TimelockAlreadyActive();

    /// @notice Thrown by {setTimelock} when the provided timelock address is the zero address.
    error ZeroAddress();

    /// @notice Thrown by {activateTimelock} when no timelock address has been set.
    error TimelockNotSet();

    // ── Internal functions ────────────────────────────────────────────────────

    /**
     * @dev Validates and consumes the matured timelock schedule entry for the
     *      calling function.  No-op while `active` is false (bootstrap window).
     *      `sig` and `args` must be captured in the calling contract's context
     *      (i.e. `msg.sig` and `msg.data[4:]`) so that the timelock receives
     *      the original function's selector and arguments, not this call's.
     */
    function enforceDelay(bytes4 sig, bytes calldata args) internal {
        TimelockState storage $ = _fetch();
        if ($.active) ITimelock($.timelock).checkDelayExpired(sig, args);
    }

    /**
     * @dev Stores the timelock address.  Reverts with {ZeroAddress} if the
     *      provided address is the zero address.
     */
    function setTimelock(address timelock_) internal {
        if (timelock_ == address(0)) revert ZeroAddress();
        TimelockState storage $ = _fetch();
        $.timelock = timelock_;
    }

    /**
     * @dev Irreversibly activates timelock enforcement.  Reverts with
     *      {TimelockAlreadyActive} if already active, or {TimelockNotSet} if no
     *      timelock address has been configured.  Returns the stored timelock
     *      address so the caller can include it in an emitted event.
     */
    function activateTimelock() internal returns (address timelock_) {
        TimelockState storage $ = _fetch();
        if ($.active) revert TimelockAlreadyActive();
        if ($.timelock == address(0)) revert TimelockNotSet();
        $.active = true;
        return $.timelock;
    }

    /// @dev Returns the current timelock state (address + active flag).
    function state() internal view returns (address timelock_, bool active_) {
        TimelockState storage $ = _fetch();
        return ($.timelock, $.active);
    }
}
