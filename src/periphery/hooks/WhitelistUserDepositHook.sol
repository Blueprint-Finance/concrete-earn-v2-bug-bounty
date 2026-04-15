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
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    constructor(address owner) UserDepositCapHook(owner) {}

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
     * @notice Pre-deposit hook - validates deposit against whitelist and per user limit
     * @param sender vault address
     * @param assets The amount of assets being deposited
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this deposit
     */
    function preDeposit(address sender, uint256 assets, address receiver, uint256 totalAssets) public view override {
        if (!whitelist[sender]) revert NotWhitelisted(sender);
        super.preDeposit(sender, assets, receiver, totalAssets);
    }

    /**
     * @notice Pre-mint hook - validates mint against user whitelist and deposit limit
     * @param sender vault address
     * @param shares The amount of shares being minted
     * @param receiver The address that will receive the vault shares
     * @param totalAssets The total assets in the vault before this mint
     */
    function preMint(address sender, uint256 shares, address receiver, uint256 totalAssets) public view override {
        if (!whitelist[sender]) revert NotWhitelisted(sender);
        super.preMint(sender, shares, receiver, totalAssets);
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
}
