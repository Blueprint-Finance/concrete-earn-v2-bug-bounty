// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IHook} from "../../interface/IHook.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

/**
 * @title UserDepositCapHook
 * @notice Pre-deposit hook that enforces user deposit caps and can be configured for multiple vaults
 * @dev This hook can be used by multiple vaults, each with its own user deposit cap configuration.
 *      It tracks cumulative deposits per user per vault and enforces the configured cap.
 * @author Blueprint Finance
 */
contract UserDepositCapHook is IHook, Ownable {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error UserDepositLimitExceeded(address user, uint256 attemptedTotal, uint256 limit);
    error InvalidLimit(uint256 limit);
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event VaultDepositCapSet(address indexed vault, uint256 oldCap, uint256 newCap);

    // ─────────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Deposit cap per vault (in asset terms)
    /// @dev Maps vault address to the deposit cap for that vault
    mapping(address vault => uint256 cap) public userDepositCapByVault;

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes the hook
     * @param _owner The owner address that can manage vault caps
     */
    constructor(address _owner) Ownable(_owner) {}

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the deposit cap for a specific vault
     * @param _vault The vault address to configure
     * @param _depositCap The deposit cap for users in this vault (in asset terms)
     */
    function setVaultDepositCap(address _vault, uint256 _depositCap) external onlyOwner {
        require(_vault != address(0), ZeroAddress());
        uint256 oldCap = userDepositCapByVault[_vault];
        userDepositCapByVault[_vault] = _depositCap;
        emit VaultDepositCapSet(_vault, oldCap, _depositCap);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Gets the per-user deposit cap for a specific vault
     * @param _vault The vault address
     * @return The deposit cap that applies to each user in this vault
     */
    function getUserDepositCap(address _vault) public view returns (uint256) {
        return userDepositCapByVault[_vault];
    }

    /**
     * @notice Checks if a user can deposit a given amount into a vault
     * @param _vault The vault address to check against
     * @param _user The user (receiver) address
     * @param _additionalAssets The amount of assets to deposit
     * @return true if the user can deposit, reverts if the user cannot deposit
     */
    function canUserDeposit(address _vault, address _user, uint256 _additionalAssets) external view returns (bool) {
        _checkDepositLimit(IERC4626(_vault), _user, _additionalAssets);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Pre Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Pre-deposit hook - validates deposit against user limitt
     * @param sender sender address
     * @param assets The amount of assets being deposited
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this deposit
     */
    function preDeposit(address sender, uint256 assets, address receiver, uint256 totalAssets) public view virtual {
        _checkDepositLimit(IERC4626(msg.sender), receiver, assets);
    }

    /**
     * @notice Pre-mint hook - validates mint against user limit
     * @param sender sender address
     * @param shares The amount of shares being minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this mint
     */
    function preMint(address sender, uint256 shares, address receiver, uint256 totalAssets) public view virtual {
        uint256 assets = IERC4626(msg.sender).previewMint(shares);
        _checkDepositLimit(IERC4626(msg.sender), receiver, assets);
    }

    /// @notice Pre-withdraw hook - not implemented
    function preWithdraw(address, uint256, address, address, uint256) public pure virtual {}

    /// @notice Pre-redeem hook - not implemented
    function preRedeem(address, uint256, address, address, uint256) public pure virtual {}

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Post Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Post-deposit hook - not implemented
    function postDeposit(address, uint256, uint256, address, uint256) public pure virtual {}

    /// @notice Post-mint hook - not implemented
    function postMint(address, uint256, uint256, address, uint256) public pure virtual {}

    /// @notice Post-withdraw hook - not implemented
    function postWithdraw(address, uint256, uint256, address, uint256) public pure virtual {}

    /// @notice Post-redeem hook - not implemented
    function postRedeem(address, uint256, uint256, address, uint256) public pure virtual {}

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Internal function to check if a deposit would exceed the vault's cap
     * @param _vault The vault address (msg.sender in hook context)
     * @param _receiver The address that will receive the shares
     * @param _additionalAssets The amount of assets being added
     */
    function _checkDepositLimit(IERC4626 _vault, address _receiver, uint256 _additionalAssets) internal view {
        uint256 depositCap_ = userDepositCapByVault[address(_vault)];
        uint256 userShares = _vault.balanceOf(_receiver);
        uint256 currentAssetValue = _vault.convertToAssets(userShares);
        uint256 newTotal = currentAssetValue + _additionalAssets;
        if (newTotal > depositCap_) {
            revert UserDepositLimitExceeded(_receiver, newTotal, depositCap_);
        }
    }
}

