// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IHook} from "../../interface/IHook.sol";
import {AccessControlDefaultAdminRulesEnumerable} from "../../lib/AccessControlDefaultAdminRulesEnumerable.sol";
import {HookContainerStorageLib} from "../lib/HookContainerStorageLib.sol";
import {PeripheryRolesLib} from "../lib/PeripheryRolesLib.sol";

/**
 * @title HookContainer
 * @notice Container contract that combines multiple independent hook contracts into one
 * @dev Implements IHook interface and forwards all hook calls to registered sub-hooks sequentially.
 *      Uses ERC-7201 namespaced storage pattern for storage isolation.
 *      All sub-hooks must pass (no reverts) for the container hook to succeed.
 * @dev Uses AccessControlDefaultAdminRulesEnumerable for role-based access control with
 *      default admin rules and enumeration support. HOOK_MANAGER_ROLE can add/remove sub-hooks.
 * @dev IMPORTANT - Hook Order: The execution order of hooks is NOT guaranteed to remain stable.
 *      Adding hooks appends to the end, but removing hooks uses swap-and-pop which changes order.
 *      Do not rely on hook execution order for correctness. Hooks should be independently valid.
 * @dev IMPORTANT - Trust Model: This container implicitly trusts all registered hook code.
 *      - Hooks should be stateless validators (apart from configuration storage)
 *      - Hooks should not allow callbacks or arbitrary code execution
 *      - This container intentionally provides NO reentrancy protection by design
 *      - This container performs NO caller verification - hook functions are publicly callable
 *      - A malicious or buggy hook can block all vault operations
 *      - Thoroughly audit all hooks before registration
 */
contract HookContainer is IHook, AccessControlDefaultAdminRulesEnumerable {
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
    error ZeroAddress();
    error MaxHooksExceeded();
    error SelfRegistrationNotAllowed();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event HookAdded(address indexed hook);
    event HookRemoved(address indexed hook);

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes the hook container with access control
     * @param _admin The admin address that can manage roles
     * @dev _admin zero address check is handled by AccessControlDefaultAdminRulesEnumerable constructor
     */
    constructor(address _admin) AccessControlDefaultAdminRulesEnumerable(0, _admin) {
        _setRoleAdmin(PeripheryRolesLib.HOOK_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
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
    function addHook(address _hook) external onlyRole(PeripheryRolesLib.HOOK_MANAGER_ROLE) {
        HookContainerStorageLib.HookContainerStorage storage $ = HookContainerStorageLib.fetch();

        require(_hook != address(0), ZeroAddress());
        require(_hook != address(this), SelfRegistrationNotAllowed());
        require(!$.isHookRegistered[_hook], HookAlreadyRegistered(_hook));
        require($.hooks.length < MAX_HOOKS, MaxHooksExceeded());

        $.hooks.push(_hook);
        $.isHookRegistered[_hook] = true;

        emit HookAdded(_hook);
    }

    /**
     * @notice Removes a hook from the container
     * @param _hook The address of the hook contract to remove
     * @dev Only callable by accounts with HOOK_MANAGER_ROLE
     */
    function removeHook(address _hook) external onlyRole(PeripheryRolesLib.HOOK_MANAGER_ROLE) {
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
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this deposit
     */
    function preDeposit(address sender, uint256 assets, address receiver, uint256 totalAssets) external {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preDeposit(sender, assets, receiver, totalAssets);
        }
    }

    /**
     * @notice Pre-mint hook - forwards to all registered hooks
     * @param sender The address initiating the mint
     * @param shares The amount of shares being minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this mint
     */
    function preMint(address sender, uint256 shares, address receiver, uint256 totalAssets) external {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preMint(sender, shares, receiver, totalAssets);
        }
    }

    /**
     * @notice Pre-withdraw hook - forwards to all registered hooks
     * @param sender The address initiating the withdrawal
     * @param assets The amount of assets being withdrawn
     * @param receiver The address that will receive the assets
     * @param owner The owner of the shares being redeemed
     * @param totalAssets The total assets in the vault before this withdrawal
     */
    function preWithdraw(address sender, uint256 assets, address receiver, address owner, uint256 totalAssets)
        external
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preWithdraw(sender, assets, receiver, owner, totalAssets);
        }
    }

    /**
     * @notice Pre-redeem hook - forwards to all registered hooks
     * @param sender The address initiating the redemption
     * @param shares The amount of shares being redeemed
     * @param receiver The address that will receive the assets
     * @param owner The owner of the shares being redeemed
     * @param totalAssets The total assets in the vault before this redemption
     */
    function preRedeem(address sender, uint256 shares, address receiver, address owner, uint256 totalAssets) external {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).preRedeem(sender, shares, receiver, owner, totalAssets);
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
    function postMint(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external {
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
    {
        address[] storage hooks = HookContainerStorageLib.fetch().hooks;
        uint256 length = hooks.length;
        for (uint256 i = 0; i < length; i++) {
            IHook(hooks[i]).postRedeem(sender, assets, shares, receiver, totalAssets);
        }
    }
}
