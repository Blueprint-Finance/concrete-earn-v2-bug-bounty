// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin
// ─────────────────────────────────────────────────────────────────────────────
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {IContractId} from "../../interface/IContractId.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Clones-with-immutable-args
// ─────────────────────────────────────────────────────────────────────────────
import {Clone} from "clones-with-immutable-args/Clone.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {
    IPositionHelperBase,
    SelfLiqState,
    TargetOwnerAmount,
    PositionApprovals,
    _SelfLiqMode
} from "../interface/IPositionHelperBase.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {ConcreteV2RolesLib} from "../../lib/Roles.sol";
import {ILenderModule} from "../interface/ILenderModule.sol";
import {IFlashModule} from "../interface/IFlashModule.sol";
import {ISwapModule} from "../interface/ISwapModule.sol";
import {TokenPair} from "../interface/ILoopingPrimitive.sol";
import {LoopModality, LoopModalityLib} from "../lib/Looping/LoopModalityLib.sol";
import {PositionManagementHelperStorageLib as PMHSLib} from "../lib/PositionManagementHelperStorageLib.sol";
import {PositionManagementHelperLib as PMHLib} from "../lib/PositionManagementHelperLib.sol";
import {WAD, RAY} from "../lib/Constants.sol";
import {IConcreteAsyncVaultImpl} from "../../interface/IConcreteAsyncVaultImpl.sol";

// ─────────────────────────────────────────────────────────────────────────────
// PositionHelperBase — abstract base
// ─────────────────────────────────────────────────────────────────────────────

/// @title  PositionHelperBase
/// @notice Abstract operator contract that manages a leveraged lend/borrow
///         position on behalf of a `positionOwner`.
///
/// @dev Clone lifecycle (ERC-1167 with immutable args via wighawag/clones-with-immutable-args):
///   • `positionOwner`, `collateralToken`, `borrowToken`, `collateralDecimals`, and
///     `borrowDecimals` are NOT stored in contract storage.  They are appended to each
///     clone's bytecode at clone time and read back via `_getArgAddress` / `_getArgUint8`.
///     Encoding (62 bytes):
///       [positionOwner (20)][collateralToken (20)][borrowToken (20)]
///       [collateralDecimals (1)][borrowDecimals (1)]
///   • The concrete implementation's constructor must call `_disableInitializers()`
///     so the bare implementation contract cannot be accidentally initialized.
///   • Each clone calls `initialize(...)` exactly once to set per-instance state
///     (roles, modules) and per-clone token approvals.
///
/// @dev Cloning pattern:
///   1. Deploy the concrete implementation (sets lender immutables, disables initializers).
///   2. For each position, call `ClonesWithImmutableArgs.clone(implementation,
///         abi.encodePacked(positionOwner, collateralToken, borrowToken,
///                          collateralDecimals, borrowDecimals))`.
///   3. Call `initialize(...)` on the clone.
///
/// @dev Zero-balance invariant: this contract MUST NOT hold tokens at rest.
///      Tokens may transit during a transaction, but every balance MUST be zero
///      by the time the outermost call returns.
abstract contract PositionHelperBase is
    Clone,
    AccessControlEnumerableUpgradeable,
    IPositionHelperBase,
    ILenderModule,
    IContractId
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant CONTRACT_TYPE = 4; // position helper

    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 public constant POSITION_OPERATOR_ROLE = keccak256("POSITION_OPERATOR_ROLE");
    bytes32 public constant POSITION_ADMIN_ROLE = keccak256("POSITION_ADMIN_ROLE");

    /// @dev Default maximum acceptable slippage for self-liquidation swaps (WAD).
    ///      10% = 0.10e18.
    uint64 internal constant DEFAULT_MAX_SELF_LIQ_SLIPPAGE_WAD = 1e17;

    /// @dev A tiny repayment buffer used to cover lender-side rounding dust.
    uint256 internal constant REPAY_RAY_ROUNDING_BUFFER = 2;

    // ── Flash callback guards ─────────────────────────────────────────────────

    /// @dev Reverts if the caller of `executeFlash` is not the registered flash module.
    modifier onlyFlashModule() {
        address flashMod = PMHSLib.fetch().flashModule;
        if (msg.sender != flashMod) revert IPositionHelperBase.OnlyFlashModule(msg.sender, flashMod);
        _;
    }

    /// @dev Reverts if the flash requester is not this contract.
    ///      Prevents a rogue flash module from replaying a callback against an unrelated position.
    modifier onlyFlashRequester(address requester_) {
        if (requester_ != address(this)) {
            revert IPositionHelperBase.InvalidFlashRequester(requester_, address(this));
        }
        _;
    }

    /// @dev Admin may always self-liquidate. Operator may only trigger it if the LTV is above the
    ///      self-liq buffer. Called directly (not via modifier) at each use site — see
    ///      `_requireOnlySingleCollateralPosition` for why.
    function _requireCanLiquidate() internal view {
        // Admin role is allowed in any case.
        // If function needs to be called even if the ltv condition is not met, the admin may do so.
        bool isAllowed = hasRole(POSITION_ADMIN_ROLE, msg.sender);
        if (!isAllowed) {
            // if the sender is not the admin, it can still trigger the function if the ltv condition is met.
            isAllowed = hasRole(POSITION_OPERATOR_ROLE, msg.sender)
                && (uint256(getCurrentLtvInWad()) + PMHSLib.fetch().selfLiqThrBufferInWad)
                    >= getLiquidationThresholdInWad();
            // the sender may trigger only if the ltv is above the buffer and if they have the operator role.
        }
        if (!isAllowed) revert IPositionHelperBase.NeitherAdminNorOperatorWithinPermissibleLtv(msg.sender);
    }

    // ── Clone immutable args ──────────────────────────────────────────────────
    // Encoding: [positionOwner (20)][collateralToken (20)][borrowToken (20)]
    //           [collateralDecimals (1)][borrowDecimals (1)]
    // Set at clone time: ClonesWithImmutableArgs.clone(impl, abi.encodePacked(...))

    uint256 internal constant POSITION_OWNER_OFFSET = 0;
    uint256 internal constant COLLATERAL_TOKEN_OFFSET = 20;
    uint256 internal constant BORROW_TOKEN_OFFSET = 40;
    uint256 internal constant COLLATERAL_DECIMALS_OFFSET = 60;
    uint256 internal constant BORROW_DECIMALS_OFFSET = 61;

    /// @notice Account on whose behalf operations are executed.
    ///         Read from clone immutable args at byte offset `POSITION_OWNER_OFFSET`.
    function POSITION_OWNER() public pure override(IPositionHelperBase) returns (address) {
        return _getArgAddress(POSITION_OWNER_OFFSET);
    }

    /// @notice ERC20 token supplied as collateral to the lender.
    ///         Read from clone immutable args at byte offset `COLLATERAL_TOKEN_OFFSET`.
    function COLLATERAL_TOKEN() public pure override(ILenderModule) returns (address) {
        return _getArgAddress(COLLATERAL_TOKEN_OFFSET);
    }

    /// @notice ERC20 token borrowed from the lender and deployed into `target`.
    ///         Read from clone immutable args at byte offset `BORROW_TOKEN_OFFSET`.
    function BORROW_TOKEN() public pure override(ILenderModule) returns (address) {
        return _getArgAddress(BORROW_TOKEN_OFFSET);
    }

    /// @notice Decimals of the collateral token, encoded at clone time.
    function COLLATERAL_DECIMALS() public pure returns (uint8) {
        return _getArgUint8(COLLATERAL_DECIMALS_OFFSET);
    }

    /// @notice Decimals of the borrow token, encoded at clone time.
    function BORROW_DECIMALS() public pure returns (uint8) {
        return _getArgUint8(BORROW_DECIMALS_OFFSET);
    }

    // ── Per-clone initializer ─────────────────────────────────────────────────

    /// @dev Called once from the concrete contract's `initialize(...)`.
    ///
    /// @param admin_                    Address granted `POSITION_ADMIN_ROLE`.
    /// @param operator_                 Address granted `POSITION_OPERATOR_ROLE`.
    /// @param yieldVault_               Async ERC4626 vault where borrowed funds are deployed.
    ///                                  Must satisfy: `yieldVault_.asset() == BORROW_TOKEN()`.
    /// @param flashModule_              Flash loan module (IFlashModule).
    /// @param swapModule_               Swap module (ISwapModule).
    /// @param healthyLtvInWad_          Centre of the desired healthy LTV band, in WAD.
    ///                                  e.g. 0.6e18 = 60% LTV is the operating target.
    /// @param healthyLtvDeviationInWad_ Half-width of the healthy band, in WAD.
    ///                                  LTVs in [healthyLtv − deviation, healthyLtv + deviation]
    ///                                  are classified as Healthy.  Must be > 0.
    /// @param selfLiqThrBufferInWad_    WAD buffer below the lender liquidation threshold
    ///                                  that triggers self-liquidation.  Must be > 0.
    function __PositionHelperBase_init(
        address admin_,
        address operator_,
        address yieldVault_,
        address flashModule_,
        address swapModule_,
        uint64 healthyLtvInWad_,
        uint64 healthyLtvDeviationInWad_,
        uint64 selfLiqThrBufferInWad_
    ) internal onlyInitializing {
        if (yieldVault_ == address(0) || yieldVault_.code.length == 0) {
            revert IPositionHelperBase.InvalidYieldVault();
        }
        if (BORROW_TOKEN() != IERC4626(yieldVault_).asset()) {
            revert IPositionHelperBase.InconsistentTokensBetweenLenderAndTarget();
        }
        if (admin_ == address(0)) revert IPositionHelperBase.ZeroAddress();
        if (operator_ == address(0)) revert IPositionHelperBase.InvalidOperatorAddress();
        if (flashModule_ != address(0) && flashModule_.code.length == 0) {
            revert IPositionHelperBase.InvalidFlashModule();
        }
        if (swapModule_ != address(0) && swapModule_.code.length == 0) revert IPositionHelperBase.InvalidSwapModule();
        if (selfLiqThrBufferInWad_ == 0) revert IPositionHelperBase.InvalidSelfLiqThrBufferInWad();
        if (healthyLtvDeviationInWad_ == 0) revert IPositionHelperBase.InvalidHealthyLtvDeviationInWad();

        // Validate that the encoded decimals match the actual token metadata.
        if (COLLATERAL_DECIMALS() != IERC20Metadata(COLLATERAL_TOKEN()).decimals()) {
            revert IPositionHelperBase.InvalidTokenDecimals();
        }
        if (BORROW_DECIMALS() != IERC20Metadata(BORROW_TOKEN()).decimals()) {
            revert IPositionHelperBase.InvalidTokenDecimals();
        }

        __AccessControlEnumerable_init();
        _setRoleAdmin(POSITION_ADMIN_ROLE, POSITION_ADMIN_ROLE);
        _setRoleAdmin(POSITION_OPERATOR_ROLE, POSITION_ADMIN_ROLE);
        _grantRole(POSITION_ADMIN_ROLE, admin_);
        _grantRole(POSITION_OPERATOR_ROLE, operator_);

        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        $.yieldVault = yieldVault_;
        $.flashModule = flashModule_;
        $.swapModule = swapModule_;
        $.maxSelfLiqSlippageInWad = DEFAULT_MAX_SELF_LIQ_SLIPPAGE_WAD;
        $.healthyLtvInWad = healthyLtvInWad_;
        $.healthyLtvDeviationInWad = healthyLtvDeviationInWad_;
        $.selfLiqThrBufferInWad = selfLiqThrBufferInWad_;
    }

    constructor() {
        _disableInitializers();
    }

    // ── Contract identity ─────────────────────────────────────────────────────

    function ID() public pure virtual override(IContractId) returns (uint64);

    // ── Storage view helpers ──────────────────────────────────────────────────

    /// @notice Async ERC4626 vault where borrowed funds are deployed.
    function yieldVault() public view returns (address) {
        return PMHSLib.fetch().yieldVault;
    }

    /// @notice Flash loan module used by self-liquidation flows.
    function flashModule() public view virtual returns (address) {
        return PMHSLib.fetch().flashModule;
    }

    /// @notice Swap module used to convert collateral to borrow tokens during self-liquidation.
    function swapModule() public view virtual returns (address) {
        return PMHSLib.fetch().swapModule;
    }

    /// @notice Max allowed swap slippage for self-liquidation calls, in WAD (1e18 = 100%).
    function maxSelfLiquidationSlippageInWad() public view returns (uint64) {
        return PMHSLib.fetch().maxSelfLiqSlippageInWad;
    }

    /// @notice Centre of the healthy LTV band, in WAD (1e18 = 100%).
    function healthyLtvInWad() public view returns (uint64) {
        return PMHSLib.fetch().healthyLtvInWad;
    }

    /// @notice Half-width of the healthy LTV band, in WAD.
    function healthyLtvDeviationInWad() public view returns (uint64) {
        return PMHSLib.fetch().healthyLtvDeviationInWad;
    }

    /// @notice WAD buffer below the lender liquidation threshold that triggers self-liquidation.
    function selfLiqThrBufferInWad() public view returns (uint64) {
        return PMHSLib.fetch().selfLiqThrBufferInWad;
    }

    /// @notice Updates the max allowed self-liquidation slippage (WAD).
    /// @dev Only callable by POSITION_ADMIN_ROLE.
    function setMaxSelfLiquidationSlippageInWad(uint64 newMaxSlippageInWad) external onlyRole(POSITION_ADMIN_ROLE) {
        if (newMaxSlippageInWad == 0 || uint256(newMaxSlippageInWad) >= WAD) {
            revert IPositionHelperBase.InvalidMaxSlippageInWad();
        }
        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        emit IPositionHelperBase.MaxSelfLiquidationSlippageUpdated($.maxSelfLiqSlippageInWad, newMaxSlippageInWad);
        $.maxSelfLiqSlippageInWad = newMaxSlippageInWad;
    }

    /// @dev Validates that the LTV band and self-liq buffer are consistent with the lender's
    ///      liquidation threshold.  Reverts with InvalidSelfLiqThrBufferInWad when buffer == 0
    ///      (a positive buffer is required to preserve the operator's preemptive self-liquidation
    ///       margin below the lender threshold), otherwise reverts with InvalidLtvRange when:
    ///        • ltvDev == 0, or
    ///        • lenderLiqThr ≤ healthyLtv + ltvDev + buffer
    ///          (equivalent to selfLiqThreshold ≤ healthyUpper — covers the case where
    ///           healthyLtv itself already sits above the self-liq trigger)
    ///      Uses the addition form to avoid underflow when computing selfLiqThreshold.
    function _ltvRangeIsValid(uint64 healthyLtv, uint64 ltvDev, uint64 buffer) internal view {
        if (buffer == 0) revert IPositionHelperBase.InvalidSelfLiqThrBufferInWad();
        uint64 liqThr = getLiquidationThresholdInWad();
        if (ltvDev == 0 || uint256(liqThr) <= uint256(healthyLtv) + ltvDev + buffer) {
            revert IPositionHelperBase.InvalidLtvRange(healthyLtv, ltvDev, buffer, liqThr);
        }
    }

    /// @notice Updates the centre of the healthy LTV band, in WAD.
    /// @dev Only callable by POSITION_ADMIN_ROLE.
    function setHealthyLtvInWad(uint64 newHealthyLtvInWad) external onlyRole(POSITION_ADMIN_ROLE) {
        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        _ltvRangeIsValid(newHealthyLtvInWad, $.healthyLtvDeviationInWad, $.selfLiqThrBufferInWad);
        emit IPositionHelperBase.HealthyLtvUpdated($.healthyLtvInWad, newHealthyLtvInWad);
        $.healthyLtvInWad = newHealthyLtvInWad;
    }

    /// @notice Updates the half-width of the healthy LTV band, in WAD.
    /// @dev Only callable by POSITION_ADMIN_ROLE.
    function setHealthyLtvDeviationInWad(uint64 newDeviationInWad) external onlyRole(POSITION_ADMIN_ROLE) {
        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        _ltvRangeIsValid($.healthyLtvInWad, newDeviationInWad, $.selfLiqThrBufferInWad);
        emit IPositionHelperBase.HealthyLtvDeviationUpdated($.healthyLtvDeviationInWad, newDeviationInWad);
        $.healthyLtvDeviationInWad = newDeviationInWad;
    }

    /// @notice Updates the self-liquidation threshold buffer, in WAD.
    /// @dev Only callable by POSITION_ADMIN_ROLE.
    function setSelfLiqThrBufferInWad(uint64 newBufferInWad) external onlyRole(POSITION_ADMIN_ROLE) {
        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        _ltvRangeIsValid($.healthyLtvInWad, $.healthyLtvDeviationInWad, newBufferInWad);
        emit IPositionHelperBase.SelfLiqThrBufferUpdated($.selfLiqThrBufferInWad, newBufferInWad);
        $.selfLiqThrBufferInWad = newBufferInWad;
    }

    // ── Position views (lender-implemented) ──────────────────────────────────
    // Declared public virtual; the lender subclass overrides them directly —
    // no internal+external wrapper indirection.

    /// @notice Current collateral and debt balances at the lender, in native token units.
    function getPosition() public view virtual returns (uint256 collateralAmount, uint256 debtAmount);

    /// @notice Current collateral balance at the lender, in collateral token units.
    function getCollateralAmount() public view virtual returns (uint256);

    /// @notice Current outstanding debt at the lender, in borrow token units.
    function getDebtAmount() public view virtual returns (uint256);

    /// @notice Current LTV of the position, in WAD (1e18 = 100%).
    function getCurrentLtvInWad() public view virtual returns (uint64);

    /// @notice Maximum LTV permitted by the lender for this collateral, in WAD.
    function getMaxLtvInWad() public view virtual returns (uint64);

    /// @notice Variable borrow rate on the borrowed asset, in WAD (1e18 = 100% APY).
    function getBorrowRateInWad() public view virtual returns (uint64);

    /// @notice Supply/liquidity rate on the collateral asset, in WAD (1e18 = 100% APY).
    function getSupplyRateInWad() public view virtual returns (uint64);

    /// @notice Price of one collateral token expressed in borrow tokens, in RAY (1e27 = 1.0).
    function collateralPriceInBorrowTokensInRay() public view virtual returns (uint256);

    /// @notice Amount of borrow tokens currently available to borrow from the lending pool.
    function getAvailablePoolLiquidity() public view virtual returns (uint256);

    /// @notice Current liquidation threshold in WAD (from the lender's config).
    ///         Positions at or above this LTV are eligible for external liquidation.
    function getLiquidationThresholdInWad() public view virtual returns (uint64);

    /// @notice Snapshot of the full position state in a single call.
    /// @return collateralAmount    Collateral at the lender, in collateral token units.
    /// @return debtAmount          Outstanding debt at the lender, in borrow token units.
    /// @return currentLtvInWad     Current LTV, in WAD (1e18 = 100%).
    /// @return collateralPriceInRay Collateral price in borrow tokens, in RAY (1e27 = 1.0).
    function getFullPosition()
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount, uint64 currentLtvInWad, uint256 collateralPriceInRay)
    {
        (collateralAmount, debtAmount) = getPosition();
        currentLtvInWad = getCurrentLtvInWad();
        collateralPriceInRay = collateralPriceInBorrowTokensInRay();
    }

    // ── Token pair ────────────────────────────────────────────────────────────

    /// @notice Returns the (collateralToken, borrowToken) pair for this position.
    function getTokenPair() external pure override(ILenderModule) returns (TokenPair memory) {
        return TokenPair({collateralToken: COLLATERAL_TOKEN(), borrowToken: BORROW_TOKEN()});
    }

    // ── Approval check ────────────────────────────────────────────────────────

    /// @notice Returns the complete approval and role status for this clone in a single call.
    ///         All fields must be `true` before invoking the corresponding operations.
    function checkApprovals() external view returns (PositionApprovals memory) {
        address owner = POSITION_OWNER();
        address self = address(this);
        (bool lenderCollateral, bool lenderDebt) = _getLenderApprovals();
        return PositionApprovals({
            collateralTokenApproved: IERC20(COLLATERAL_TOKEN()).allowance(owner, self) == type(uint256).max,
            lenderCollateralApproved: lenderCollateral,
            lenderDebtDelegated: lenderDebt,
            borrowTokenApproved: IERC20(BORROW_TOKEN()).allowance(owner, self) == type(uint256).max,
            vaultSharesApproved: IERC20(yieldVault()).allowance(owner, self) == type(uint256).max,
            hasWithdrawalManagerRole: IAccessControl(yieldVault()).hasRole(ConcreteV2RolesLib.WITHDRAWAL_MANAGER, self)
        });
    }

    // ── External operator entry points — lender ops ───────────────────────────

    /// @notice Supply `amount` of collateralToken on behalf of positionOwner.
    function supply(uint256 amount)
        external
        override(ILenderModule, IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        if (amount == 0) revert IPositionHelperBase.ZeroAmount();
        _supply(amount, true, true);
    }

    /// @notice Withdraw `amount` of collateral from the lender and return to positionOwner.
    ///
    /// @dev WARNING (Aave V3): pulling aTokens from positionOwner triggers Aave's health-factor
    ///      check at that moment.  If the position is near-liquidation, this call will revert
    ///      even though repaying first would have made room.  Use `retract` (repay-first)
    ///      for leveraged positions; standalone `withdraw` is safe only when debt is low.
    function withdraw(uint256 amount)
        external
        override(ILenderModule, IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        if (amount == 0) revert IPositionHelperBase.ZeroAmount();
        _withdraw(amount, true, true);
    }

    /// @notice Borrow `amount` of borrowToken via credit delegation and send to positionOwner.
    function borrow(uint256 amount)
        external
        override(ILenderModule, IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        if (amount == 0) revert IPositionHelperBase.ZeroAmount();
        _borrow(amount, true);
    }

    /// @notice Repay `amount` of borrowToken debt for positionOwner.
    function repay(uint256 amount)
        external
        override(ILenderModule, IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        if (amount == 0) revert IPositionHelperBase.ZeroAmount();
        _repay(amount, true);
    }

    // ── External operator entry points — target vault ops ─────────────────────

    /// @notice Deposit `amount` of borrowToken into the target vault.
    ///         Shares are minted directly to positionOwner.
    function depositOnTarget(uint256 amount)
        external
        virtual
        onlyRole(POSITION_OPERATOR_ROLE)
        returns (uint256 sharesReceived)
    {
        return _depositOnTarget(amount, true, true);
    }

    /// @notice Submit a queued redemption request for `shares` of the target vault.
    ///         Returns `instantAmount > 0` if the vault processed the redemption atomically.
    function requestRedemptionFromTarget(uint256 shares)
        external
        virtual
        onlyRole(POSITION_OPERATOR_ROLE)
        returns (uint256 amountReceived)
    {
        return _requestRedemptionFromTarget(shares);
    }

    /// @notice Cancel an outstanding redemption request and submit a new request in one call.
    /// @dev `requestIdToCancel` is the epoch ID for `ConcreteAsyncVaultImpl`.
    ///      Returns `instantAmount > 0` if the vault processed the redemption atomically.
    function updateRedemptionRequestFromTarget(uint256 requestIdToCancel, uint256 newSharesAmount)
        external
        virtual
        onlyRole(POSITION_OPERATOR_ROLE)
        returns (uint256 amountReceived)
    {
        if (newSharesAmount == 0) revert IPositionHelperBase.ZeroShares();
        _cancelRedemptionRequestFromTarget(requestIdToCancel);

        uint256 remaining =
            IConcreteAsyncVaultImpl(yieldVault()).getUserEpochRequest(POSITION_OWNER(), requestIdToCancel);
        if (remaining != 0) {
            revert IPositionHelperBase.RedemptionRequestNotCleared(requestIdToCancel, remaining);
        }
        return _requestRedemptionFromTarget(newSharesAmount);
    }

    /// @notice Cancel an outstanding redemption request.
    ///         Requires this contract to hold the `WITHDRAWAL_MANAGER_ROLE` on the vault.
    function cancelRedemptionRequestFromTarget(uint256 requestId) external onlyRole(POSITION_OPERATOR_ROLE) {
        _cancelRedemptionRequestFromTarget(requestId);
    }

    /// @notice Claim one or more fulfilled redemption requests and return assets to positionOwner.
    ///         Requires this contract to hold the `WITHDRAWAL_MANAGER_ROLE` on the vault.
    function claimRedemptionFromTarget(uint256[] calldata requestIds)
        external
        onlyRole(POSITION_OPERATOR_ROLE)
        returns (uint256 amount)
    {
        return _claimRedemptionFromTarget(requestIds);
    }

    /// @notice Escalate the outstanding redemption request to priority status.
    ///         Emits an event for off-chain processing by default.
    ///         Override in a subcontract when the vault supports on-chain priority queuing.
    function requestPriorityRedemptionFromTarget(uint256 requestId)
        public
        virtual
        override(IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        emit IPositionHelperBase.PriorityRedemptionRequested(requestId);
    }

    /// @notice Revoke the priority escalation on the outstanding redemption request.
    ///         Override in a subcontract when the vault supports on-chain priority queuing.
    function revokePriorityRedemptionFromTarget(uint256 requestId)
        public
        virtual
        override(IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        emit IPositionHelperBase.PriorityRedemptionRevoked(requestId);
    }

    // ── External operator entry points — high-level position flows ────────────

    /// @notice Deploy capital: supply collateral, borrow to `targetLtvInWad`, deposit into target.
    ///
    /// @dev Flow:
    ///   1. Pull `collateralAmount` from positionOwner and supply to the lender (aTokens → owner).
    ///   2. Post-supply LTV = d / ((c + x) · p).  If targetLtv ≤ post-supply LTV, skip borrow.
    ///   3. Borrow the delta to reach targetLtv and deposit into target vault (shares → owner).
    function deploy(uint256 collateralAmount, uint64 targetLtvInWad)
        external
        override(IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        _requireSingleCollateralPosition();
        if (targetLtvInWad > getMaxLtvInWad()) {
            revert IPositionHelperBase.TargetLtvExceedsMaxLtv();
        }

        uint256 price = collateralPriceInBorrowTokensInRay();
        uint256 collateralBefore = getCollateralAmount();
        uint256 existingDebt = getDebtAmount();

        if (collateralAmount > 0) {
            _supply(collateralAmount, true, true);
        }

        if (uint256(targetLtvInWad) <= PMHLib.minLtv(existingDebt, collateralBefore, collateralAmount, price)) return;

        uint256 borrowAmount =
            PMHLib.borrowAmountForTargetLtv(price, targetLtvInWad, collateralBefore, collateralAmount, existingDebt);

        // Cap borrow to available pool liquidity
        uint256 availableLiquidity = getAvailablePoolLiquidity();
        if (borrowAmount == 0 || availableLiquidity == 0) return;

        if (borrowAmount > availableLiquidity) borrowAmount = availableLiquidity;
        _borrow(borrowAmount, false);
        _depositOnTarget(borrowAmount, false, true);
    }

    /// @notice Pull `repayAmount` borrow tokens from positionOwner, repay debt, then withdraw
    ///         `withdrawalAmount` collateral.  LTV after withdrawal must not exceed
    ///         `maxPermissibleLtv`.  Either amount may be zero.
    function retract(uint256 repayAmount, uint256 withdrawalAmount, uint64 maxPermissibleLtv)
        external
        override(IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        _requireSingleCollateralPosition();
        if (repayAmount > 0) {
            IERC20(BORROW_TOKEN()).safeTransferFrom(POSITION_OWNER(), address(this), repayAmount);
        }
        _retract(repayAmount, withdrawalAmount, maxPermissibleLtv);
    }

    /// @notice Claim fulfilled redemptions then call retract (claimed amount used as repayAmount).
    function claimAndRetract(uint256[] calldata requestIds, uint256 withdrawalAmount, uint64 maxPermissibleLtv)
        external
        override(IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        _requireSingleCollateralPosition();
        uint256 claimed = _claimRedemptionFromTarget(requestIds);
        IERC20(BORROW_TOKEN()).safeTransferFrom(POSITION_OWNER(), address(this), claimed);
        _retract(claimed, withdrawalAmount, maxPermissibleLtv);
    }

    /// @notice redeem yield vault shares (synchronous path) and call retract (redeemed amount used as repayAmount).
    /// @dev Only works when the yield vault is enabled for atomic withdrawals.
    function redeemAndRetract(uint256 shares, uint256 withdrawalAmount, uint64 maxPermissibleLtv)
        external
        override(IPositionHelperBase)
        onlyRole(POSITION_OPERATOR_ROLE)
    {
        _requireSingleCollateralPosition();
        if (shares == 0) revert IPositionHelperBase.ZeroShares();
        // if the yield vault queue is active then revert.
        if (IConcreteAsyncVaultImpl(yieldVault()).isQueueActive()) {
            revert IPositionHelperBase.QueueIsActive();
        }
        uint256 redeemedAmount = IERC4626(yieldVault()).redeem(shares, address(this), POSITION_OWNER());
        _retract(redeemedAmount, withdrawalAmount, maxPermissibleLtv);
    }

    // ── External operator entry points — self-liquidation ─────────────────────

    /// @notice Flash-loan-assisted self-liquidation for a specified debt amount.
    ///
    /// @dev Computes worst-case collateral to withdraw via `PMHLib.flashWithdrawAmount`,
    ///      then initiates the flash.  All execution continues in `executeFlash`.
    ///
    /// @param debtAmount       Borrow-token units to repay.
    ///                         Pass `type(uint256).max` to liquidate the entire current debt.
    /// @param maxSlippageInWad Maximum acceptable swap slippage, in WAD (1e18 = 100%).
    function selfLiquidate(uint256 debtAmount, uint64 maxSlippageInWad) external override(IPositionHelperBase) {
        _requireCanLiquidate();
        _requireSingleCollateralPosition();
        _selfLiquidate(_SelfLiqMode.DebtAmount, debtAmount, 0, maxSlippageInWad);
    }

    /// @notice Partial self-liquidation reducing position LTV to `targetLtvInWad`.
    ///
    /// @dev Computes the collateral to withdraw and the flash amount simultaneously via
    ///      `PMHLib.flashWithdrawAmountFromTargetLtv`, then initiates the same flash callback
    ///      as `selfLiquidate`.
    ///
    ///      The flash premium is quoted on `getDebtAmount()` (conservative upper bound);
    ///      for typical implementations the premium rate is amount-independent.
    ///
    ///      WARNING: `targetLtvInWad` is solved against this pair's own `getCollateralAmount()` /
    ///      `getDebtAmount()`, not the lender's account-wide totals that `getCurrentLtvInWad()` /
    ///      `getLiquidationThresholdInWad()` (and the `_requireCanLiquidate` trigger) are based on. If
    ///      POSITION_OWNER() holds additional collateral or debt at the lender outside this pair,
    ///      driving this pair's LTV to `targetLtvInWad` does not guarantee the account-wide LTV
    ///      reaches `targetLtvInWad` — it may under- or over-correct the actual liquidation risk.
    ///
    /// @param targetLtvInWad   Desired post-liquidation LTV, in WAD (1e18 = 100%).
    /// @param maxSlippageInWad Maximum acceptable swap slippage, in WAD (1e18 = 100%).
    function selfLiquidateToLtv(uint64 targetLtvInWad, uint64 maxSlippageInWad) external override(IPositionHelperBase) {
        _requireCanLiquidate();
        _requireSingleCollateralPosition();
        _selfLiquidate(_SelfLiqMode.TargetLtv, 0, targetLtvInWad, maxSlippageInWad);
    }

    // ── External admin entry points ───────────────────────────────────────────

    /// @notice Rescue ERC-20 tokens accidentally sent to this contract.
    ///         Only callable by `POSITION_ADMIN_ROLE`.
    function rescueFunds(address token, uint256 amount)
        external
        override(IPositionHelperBase)
        onlyRole(POSITION_ADMIN_ROLE)
    {
        if (token == address(0)) revert IPositionHelperBase.ZeroAddress();
        IERC20(token).safeTransfer(msg.sender, amount);
        emit IPositionHelperBase.FundsRescued(token, msg.sender, amount);
    }

    // ── Flash callback ────────────────────────────────────────────────────────

    /// @notice Called by the flash module after it has transferred `amountInToken`
    ///         of borrowToken to this contract.
    ///
    /// @dev Self-liquidation flow (LoopWithdrawAndDeallocate):
    ///   1. Repay positionOwner's `amountInToken` debt at the lender (tokens already here).
    ///   2. Withdraw `collateralToWithdraw` from the lender (aTokens pulled from positionOwner;
    ///      repay in step 1 already lowered the health-factor check).
    ///   3. Swap exact-out: collateral → borrowToken for exactly `totalOwed` (flash + premium).
    ///      `maxAmountIn` = all withdrawn collateral; the swap uses only what is needed.
    ///   4. Re-supply surplus collateral (already in this contract) to the lender.
    ///   5. Approve flash module to pull back flash amount + premium.
    ///   6. Emit SelfLiquidated.
    ///
    /// @param amountInToken  Flash-borrowed borrow tokens, already in this contract.
    /// @param premiumInToken Flash premium owed on top of `amountInToken`.
    /// @param requester      Must equal `address(this)` — enforced by `onlyFlashRequester`.
    /// @param data           ABI-encoded `(uint256 collateralToWithdraw)` set by the caller.
    function executeFlash(
        address, /* token */
        uint256 amountInToken,
        uint256 premiumInToken,
        address requester,
        LoopModality, /* loopModality */
        bytes calldata data
    ) external onlyFlashModule onlyFlashRequester(requester) returns (bool) {
        uint256 collateralToWithdraw = abi.decode(data, (uint256));

        SelfLiqState memory s;
        s.positionOwner = POSITION_OWNER();
        s.swapModule = PMHSLib.fetch().swapModule;
        s.totalOwed = amountInToken + premiumInToken;
        s.debtRepaid = amountInToken;

        // 1. Repay debt (flash borrow tokens already in this contract).
        _repay(amountInToken, false);

        // Snapshot before withdrawing: any collateral balance already sitting here (e.g. an
        // unsolicited direct ERC-20 transfer) cancels out in the post-swap delta below, so it
        // can never be mistaken for swap surplus or make that surplus exceed `collateralToWithdraw`.
        uint256 collateralBalanceBefore = IERC20(COLLATERAL_TOKEN()).balanceOf(address(this));

        // 2. Withdraw collateral; repay in step 1 already satisfied the health-factor check.
        //    transferFromOwner=true: aTokens live in positionOwner's wallet (supply mints them there);
        //    transferToOwner=false:  underlying collateral stays here for the swap in step 3.
        _withdraw(collateralToWithdraw, true, false);

        // 3. Swap exact-out: collateral → exactly totalOwed borrow tokens.
        //    maxAmountIn = all withdrawn collateral; surplus collateral is re-supplied in step 4.
        ISwapModule(s.swapModule)
            .swapExactAmountOut(COLLATERAL_TOKEN(), BORROW_TOKEN(), collateralToWithdraw, s.totalOwed);

        // Surplus attributable to this withdrawal only (balanceAfter - balanceBefore), so any
        // pre-existing/donated balance is excluded and the subtraction below can't underflow.
        uint256 collateralBalanceAfter = IERC20(COLLATERAL_TOKEN()).balanceOf(address(this));
        uint256 surplusCollateral = collateralBalanceAfter - collateralBalanceBefore;
        s.collateralUsed = collateralToWithdraw - surplusCollateral;

        // 4. Re-supply surplus collateral (already in this contract, so transferFromOwner=false).
        if (surplusCollateral > 0) _supply(surplusCollateral, false, true);

        // 5. Approve flash module to pull back flash amount + premium.
        IERC20(BORROW_TOKEN()).forceApprove(msg.sender, s.totalOwed);

        emit IPositionHelperBase.SelfLiquidated(
            amountInToken, s.debtRepaid, collateralToWithdraw, surplusCollateral, s.collateralUsed
        );
        return true;
    }

    // ── Internal — core unwind logic ──────────────────────────────────────────

    /// @dev Core unwind primitive.
    ///      Assumes that the borrow tokens are already in this contract.
    ///      Execution order (repay-first for Aave V3 health-factor compliance):
    ///        a. Validate `maxPermissibleLtv` ≤ lender protocol max LTV.
    ///        b. If `repayAmount` > 0: assert sufficient contract balance, then repay.
    ///        c. If `withdrawalAmount` > 0: assert withdrawal stays within `maxPermissibleLtv`,
    ///           then withdraw collateral to positionOwner.
    ///
    ///      Either `repayAmount` or `withdrawalAmount` (or both) may be zero.
    ///
    /// @param repayAmount       Borrow tokens already in this contract to repay.
    /// @param withdrawalAmount  Collateral to return to positionOwner, in collateral token units.
    /// @param maxPermissibleLtv Post-operation LTV ceiling, in WAD.
    function _retract(uint256 repayAmount, uint256 withdrawalAmount, uint64 maxPermissibleLtv) internal {
        // a. maxPermissibleLtv must not exceed the lender's protocol max LTV.
        if (maxPermissibleLtv > getMaxLtvInWad()) {
            revert IPositionHelperBase.MaxPermissibleLtvExceedsLenderMaxLtv();
        }

        // b. Repay — check sufficient balance first.
        if (repayAmount > 0) {
            if (IERC20(BORROW_TOKEN()).balanceOf(address(this)) < repayAmount) {
                revert IPositionHelperBase.InsufficientRepayBalance();
            }
            _repay(repayAmount, false);
        }

        // c. Withdraw collateral — ensure LTV stays within maxPermissibleLtv.
        if (withdrawalAmount > 0) {
            uint256 xMax = PMHLib.withdrawable(
                getCollateralAmount(), getDebtAmount(), 0, collateralPriceInBorrowTokensInRay(), maxPermissibleLtv
            );
            if (withdrawalAmount > xMax) {
                revert IPositionHelperBase.WithdrawalWouldBreachMaxPermissibleLtv();
            }
            _withdraw(withdrawalAmount, true, true);
        }
    }

    /// @dev Repay `borrowAmount` of debt at the lender.
    /// @param transferFromOwner If true, pull borrowToken from positionOwner first.
    function _repay(uint256 borrowAmount, bool transferFromOwner) internal {
        _repayLender(borrowAmount, transferFromOwner);

        // Skip sweeping during flash callbacks; flash repayment happens after this call.
        if (msg.sender == PMHSLib.fetch().flashModule) return;

        uint256 residual = IERC20(BORROW_TOKEN()).balanceOf(address(this));
        if (residual > REPAY_RAY_ROUNDING_BUFFER) {
            IERC20(BORROW_TOKEN()).safeTransfer(POSITION_OWNER(), residual);
        }
    }

    // ── Internal — self-liquidation initiation ────────────────────────────────

    function _selfLiquidate(_SelfLiqMode mode, uint256 debtAmount, uint64 targetLtvInWad, uint64 maxSlippageInWad)
        internal
        virtual
    {
        uint64 maxAllowed = PMHSLib.fetch().maxSelfLiqSlippageInWad;
        if (maxSlippageInWad > maxAllowed) revert IPositionHelperBase.MaxSlippageTooHigh(maxSlippageInWad, maxAllowed);

        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        address borrowToken = BORROW_TOKEN();
        uint256 price = collateralPriceInBorrowTokensInRay();

        uint256 debtToFlash;
        uint256 collateralToWithdraw;

        if (mode == _SelfLiqMode.DebtAmount) {
            if (debtAmount == type(uint256).max) debtAmount = getDebtAmount();
            if (debtAmount == 0) revert IPositionHelperBase.NoDebt();

            uint64 flashPremium = IFlashModule($.flashModule).flashPremiumQuoteInWad(borrowToken, debtAmount);
            collateralToWithdraw = PMHLib.flashWithdrawAmount(debtAmount, flashPremium, maxSlippageInWad, price);
            debtToFlash = debtAmount;
        } else {
            uint256 currentDebt = getDebtAmount();
            if (currentDebt == 0) revert IPositionHelperBase.NoDebt();

            // Quote premium on full debt (rate is typically flat, amount-independent).
            uint64 flashPremium = IFlashModule($.flashModule).flashPremiumQuoteInWad(borrowToken, currentDebt);

            collateralToWithdraw = PMHLib.flashWithdrawAmountFromTargetLtv(
                targetLtvInWad, flashPremium, maxSlippageInWad, getCollateralAmount(), currentDebt, price
            );

            // 0 → already at or below target.
            if (collateralToWithdraw == 0) revert IPositionHelperBase.TargetLtvTooHigh();
            // max → target unreachable (flash + slippage cost exceeds liquidation gain).
            if (collateralToWithdraw == type(uint256).max) {
                revert IPositionHelperBase.SelfLiqCostExceedsLiquidatorBonus();
            }

            // Recover flash amount from collateral: y = x * pi/RAY * WAD/F_wad.
            uint256 F = WAD.mulDiv(WAD + uint256(flashPremium), WAD - uint256(maxSlippageInWad));
            debtToFlash = collateralToWithdraw.mulDiv(price, RAY).mulDiv(WAD, F);
        }

        bool flashSuccess = IFlashModule($.flashModule)
            .flash(
                borrowToken,
                debtToFlash,
                LoopModalityLib.pack(false, false, false, false, 0, 0),
                abi.encode(collateralToWithdraw)
            );
        if (!flashSuccess) revert IPositionHelperBase.FlashLoanFailed();
    }

    /// @inheritdoc IPositionHelperBase
    function calculateTargetRepayAmount(uint256 requiredPrincipalAmount, uint64 targetLtvInWad)
        public
        view
        override(IPositionHelperBase)
        returns (uint256)
    {
        return PMHLib.repayAmountForTargetLtv(
            collateralPriceInBorrowTokensInRay(),
            targetLtvInWad,
            getCollateralAmount(),
            requiredPrincipalAmount,
            getDebtAmount()
        );
    }

    // ── Internal — target vault operations ────────────────────────────────────

    /// @dev Deposits `assetAmount` of borrowToken into the target vault.
    /// @param transferFromOwner If true, pull borrowToken from positionOwner first.
    /// @param transferToOwner   If true, forward minted shares to positionOwner.
    function _depositOnTarget(uint256 assetAmount, bool transferFromOwner, bool transferToOwner)
        internal
        virtual
        returns (uint256)
    {
        TargetOwnerAmount memory toa;
        toa.target = yieldVault();
        toa.owner = POSITION_OWNER();
        if (transferFromOwner) IERC20(BORROW_TOKEN()).safeTransferFrom(toa.owner, address(this), assetAmount);
        address newOwner = transferToOwner ? toa.owner : address(this);
        toa.amount = IERC4626(toa.target).deposit(assetAmount, newOwner);
        emit IPositionHelperBase.DepositedOnTarget(assetAmount, toa.amount, newOwner);
        return toa.amount;
    }

    /// @dev Requests withdrawal from the target vault (yield vault)
    function _requestRedemptionFromTarget(uint256 shares) internal virtual returns (uint256 amountReceived) {
        address positionOwner_ = POSITION_OWNER();
        amountReceived = IERC4626(yieldVault()).redeem(shares, positionOwner_, positionOwner_);
        emit IPositionHelperBase.RedemptionRequestedFromTarget(shares, amountReceived, positionOwner_);
    }

    /// @dev Cancels an outstanding redemption request on the target vault.
    ///      Requires this contract to hold the `WITHDRAWAL_MANAGER_ROLE` on the vault.
    function _cancelRedemptionRequestFromTarget(uint256 requestId) internal virtual {
        address positionOwner_ = POSITION_OWNER();
        IConcreteAsyncVaultImpl(yieldVault()).cancelRequest(positionOwner_, requestId);
        emit IPositionHelperBase.RedemptionRequestCancelled(requestId);
    }

    /// @dev Claims assets from one or more fulfilled redemption requests.
    ///      Requires this contract to hold the `WITHDRAWAL_MANAGER_ROLE` on the vault.
    function _claimRedemptionFromTarget(uint256[] memory requestIds)
        internal
        virtual
        returns (uint256 withdrawnAmount)
    {
        address positionOwner_ = POSITION_OWNER();
        uint256 positionOwnerBalanceBefore = IERC20(BORROW_TOKEN()).balanceOf(positionOwner_);
        IConcreteAsyncVaultImpl(yieldVault()).claimWithdrawal(positionOwner_, requestIds);
        uint256 positionOwnerBalanceAfter = IERC20(BORROW_TOKEN()).balanceOf(positionOwner_);
        withdrawnAmount = positionOwnerBalanceAfter - positionOwnerBalanceBefore;
        emit IPositionHelperBase.RedemptionClaimedFromTarget(withdrawnAmount);
    }

    // ── Internal virtual — lender operations ──────────────────────────────────
    // These have internal bool flags not exposed in the public interface,
    // so they remain as internal virtuals overridden by the lender subclass.

    /// @dev Supply `collateralAmount` of collateralToken to the lender.
    /// @param transferFromOwner If true, pull collateralToken from positionOwner first.
    /// @param transferToOwner   If true, mint lender position tokens (e.g. aTokens) to
    ///                          positionOwner.  If false, keep them in this contract.
    ///                          In almost all cases this should be true.
    function _supply(uint256 collateralAmount, bool transferFromOwner, bool transferToOwner) internal virtual;

    /// @dev Withdraw `collateralAmount` from the lender.
    /// @param transferFromOwner If true, pull lender position tokens (e.g. aTokens) from
    ///                          positionOwner before calling pool.withdraw.
    ///                          NOTE (Aave V3): the aToken.transferFrom triggers Aave's
    ///                          health-factor check on positionOwner at that moment.
    ///                          For flash-loan self-liquidation, aTokens will already
    ///                          be in this contract — use transferFromOwner=false in that case.
    /// @param transferToOwner   If true, return underlying collateral to positionOwner.
    function _withdraw(uint256 collateralAmount, bool transferFromOwner, bool transferToOwner) internal virtual;

    /// @dev Borrow `borrowAmount` from the lender via credit delegation.
    /// @param transferToOwner If true, send borrowed tokens to positionOwner.
    function _borrow(uint256 borrowAmount, bool transferToOwner) internal virtual;

    /// @dev Lender-specific repay implementation invoked by `_repay`.
    /// @param transferFromOwner If true, pull borrowToken from positionOwner first.
    function _repayLender(uint256 borrowAmount, bool transferFromOwner) internal virtual;

    /// @dev Returns lender-specific approval booleans for positionOwner → this contract.
    ///      `lenderCollateralApproved` — approval on the lender's collateral position token
    ///                                   (e.g. aToken for Aave V3).
    ///      `lenderDebtDelegated`      — delegation to borrow on behalf of positionOwner.
    function _getLenderApprovals()
        internal
        view
        virtual
        returns (bool lenderCollateralApproved, bool lenderDebtDelegated);

    /// @dev Called directly (not via modifier) by `deploy`/`retract`/`claimAndRetract`/
    ///      `redeemAndRetract`/`selfLiquidate`/`selfLiquidateToLtv`. No-op by default. Override in
    ///      a lender subclass whose LTV math (single-reserve `getCollateralAmount`/`getDebtAmount`
    ///      combined with lender-wide `getCurrentLtvInWad`) is only valid when positionOwner holds
    ///      at most one active collateral reserve and one active debt reserve at the lender.
    function _requireSingleCollateralPosition() internal view virtual {}
}
