// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title TimelockStorageLib
 * @notice EIP-7201 namespaced storage layout for the {Timelock} contract.
 * @dev Storage location is computed as:
 *      keccak256(abi.encode(uint256(keccak256("concrete.storage.Timelock")) - 1)) & ~bytes32(uint256(0xff))
 */
library TimelockStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.Timelock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TimelockStorageLocation =
        0xcfca85a4719d22690640a5e288776a51c2c063159c052e31e743bcb0bd360600;

    /// @custom:storage-location erc7201:concrete.storage.Timelock
    struct TimelockStorage {
        // ── Tier configuration ────────────────────────────────────────────
        /// @dev tier code → configured delay in seconds.
        mapping(bytes4 tier => uint256 delay) tierDelay;
        // ── Artifact registry ─────────────────────────────────────────────
        /// @dev (contractType, artifact) → tier code. `bytes4(0)` means unregistered
        ///      (and therefore, for {checkDelayExpired}, not delay-gated).
        ///
        ///      An `artifact` is the generic identifier of a protected entry on a
        ///      contract of `contractType`. Two encodings coexist in the same map
        ///      with negligible collision risk (~2^-224):
        ///
        ///        - Function selectors: `artifact = bytes32(bytes4(selector))`.
        ///          The 4-byte selector occupies the high bytes; low 28 bytes are zero.
        ///        - Role identifiers (for `grantRole` special-case):
        ///          `artifact = role` (already `bytes32` from `keccak256(...)`).
        ///
        ///      The role-grant tier is therefore looked up at
        ///      `artifactDelayTier[contractType][role]` — no separate map needed.
        mapping(bytes4 contractType => mapping(bytes32 artifact => bytes4 tier)) artifactDelayTier;
        // ── Schedule ──────────────────────────────────────────────────────
        /// @dev actionId → readyAt timestamp (`0` means no entry).
        ///      `actionId = keccak256(abi.encode(target, selector, args))` where
        ///      `target` is the protected contract address — i.e. `msg.sender` of
        ///      the eventual {checkDelayExpired} call. Including `target` lets the
        ///      timelock serve as a central delay hub for many vaults/strategies
        ///      without per-instance collisions on shared selectors.
        mapping(bytes32 actionId => uint256 readyAt) schedules;
        // ── Target binding ────────────────────────────────────────────────
        /// @dev protectedContract address → registered contract type. `bytes4(0)` means unbound.
        mapping(address protectedContract => bytes4 contractType) contractTypeOf;
        // ── Activation flag ───────────────────────────────────────────────
        /// @dev While `false`, `checkDelayExpired` is a no-op. One-way: flips to `true` and stays.
        bool active;
    }

    /// @dev Returns the EIP-7201 storage struct for this library.
    function fetch() internal pure returns (TimelockStorage storage $) {
        assembly {
            $.slot := TimelockStorageLocation
        }
    }
}
