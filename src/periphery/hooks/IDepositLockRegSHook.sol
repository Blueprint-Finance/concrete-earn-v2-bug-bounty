// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IHook} from "../../interface/IHook.sol";

/**
 * @title IDepositLockRegSHook
 * @notice External surface specific to the `DepositLockRegSHook` family on top of the
 *         standard {IHook} interface.
 * @dev    Extends {IHook} so a `DepositLockRegSHook` implementation satisfies both vault
 *         hook calls and the Reg-S-specific migration / view surface through a single
 *         type. Concretely:
 *
 *         - `vault()` and every `pre*` / `post*` callback are inherited from {IHook}.
 *         - `drainAndGetLocked` is the v1 → v2 migration primitive (state-changing,
 *           gated by `onlySuccessorHook` on the implementation).
 *         - `effectiveTransferLocked` / `effectiveRedeemLocked` are the post-expiry
 *           aggregates a v2 deployment (or any off-chain dashboard) needs to consume.
 */
interface IDepositLockRegSHook is IHook {
    /// @notice Drives predecessor per-user expiry forward, optionally consumes Reg-S-window
    ///         locks when shares are burned via redeem/withdraw on the successor, and returns
    ///         post-update aggregates.
    /// @dev Callable only by the configured `successorHook` (set on v1 via `setSuccessorHook`).
    ///      Idempotent — repeat calls only iterate locks added since the previous invocation.
    /// @param user The user whose residual state should be drained.
    /// @param regSSharesToConsume Shares to subtract from this hook's Reg-S middle-window locks
    ///        (FIFO). Pass `0` on transfer-only drains.
    /// @return transferLocked Post-cleanup transfer-locked aggregate.
    /// @return redeemLocked   Post-cleanup redeem-locked aggregate (computed on the fly).
    /// @return regSConsumed   Shares actually removed from Reg-S-window locks (≤ input).
    function drainAndGetLocked(address user, uint256 regSSharesToConsume)
        external
        returns (uint256 transferLocked, uint256 redeemLocked, uint256 regSConsumed);

    /// @notice Post-expiry transfer-locked aggregate simulated in memory. No state writes.
    function effectiveTransferLocked(address user) external view returns (uint256);

    /// @notice Post-expiry redeem-locked aggregate computed on the fly. No state writes.
    function effectiveRedeemLocked(address user) external view returns (uint256);
}
