// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseHook} from "./BaseHook.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title BaseOwnableHook
 * @notice Abstract base for owner-managed hooks. Layers `OwnableUpgradeable` on top of {BaseHook}
 *         so single-purpose validator hooks share the same ownership wiring without each repeating
 *         the inheritance and initializer plumbing.
 *
 * @dev    Aggregators that need role-based access control (e.g. the hook container) inherit
 *         {BaseHook} directly instead of this contract, keeping the two access-control models from
 *         leaking into one another.
 */
abstract contract BaseOwnableHook is BaseHook, OwnableUpgradeable {
    /// @dev Shared initialization for owner-managed hooks. Runs the {BaseHook} factory guard, then
    ///      sets the owner. Concrete hooks call this from their own `initializer` before configuring
    ///      hook-specific state.
    /// @param owner_ Address granted ownership of the hook.
    function __BaseOwnableHook_init(address owner_) internal onlyInitializing {
        __BaseHook_init();
        __Ownable_init(owner_);
    }
}
