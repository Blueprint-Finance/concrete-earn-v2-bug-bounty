// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IHook} from "../../interface/IHook.sol";
import {BaseOwnableHook} from "./BaseOwnableHook.sol";

/**
 * @title MultiAssetDepositCapHook
 * @notice Pre-deposit hook that enforces a global cap on the cumulative amount deposited per
 *         deposit token, for a single multi-asset deposit vault.
 *
 * @dev    Bound to the {IHook-preMultiDeposit} lifecycle point (`PRE_MULTI_DEPOSIT`,
 *         flag 13), which is raised only by {ConcreteMultiAssetDepositAsyncVault} and only for
 *         deposits whose asset differs from the vault's base `asset()`. Base-asset deposits take
 *         the inherited ERC-4626 path and are therefore never seen or capped here; use the vault's
 *         `maxGlobalDepositAmount` for those.
 *
 *         ## Offset-by-1 cap encoding
 *
 *         Caps are stored offset by one so that "never configured" and "configured to zero" are
 *         distinguishable in a single slot: a stored `0` means uncapped, `1` means a cap of `0`
 *         (all deposits of that token blocked), `423` means a cap of `422`. {setDepositCap} takes
 *         the real cap and applies the offset itself; {removeCap} is the only way back to
 *         the uncapped state.
 *
 *         ## Rolling sum semantics
 *
 *         {totalDeposited} accumulates the raw deposit amount, in the deposit token's own
 *         decimals, for every token the hook sees — capped or not. Recording uncapped tokens too
 *         means a cap installed later already accounts for everything deposited before it.
 *
 *         The sum is monotonic: withdrawals and redemptions never reduce it, and there is no
 *         admin path to rewind it. This is a lifetime deposit cap, not an outstanding-balance cap.
 *         Once a token's total reaches its cap, that token is closed for deposits unless the cap
 *         is raised or cleared.
 *
 *         ## Caller authorization
 *
 *         Unlike the stateless validator hooks, {preMultiDeposit} writes storage, so it is gated
 *         to the vault (and optionally a {HookContainer} forwarding on the vault's behalf). Were
 *         it open, anyone could inflate the counters and permanently block deposits.
 *
 * @author Blueprint Finance
 */
contract MultiAssetDepositCapHook is BaseOwnableHook {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error TokenDepositCapExceeded(address token, uint256 attemptedTotal, uint256 cap);
    error CapTooLarge(uint256 cap);
    error OnlyVaultOrHookContainer();
    error InvalidHookContainer();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event DepositCapSet(address indexed token, uint256 previousCap, uint256 newCap);
    event DepositCapCleared(address indexed token, uint256 previousCap);
    event HookContainerSet(address previousContainer, address newContainer);

    /**
     * @notice Emitted by {preMultiDeposit} when a deposit is recorded against a *capped* token.
     *         Not emitted for uncapped tokens, since there is no cap being consumed.
     * @param token The deposit token that was recorded
     * @param amountDeposited The raw amount of `token` just deposited, in `token`'s own decimals
     * @param cap The cap configured for `token` at the time of this deposit
     * @param remainingToCap The amount of `token` that may still be deposited before the cap is reached
     */
    event PerTokenCapConsumed(address indexed token, uint256 amountDeposited, uint256 cap, uint256 remainingToCap);

    // ─────────────────────────────────────────────────────────────────────────────
    // Config
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Address of the HookContainer that forwards vault hook calls. `address(0)` = vault-only.
    /// @dev Fully trusted: it can advance the rolling sums with the same authority as the vault.
    ///      The owner must ensure the container preserves the same call semantics as a direct
    ///      vault invocation.
    address public hookContainer;

    // ─────────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Cumulative amount of each token deposited through this hook, in that token's decimals.
    mapping(address token => uint256 total) public totalDeposited;

    /// @dev Per-token cap offset by one: `0` = uncapped, `n` = cap of `n - 1`. Accessed through
    ///      {getDepositCap} / {getRawDepositCap} so the encoding never leaks into callers by accident.
    mapping(address token => uint256 capPlusOne) private _capPlusOne;

    // ─────────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────────

    modifier onlyVaultOrHookContainer() {
        if (msg.sender != VAULT() && msg.sender != hookContainer) revert OnlyVaultOrHookContainer();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor & initializer
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes a freshly-deployed clone of this hook.
     * @param _owner The owner address that can manage the per-token caps
     * @dev Vault address is supplied as an immutable arg at clone time, not via initialize.
     *      Every token starts uncapped; caps are configured afterwards via {setDepositCap}.
     */
    function initialize(address _owner) external virtual initializer {
        __MultiAssetDepositCapHook_init(_owner);
    }

    /// @dev Shared initialization logic invoked by this contract's `initialize` and by the
    ///      initializers of derived hooks.
    function __MultiAssetDepositCapHook_init(address _owner) internal onlyInitializing {
        __BaseOwnableHook_init(_owner);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Contract identity
    // ─────────────────────────────────────────────────────────────────────────────

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 9; // MultiAssetDepositCapHook
    }

    function VERSION() public pure virtual override returns (uint256, uint256, uint256) {
        return (1, 7, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the global lifetime deposit cap for `token`
     * @param token The deposit token the cap applies to
     * @param cap The maximum cumulative amount of `token` (in that token's own decimals) that may
     *            ever be deposited through this hook. `0` blocks all deposits of `token`.
     * @dev The cap is compared against the existing {totalDeposited}, so setting a cap below the
     *      amount already deposited immediately closes the token for further deposits.
     */
    function setDepositCap(address token, uint256 cap) external onlyOwner {
        require(token != address(0), ZeroAddress());
        require(cap != type(uint256).max, CapTooLarge(cap));

        uint256 previous = _capPlusOne[token];
        _capPlusOne[token] = cap + 1;

        emit DepositCapSet(token, previous == 0 ? 0 : previous - 1, cap);
    }

    /**
     * @notice Removes the cap for `token`, making it unlimited again
     * @param token The deposit token to uncap
     * @dev Distinct from `setDepositCap(token, 0)`, which sets a cap *of* zero. The rolling sum is
     *      untouched, so re-capping later still accounts for past deposits.
     */
    function removeCap(address token) external onlyOwner {
        uint256 previous = _capPlusOne[token];
        _capPlusOne[token] = 0;

        emit DepositCapCleared(token, previous == 0 ? 0 : previous - 1);
    }

    /**
     * @notice Sets the hook container authorized to forward hook calls alongside the vault
     * @param container The container address, or `address(0)` for vault-only
     */
    function setHookContainer(address container) external onlyOwner {
        if (container != address(0) && IHook(container).VAULT() != VAULT()) revert InvalidHookContainer();

        address previous = hookContainer;
        hookContainer = container;
        emit HookContainerSet(previous, container);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the cap configured for `token`
     * @param token The deposit token to query
     * @return capped Whether a cap has been configured at all
     * @return cap The cap, meaningful only when `capped` is true
     */
    function getDepositCap(address token) public view returns (bool capped, uint256 cap) {
        uint256 capPlusOne = _capPlusOne[token];
        if (capPlusOne == 0) return (false, 0);
        unchecked {
            return (true, capPlusOne - 1);
        }
    }

    /**
     * @notice Returns the raw offset-by-1 cap as stored: `0` = no cap, `n` = cap of `n - 1`
     * @param token The deposit token to query
     * @return The stored offset value
     */
    function getRawDepositCap(address token) public view returns (uint256) {
        return _capPlusOne[token];
    }

    /**
     * @notice Checks whether depositing `amount` of `token` would stay within the cap
     * @param token The deposit token
     * @param amount The amount to deposit, in `token`'s own decimals
     * @return true if the deposit fits, reverts with {TokenDepositCapExceeded} otherwise
     */
    function canDeposit(address token, uint256 amount) external view returns (bool) {
        (bool capped, uint256 cap) = getDepositCap(token);
        _checkDepositCap(token, capped, cap, totalDeposited[token] + amount);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Hook Implementations - Pre Hooks
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Pre-multi-deposit hook - records the raw deposit amount and enforces the token's cap.
    /// @dev Only `depositAsset` and `depositAssetAmount` are consumed; the remaining {IHook}
    ///      parameters are unused here and left unnamed. The rolling sum is advanced before the
    ///      check so an uncapped token still accumulates.
    function preMultiDeposit(
        address,
        address depositAsset,
        uint256 depositAssetAmount,
        uint256,
        uint256,
        address,
        uint256
    ) public virtual override onlyVaultOrHookContainer {
        uint256 newTotal = totalDeposited[depositAsset] + depositAssetAmount;
        (bool capped, uint256 cap) = getDepositCap(depositAsset);
        _checkDepositCap(depositAsset, capped, cap, newTotal);

        totalDeposited[depositAsset] = newTotal;

        if (capped) {
            emit PerTokenCapConsumed(depositAsset, depositAssetAmount, cap, cap - newTotal);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Reverts if `newTotal` would exceed `cap`, when `capped` is true
     * @param token The deposit token being checked, used only for the revert reason
     * @param capped Whether `token` has a cap configured, as returned by {getDepositCap}
     * @param cap The cap configured for `token`, meaningful only when `capped` is true
     * @param newTotal The prospective cumulative deposited amount
     */
    function _checkDepositCap(address token, bool capped, uint256 cap, uint256 newTotal) internal pure {
        if (capped && newTotal > cap) {
            revert TokenDepositCapExceeded(token, newTotal, cap);
        }
    }
}
