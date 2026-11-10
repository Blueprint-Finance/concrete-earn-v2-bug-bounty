// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IHook} from "../../interface/IHook.sol";
import {IContractId} from "../../interface/IContractId.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";

/**
 * @title BaseHook
 * @notice Abstract base for every vault hook. Centralizes the boilerplate shared by all hooks:
 *         the {VAULT}/{FACTORY} immutable-args layout, the clone initializer guard, the contract
 *         identity ({CONTRACT_TYPE}/{FLAVOUR}/{VERSION}/{ID}) and no-op defaults for the full
 *         {IHook} surface.
 *
 * @dev    ## Scope (what this base intentionally does NOT include)
 *
 *         `BaseHook` carries **no access-control mixin and no mutable storage**. Access control is
 *         left to each concrete hook so that single-purpose validators can use `OwnableUpgradeable`
 *         while aggregators (e.g. the hook container) can use role-based access control, without one
 *         dragging the other's unused machinery. Keeping the base storage-free also means it never
 *         participates in the storage layout of the clones that inherit it.
 *
 *         ## Immutable args
 *
 *         Clones are deployed via ClonesWithImmutableArgs with `[factory (20)][vault (20)]` appended
 *         to their calldata. {FACTORY} and {VAULT} read those bytes (hence `pure`), so neither value
 *         occupies a storage slot.
 *
 *         ## Initializer guard
 *
 *         {__BaseHook_init} enforces that only the configured {FACTORY} may initialize a freshly
 *         deployed clone. Concrete hooks call it from their own `initializer` before wiring up their
 *         access-control mixin and configuration.
 *
 *         ## No-op IHook defaults
 *
 *         All eleven {IHook} entry points default to empty `external virtual` implementations
 *         (matching the interface) so that a concrete hook only overrides the lifecycle points it
 *         actually cares about. A hook that needs internal or `super` access to a given entry point
 *         overrides it with `public` (the `external` -> `public` relaxation is allowed);
 *         aggregators that only forward calls (e.g. the hook container) keep them `external`.
 *
 *         > Safety note: because the defaults are silent no-ops, a hook that *means* to enforce a
 *         > given lifecycle point MUST override it. A missing override fails open (the operation is
 *         > allowed), it does not revert.
 */
abstract contract BaseHook is IHook, IContractId, Clone, Initializable {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a non-factory address attempts to initialize a clone.
    error NotFactory();
    /// @notice Thrown when a zero address is supplied where a non-zero address is required.
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────────
    // Immutable args
    // ─────────────────────────────────────────────────────────────────────────────

    // Encoding: [factory (20)][vault (20)]
    uint256 internal constant FACTORY_OFFSET = 0;
    uint256 internal constant VAULT_OFFSET = 20;

    /// @notice Returns the factory authorized to initialize this clone.
    ///         Encoded as an immutable arg at byte offset 0 (20 bytes).
    /// @dev `pure`: the value is read from the clone's calldata immutable args, not from state.
    function FACTORY() public pure returns (address) {
        return _getArgAddress(FACTORY_OFFSET);
    }

    /// @notice Returns the vault this hook is bound to.
    ///         Encoded as an immutable arg at byte offset 20 (20 bytes).
    /// @dev `pure`: the value is read from the clone's calldata immutable args, not from state.
    function VAULT() public pure returns (address) {
        return _getArgAddress(VAULT_OFFSET);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor & initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Locks the implementation contract so only clones (via `initialize`) can be used.
    constructor() {
        _disableInitializers();
    }

    /// @dev Shared initialization guard for clones. Reverts unless the caller is {FACTORY}.
    ///      Concrete hooks invoke this from their own `initializer` before configuring access
    ///      control and hook-specific state.
    function __BaseHook_init() internal onlyInitializing {
        require(msg.sender == FACTORY(), NotFactory());
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Contract type for hooks in the {ContractIdEncoding} scheme.
    uint256 public constant CONTRACT_TYPE = 5; // hook

    /// @notice Flavour discriminator for this hook within the hook contract type.
    /// @dev Each concrete hook defines its own flavour.
    function FLAVOUR() public pure virtual returns (uint256);

    /// @notice Semantic version of this hook, returned as `(major, minor, patch)`.
    /// @dev Each concrete hook defines its own version.
    function VERSION() public pure virtual returns (uint256 major, uint256 minor, uint256 patch);

    /// @notice Encoded contract identity combining {CONTRACT_TYPE}, {FLAVOUR} and {VERSION}.
    function ID() public pure virtual override(IContractId) returns (uint64) {
        (uint256 major, uint256 minor, uint256 patch) = VERSION();
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), major, minor, patch);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // IHook — no-op defaults
    // ─────────────────────────────────────────────────────────────────────────────

    function preDeposit(address, uint256, uint256, address, uint256) external virtual {}

    function preMultiDeposit(address, address, uint256, uint256, uint256, address, uint256) external virtual {}

    function preMint(address, uint256, uint256, address, uint256) external virtual {}

    function preWithdraw(address, uint256, uint256, address, address, uint256) external virtual {}

    function preRedeem(address, uint256, uint256, address, address, uint256) external virtual {}

    function postDeposit(address, uint256, uint256, address, uint256) external virtual {}

    function postMint(address, uint256, uint256, address, uint256) external virtual {}

    function postWithdraw(address, uint256, uint256, address, uint256) external virtual {}

    function postRedeem(address, uint256, uint256, address, uint256) external virtual {}

    function preTransfer(address, address, address, uint256) external virtual {}

    function postTransfer(address, address, address, uint256) external virtual {}
}
