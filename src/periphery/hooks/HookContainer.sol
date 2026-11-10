// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseHook} from "./BaseHook.sol";
import {IHook} from "../../interface/IHook.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {HookContainerStorageLib} from "../lib/HookContainerStorageLib.sol";
import {PeripheryRolesLib} from "../lib/PeripheryRolesLib.sol";
import {ITimelockProtected} from "../../interface/ITimelockProtected.sol";
import {TimelockIntegrationLib} from "../../lib/TimelockIntegrationLib.sol";

/**
 * @title HookContainer
 * @notice Container contract that combines multiple independent hook contracts into one
 * @dev Implements IHook interface and forwards all hook calls to registered sub-hooks sequentially.
 *      Uses ERC-7201 namespaced storage pattern for storage isolation.
 *      All sub-hooks must pass (no reverts) for the container hook to succeed.
 * @dev Uses AccessControlEnumerable for role-based access control with
 *      enumeration support. HOOK_MANAGER_ROLE can add/remove sub-hooks.
 * @dev IMPORTANT - Hook Order: The execution order of hooks is NOT guaranteed to remain stable.
 *      Adding hooks appends to the end, but removing hooks uses swap-and-pop which changes order.
 *      Do not rely on hook execution order for correctness. Hooks should be independently valid.
 * @dev IMPORTANT - Trust Model: This container implicitly trusts all registered hook code.
 *      - Hooks should be stateless validators (apart from configuration storage)
 *      - Hooks should not allow callbacks or arbitrary code execution
 *      - This container intentionally provides NO reentrancy protection by design
 *      - All hook forwarding functions are restricted to calls from the vault via `onlyVault`
 *      - A malicious or buggy hook can block all vault operations
 *      - Thoroughly audit all hooks before registration
 */
contract HookContainer is BaseHook, ITimelockProtected, AccessControlEnumerableUpgradeable {
    // ─────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Maximum number of hooks that can be registered
    /// @dev adding more hooks is a bad practice, this constant limits potential gas costs for multi-hook execution, creates a soft protection against DOS issues caused by hook misconfiguration.
    uint256 public constant MAX_HOOKS = 6;

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error HookAlreadyRegistered(address hook);
    error HookNotRegistered(address hook);
    error MaxHooksExceeded();
    error SelfRegistrationNotAllowed();
    error HookVaultMismatch(address hook);
    error OnlyVault();
    error HookReplacementIdentical(address hook);
    /// @dev The last remaining DEFAULT_ADMIN_ROLE cannot revoke or renounce its own admin role.
    error CannotRemoveLastDefaultAdmin();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event HookAdded(address indexed hook);
    event HookRemoved(address indexed hook);
    event HookReplaced(address indexed oldHook, address indexed newHook);

    // ─────────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != VAULT()) revert OnlyVault();
        _;
    }

    /// @dev Applied to privileged functions that require a prior {ITimelock.propose}
    ///      followed by the matured tier delay before they can execute.
    modifier afterDelay() {
        _enforceDelay();
        _;
    }

    /// @dev Validates and consumes the matured timelock schedule entry for the
    ///      calling function. No-op while timelock enforcement is not yet active.
    /// @dev This contract is deployed as a `ClonesWithImmutableArgs` clone, with args appended to the calldata of every call. Slicing
    ///      only up to {_getImmutableArgsOffset} strips that clone-specific tail so the
    ///      forwarded args match the canonically-encoded args `Timelock.propose` used
    function _enforceDelay() internal {
        TimelockIntegrationLib.enforceDelay(msg.sig, msg.data[4:_getImmutableArgsOffset()]);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor & initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes a freshly-deployed clone of the hook container with access control.
     * @param _admin The admin address that can manage roles
     * @dev Vault address is supplied as an immutable arg at clone time, not via initialize.
     */
    function initialize(address _admin) external initializer {
        require(_admin != address(0), ZeroAddress());
        __BaseHook_init();
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _setRoleAdmin(PeripheryRolesLib.HOOK_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 1; // HookContainer
    }

    function VERSION() public pure virtual override returns (uint256, uint256, uint256) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Adds a hook to the container
     * @param _hook The address of the hook contract to add
     * @dev Only callable by accounts with HOOK_MANAGER_ROLE
     * @dev IMPORTANT: This function assumes _hook implements IHook interface correctly.
     *      No interface validation is performed. Adding an invalid hook will cause
     *      all vault operations to revert. Callers must verify hook compatibility externally.
     */
    function addHook(address _hook) external onlyRole(PeripheryRolesLib.HOOK_MANAGER_ROLE) afterDelay {
        HookContainerStorageLib.HookContainerStorage storage $ = HookContainerStorageLib.fetch();

        require(_hook != address(0), ZeroAddress());
        require(_hook != address(this), SelfRegistrationNotAllowed());
        require(!$.isHookRegistered[_hook], HookAlreadyRegistered(_hook));
        require($.hooks.length < MAX_HOOKS, MaxHooksExceeded());

        require(IHook(_hook).VAULT() == VAULT(), HookVaultMismatch(_hook));

        $.hooks.push(_hook);
        $.isHookRegistered[_hook] = true;

        emit HookAdded(_hook);
    }

    /**
     * @notice Atomically replaces an already-registered hook with a new one.
     * @dev Semantically equivalent to `removeHook(_oldHook)` followed by `addHook(_newHook)`,
     *      but performed in a single call so that there is no intermediate block (or even
     *      mempool window) in which the container's hook set has been emptied. This matters
     *      for enforcement hooks (e.g. lock hooks) whose temporary absence would lift
     *      restrictions on every vault operation routed through this container.
     *
     *      The new hook is appended at the position of the old hook to keep call ordering
     *      stable for callers that rely on it (note: the contract still does not formally
     *      guarantee a stable order across other operations; see the contract-level note).
     *
     *      Validations mirror {addHook}:
     *        - `_newHook != address(0)` (`ZeroAddress`)
     *        - `_newHook != address(this)` (`SelfRegistrationNotAllowed`)
     *        - `_oldHook` is registered (`HookNotRegistered`)
     *        - `_newHook` is not yet registered (`HookAlreadyRegistered`)
     *        - `_oldHook != _newHook` (`HookReplacementIdentical`)
     *        - `_newHook.vault() == VAULT` (`HookVaultMismatch`)
     *
     *      Only callable by accounts with `HOOK_MANAGER_ROLE`.
     * @param _oldHook The currently registered hook to remove.
     * @param _newHook The new hook to install in its place.
     */
    function replaceHook(address _oldHook, address _newHook)
        external
        onlyRole(PeripheryRolesLib.HOOK_MANAGER_ROLE)
        afterDelay
    {
        HookContainerStorageLib.HookContainerStorage storage $ = HookContainerStorageLib.fetch();

        require(_newHook != address(0), ZeroAddress());
        require(_newHook != address(this), SelfRegistrationNotAllowed());
        require(_oldHook != _newHook, HookReplacementIdentical(_oldHook));
        require($.isHookRegistered[_oldHook], HookNotRegistered(_oldHook));
        require(!$.isHookRegistered[_newHook], HookAlreadyRegistered(_newHook));

        require(IHook(_newHook).VAULT() == VAULT(), HookVaultMismatch(_newHook));

        uint256 length = $.hooks.length;
        for (uint256 i = 0; i < length; i++) {
            if ($.hooks[i] == _oldHook) {
                $.hooks[i] = _newHook;
                break;
            }
        }

        $.isHookRegistered[_oldHook] = false;
        $.isHookRegistered[_newHook] = true;

        emit HookReplaced(_oldHook, _newHook);
    }

    /**
     * @notice Removes a hook from the container
     * @param _hook The address of the hook contract to remove
     * @dev Only callable by accounts with HOOK_MANAGER_ROLE
     * @dev Unlike most removal functions elsewhere in the protocol removing a hook does
     *      not shut off a compromised privileged actor — it *lifts* whatever enforcement the
     *      hook was providing (e.g. `DepositLockHook` / `DepositLockRegSHook` transfer
     *      restrictions). Therefore it is gated behind {afterDelay}
     */
    function removeHook(address _hook) external onlyRole(PeripheryRolesLib.HOOK_MANAGER_ROLE) afterDelay {
        HookContainerStorageLib.HookContainerStorage storage $ = HookContainerStorageLib.fetch();

        require($.isHookRegistered[_hook], HookNotRegistered(_hook));

        // Remove from array by swapping with last element
        uint256 length = $.hooks.length;
        for (uint256 i = 0; i < length; i++) {
            if ($.hooks[i] == _hook) {
                $.hooks[i] = $.hooks[length - 1];
                $.hooks.pop();
                break;
            }
        }

        $.isHookRegistered[_hook] = false;

        emit HookRemoved(_hook);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Timelock admin
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITimelockProtected
    /// @dev Only callable by DEFAULT_ADMIN_ROLE and only before timelock enforcement is activated.
    ///      After {activateTimelock} the timelock address is permanently locked.
    function setTimelock(address timelock_) external afterDelay onlyRole(DEFAULT_ADMIN_ROLE) {
        TimelockIntegrationLib.setTimelock(timelock_);
        emit TimelockSet(timelock_);
    }

    /// @inheritdoc ITimelockProtected
    function activateTimelock() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address tl = TimelockIntegrationLib.activateTimelock();
        emit TimelockActivated(tl);
    }

    /// @inheritdoc ITimelockProtected
    function getTimelock() external view returns (address timelock_, bool active_) {
        return TimelockIntegrationLib.state();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Access control overrides
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Gates `grantRole` behind the timelock for every role.
    /// @dev The container only defines DEFAULT_ADMIN_ROLE and HOOK_MANAGER_ROLE, both of which
    ///      are privileged (there are no hot-key operational roles to exempt), so every grant
    ///      requires a prior timelock proposal. The per-role tier is resolved by the timelock at
    ///      `artifactDelayTier[CT_HOOK_CONTAINER][role]` (DEFAULT_ADMIN_ROLE → TIER_1,
    ///      HOOK_MANAGER_ROLE → TIER_2).
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        _enforceDelay();
        super.grantRole(role, account);
    }

    /// @notice Prevents removing the last DEFAULT_ADMIN_ROLE, which would leave the
    ///         container permanently without an admin.
    /// @dev Both {revokeRole} and {renounceRole} funnel through this hook, so this single
    ///      override blocks self-revoke, self-renounce, and admin-revokes-admin alike. With
    ///      multiple admins any one of them (including the caller) can still be removed.
    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1) {
            revert CannotRemoveLastDefaultAdmin();
        }
        return super._revokeRole(role, account);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the number of registered hooks
     * @return The number of hooks
     */
    function getHooksCount() external view returns (uint256) {
        return HookContainerStorageLib.fetch().hooks.length;
    }

    /**
     * @notice Returns all registered hook addresses
     * @return Array of hook addresses
     */
    function getAllHooks() external view returns (address[] memory) {
        return HookContainerStorageLib.fetch().hooks;
    }

    /**
     * @notice Returns the hook address at a specific index
     * @param _index The index of the hook
     * @return The hook address
     */
    function getHookAt(uint256 _index) external view returns (address) {
        return HookContainerStorageLib.fetch().hooks[_index];
    }

    /**
     * @notice Checks if a hook is registered in the container
     * @param _hook The hook address to check
     * @return True if the hook is registered
     */
    function isHookRegistered(address _hook) external view returns (bool) {
        return HookContainerStorageLib.fetch().isHookRegistered[_hook];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Pre Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Pre-deposit hook - forwards to all registered hooks
     * @param sender The address initiating the deposit
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares to be minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this deposit
     */
    function preDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        external
        override
        onlyVault
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preDeposit(sender, assets, shares, receiver, totalAssets);
        }
    }

    /**
     * @notice Pre-multi-deposit hook - forwards to all registered hooks
     * @param sender The address initiating the deposit
     * @param depositAsset The non-base token being deposited
     * @param depositAssetAmount The raw amount of `depositAsset`, in that token's own decimals
     * @param baseAssets The base-asset-equivalent value of `depositAssetAmount`
     * @param shares The amount of shares to be minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this deposit
     * @dev Sub-hooks that do not override {BaseHook-preMultiDeposit} are silent no-ops.
     */
    function preMultiDeposit(
        address sender,
        address depositAsset,
        uint256 depositAssetAmount,
        uint256 baseAssets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) external override onlyVault {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i])
                .preMultiDeposit(sender, depositAsset, depositAssetAmount, baseAssets, shares, receiver, totalAssets);
        }
    }

    /**
     * @notice Pre-mint hook - forwards to all registered hooks
     * @param sender The address initiating the mint
     * @param assets The amount of assets to be deposited
     * @param shares The amount of shares being minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this mint
     */
    function preMint(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        external
        override
        onlyVault
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preMint(sender, assets, shares, receiver, totalAssets);
        }
    }

    /**
     * @notice Pre-withdraw hook - forwards to all registered hooks
     * @param sender The address initiating the withdrawal
     * @param assets The amount of assets being withdrawn
     * @param shares The amount of shares to be burned
     * @param receiver The address that will receive the assets
     * @param owner The owner of the shares being redeemed
     * @param totalAssets The total assets in the vault before this withdrawal
     */
    function preWithdraw(
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 totalAssets
    ) external override onlyVault {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preWithdraw(sender, assets, shares, receiver, owner, totalAssets);
        }
    }

    /**
     * @notice Pre-redeem hook - forwards to all registered hooks
     * @param sender The address initiating the redemption
     * @param assets The amount of assets to be withdrawn
     * @param shares The amount of shares being redeemed
     * @param receiver The address that will receive the assets
     * @param owner The owner of the shares being redeemed
     * @param totalAssets The total assets in the vault before this redemption
     */
    function preRedeem(
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 totalAssets
    ) external override onlyVault {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preRedeem(sender, assets, shares, receiver, owner, totalAssets);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Post Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Post-deposit hook - forwards to all registered hooks
     * @param sender The address that initiated the deposit
     * @param assets The amount of assets deposited
     * @param shares The amount of shares minted
     * @param receiver The address that received the vault shares
     * @param totalAssets The total assets in the vault after this deposit
     */
    function postDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        external
        override
        onlyVault
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).postDeposit(sender, assets, shares, receiver, totalAssets);
        }
    }

    /**
     * @notice Post-mint hook - forwards to all registered hooks
     * @param sender The address that initiated the mint
     * @param assets The amount of assets deposited
     * @param shares The amount of shares minted
     * @param receiver The address that received the vault shares
     * @param totalAssets The total assets in the vault after this mint
     */
    function postMint(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        external
        override
        onlyVault
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).postMint(sender, assets, shares, receiver, totalAssets);
        }
    }

    /**
     * @notice Post-withdraw hook - forwards to all registered hooks
     * @param sender The address that initiated the withdrawal
     * @param assets The amount of assets withdrawn
     * @param shares The amount of shares burned
     * @param receiver The address that received the assets
     * @param totalAssets The total assets in the vault after this withdrawal
     */
    function postWithdraw(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        external
        override
        onlyVault
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).postWithdraw(sender, assets, shares, receiver, totalAssets);
        }
    }

    /**
     * @notice Post-redeem hook - forwards to all registered hooks
     * @param sender The address that initiated the redemption
     * @param assets The amount of assets withdrawn
     * @param shares The amount of shares burned
     * @param receiver The address that received the assets
     * @param totalAssets The total assets in the vault after this redemption
     */
    function postRedeem(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        external
        override
        onlyVault
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).postRedeem(sender, assets, shares, receiver, totalAssets);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Transfer Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Pre-transfer hook - forwards to all registered hooks
     * @param sender The address initiating the transfer (msg.sender)
     * @param from The address sending the shares
     * @param to The address receiving the shares
     * @param shares The amount of shares being transferred
     */
    function preTransfer(address sender, address from, address to, uint256 shares) external override onlyVault {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preTransfer(sender, from, to, shares);
        }
    }

    /**
     * @notice Post-transfer hook - forwards to all registered hooks
     * @param sender The address that initiated the transfer (msg.sender)
     * @param from The address that sent the shares
     * @param to The address that received the shares
     * @param shares The amount of shares transferred
     */
    function postTransfer(address sender, address from, address to, uint256 shares) external override onlyVault {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).postTransfer(sender, from, to, shares);
        }
    }
}
