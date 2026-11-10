// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {UserDepositCapHook} from "./UserDepositCapHook.sol";

contract WhitelistUserDepositHook is UserDepositCapHook {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error NotWhitelisted(address user);

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event WhitelistSet(address indexed user, bool indexed isWhitelisted);

    // ─────────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────────

    mapping(address user => bool isWhitelisted) public whitelist;

    // ─────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Initializes a freshly-deployed clone of this hook.
    function initialize(address owner_) external override initializer {
        __UserDepositCapHook_init(owner_);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setter Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function whitelistUsers(address[] memory users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            _whitelistUser(users[i], true);
        }
    }

    function unWhitelistUsers(address[] memory users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            _whitelistUser(users[i], false);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function isWhitelisted(address user) external view returns (bool) {
        return whitelist[user];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Pre-deposit hook — validates the sender against the whitelist, then the per-user cap.
     * @param sender The address initiating the deposit
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares being minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this deposit
     */
    function preDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        public
        view
        override
    {
        if (!whitelist[sender]) revert NotWhitelisted(sender);
        super.preDeposit(sender, assets, shares, receiver, totalAssets);
    }

    /**
     * @notice Pre-mint hook — validates the sender against the whitelist, then the per-user cap.
     * @param sender The address initiating the mint
     * @param assets The amount of assets to be deposited
     * @param shares The amount of shares being minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this mint
     */
    function preMint(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        public
        view
        override
    {
        if (!whitelist[sender]) revert NotWhitelisted(sender);
        super.preMint(sender, assets, shares, receiver, totalAssets);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function _whitelistUser(address user, bool setWhitelisted) internal {
        if (user == address(0)) revert ZeroAddress();
        if (whitelist[user] != setWhitelisted) {
            whitelist[user] = setWhitelisted;
            emit WhitelistSet(user, setWhitelisted);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    function FLAVOUR() public pure override(UserDepositCapHook) returns (uint256) {
        return 3; // WhitelistUserDepositHook
    }

    function VERSION() public pure virtual override returns (uint256, uint256, uint256) {
        return (1, 7, 0);
    }
}
