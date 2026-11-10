// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseOwnableHook} from "./BaseOwnableHook.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

/**
 * @title UserDepositCapHook
 * @notice Pre-deposit hook that enforces a per-user deposit cap for a single vault.
 * @dev Soft limit on the receiver's current position value
 *      (`convertToAssets(balanceOf(receiver)) + incoming assets`).
 * @author Blueprint Finance
 */
contract UserDepositCapHook is BaseOwnableHook {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error UserDepositLimitExceeded(address user, uint256 attemptedTotal, uint256 limit);
    error InvalidLimit(uint256 limit);

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event DepositCapSet(uint256 oldCap, uint256 newCap);

    // ─────────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Per-user deposit cap for this vault (in asset terms)
    uint256 public userDepositCap;

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor & initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes a freshly-deployed clone of this hook.
     * @param _owner The owner address that can manage vault caps
     * @dev Vault address is supplied as an immutable arg at clone time, not via initialize.
     */
    function initialize(address _owner) external virtual initializer {
        __UserDepositCapHook_init(_owner);
    }

    /// @dev Shared initialization logic invoked by this contract's `initialize` and by the
    ///      initializers of derived hooks.
    function __UserDepositCapHook_init(address _owner) internal onlyInitializing {
        __BaseOwnableHook_init(_owner);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 2; // UserDepositCapHook
    }

    function VERSION() public pure virtual override returns (uint256, uint256, uint256) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the per-user deposit cap for this vault
     * @param _depositCap The deposit cap for each user (in asset terms)
     */
    function setDepositCap(uint256 _depositCap) external onlyOwner {
        uint256 oldCap = userDepositCap;
        userDepositCap = _depositCap;
        emit DepositCapSet(oldCap, _depositCap);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Gets the per-user deposit cap for this vault
     * @return The deposit cap that applies to each user
     */
    function getUserDepositCap() public view returns (uint256) {
        return userDepositCap;
    }

    /**
     * @notice Checks if a user can deposit a given amount into this vault
     * @param _user The user (receiver) address
     * @param _additionalAssets The amount of assets to deposit
     * @return true if the user can deposit, reverts if the user cannot deposit
     */
    function canUserDeposit(address _user, uint256 _additionalAssets) external view returns (bool) {
        _checkDepositLimit(_user, _additionalAssets);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Pre Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Pre-deposit hook - validates the receiver's deposit against the per-user cap.
    /// @dev Only `assets` (deposit amount) and `receiver` are consumed; the remaining IHook
    ///      parameters are unused here and left unnamed.
    function preDeposit(address, uint256 assets, uint256, address receiver, uint256) public view virtual override {
        _checkDepositLimit(receiver, assets);
    }

    /// @notice Pre-mint hook - validates the receiver's mint against the per-user cap.
    /// @dev Only `assets` (deposit amount) and `receiver` are consumed; the remaining IHook
    ///      parameters are unused here and left unnamed.
    function preMint(address, uint256 assets, uint256, address receiver, uint256) public view virtual override {
        _checkDepositLimit(receiver, assets);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Internal function to check if a deposit would exceed the user's cap
     * @param _receiver The address that will receive the shares
     * @param _additionalAssets The amount of assets being added
     */
    function _checkDepositLimit(address _receiver, uint256 _additionalAssets) internal view {
        uint256 depositCap_ = userDepositCap;
        if (depositCap_ == type(uint256).max) return;
        uint256 userShares = IERC4626(VAULT()).balanceOf(_receiver);
        uint256 currentAssetValue = IERC4626(VAULT()).convertToAssets(userShares);
        uint256 newTotal = currentAssetValue + _additionalAssets;
        if (newTotal > depositCap_) {
            revert UserDepositLimitExceeded(_receiver, newTotal, depositCap_);
        }
    }
}
