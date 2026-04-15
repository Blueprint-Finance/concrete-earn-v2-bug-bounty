// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

/**
 * @title FeeAccountant
 * @notice Receives vault share tokens as the fee recipient and allows
 *         authorized distributors to distribute accumulated fee shares to
 *         whitelisted recipients in a single call. Deployed behind a UUPS proxy.
 *
 * @dev The contract itself holds vault shares. `distributeFeeShares` transfers
 *      shares from this contract to each listed recipient while emitting
 *      per-transfer and aggregate events that include the share price at the
 *      time of distribution.
 *
 * @dev The contract is bound to a single ERC-4626 vault at initialization.
 *      Only whitelisted recipient addresses may receive fee shares.
 *
 *      Roles:
 *        - `DEFAULT_ADMIN_ROLE` — can grant/revoke roles, manage the recipient
 *           whitelist, and authorize upgrades.
 *        - `DISTRIBUTOR_ROLE`   — can call `distributeFeeShares`.
 */
contract FeeAccountant is AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ── Roles ────────────────────────────────────────────────────────────

    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // ── Storage ──────────────────────────────────────────────────────────

    IERC4626 public vault;
    mapping(address => bool) public whitelistedRecipients;

    // ── Events ───────────────────────────────────────────────────────────

    event FeeDistribution(address indexed vault, uint256 sharePrice, uint256 totalShares);
    event FeeTransferred(address indexed vault, address indexed recipient, uint256 amount);
    event RecipientWhitelisted(address indexed recipient);
    event RecipientRemovedFromWhitelist(address indexed recipient);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────

    error ArrayLengthMismatch();
    error EmptyArrays();
    error TotalMismatch(uint256 expectedTotal, uint256 actualTotal);
    error ZeroAddress();
    error ZeroAdmin();
    error ZeroVault();
    error ZeroToken();
    error ZeroRecipient();
    error ZeroAmount();
    error CannotRescueVaultShares();
    error RecipientNotWhitelisted(address recipient);

    // ── Constructor (disable initializers on implementation) ─────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ── Initializer ─────────────────────────────────────────────────────

    function initialize(address admin_, address vault_) external initializer {
        if (admin_ == address(0)) revert ZeroAdmin();
        if (vault_ == address(0)) revert ZeroVault();
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();
        vault = IERC4626(vault_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(DISTRIBUTOR_ROLE, admin_);
    }

    // ── Recipient whitelist management ────────────────────────────────────

    function addRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        whitelistedRecipients[recipient] = true;
        emit RecipientWhitelisted(recipient);
    }

    function removeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        whitelistedRecipients[recipient] = false;
        emit RecipientRemovedFromWhitelist(recipient);
    }

    // ── Core ─────────────────────────────────────────────────────────────

    /**
     * @notice Distribute fee shares held by this contract to multiple recipients.
     * @param recipients  Ordered list of whitelisted recipient addresses.
     * @param amounts     Ordered list of share amounts (must match `recipients` length).
     * @param totalShares Expected sum of all `amounts` entries (integrity check).
     */
    function distributeFeeShares(address[] calldata recipients, uint256[] calldata amounts, uint256 totalShares)
        external
        onlyRole(DISTRIBUTOR_ROLE)
    {
        uint256 len = recipients.length;
        if (len == 0) revert EmptyArrays();
        if (len != amounts.length) revert ArrayLengthMismatch();

        IERC4626 vault_ = vault;
        uint256 oneShare = 10 ** vault_.decimals();
        uint256 sharePrice = vault_.convertToAssets(oneShare);

        IERC20 vaultShareToken = IERC20(address(vault_));
        uint256 sum;
        for (uint256 i; i < len; ++i) {
            sum += amounts[i];
            _transferFee(vaultShareToken, recipients[i], amounts[i]);
        }
        if (sum != totalShares) revert TotalMismatch(totalShares, sum);

        emit FeeDistribution(address(vault_), sharePrice, totalShares);
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    /**
     * @notice Rescue ERC-20 tokens accidentally sent to this contract.
     * @param token  The ERC-20 token to rescue.
     * @param to     Destination address.
     * @param amount Amount to transfer.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroToken();
        if (token == address(vault)) revert CannotRescueVaultShares();
        if (to == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _transferFee(IERC20 vaultShareToken, address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!whitelistedRecipients[recipient]) revert RecipientNotWhitelisted(recipient);
        vaultShareToken.safeTransfer(recipient, amount);
        emit FeeTransferred(address(vaultShareToken), recipient, amount);
    }

    // ── UUPS ─────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
