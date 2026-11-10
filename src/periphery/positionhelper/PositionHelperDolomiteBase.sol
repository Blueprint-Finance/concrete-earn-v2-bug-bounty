// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin
// ─────────────────────────────────────────────────────────────────────────────
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Dolomite
// ─────────────────────────────────────────────────────────────────────────────
import {IDolomiteMargin} from "../interface/IDolomiteMargin.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {PositionHelperBase, IPositionHelperBase} from "./PositionHelperBase.sol";
import {PositionManagementHelperStorageLib as PMHSLib} from "../lib/PositionManagementHelperStorageLib.sol";
import {DolomiteAccountActionLib} from "../lib/DolomiteAccountActionLib.sol";
import {DolomitePositionViewLib} from "../lib/DolomitePositionViewLib.sol";
import {DolomiteInitLib} from "../lib/DolomiteInitLib.sol";

/// @title  PositionHelperDolomiteBase
/// @notice Abstract base shared by every concrete Dolomite position-helper flavour
///         (e.g. `PositionHelperDolomiteNative`, `PositionHelperDolomiteAssetCX`).
///         Holds everything that does not depend on how a flavour performs self-liquidation:
///         supply/withdraw/borrow/repay primitives, position/LTV/margin views, market-ID
///         resolution, and sub-account transfers.
///
/// @dev Clone lifecycle:
///   1. Deploy a concrete flavour's implementation once with the DolomiteMargin contract address.
///      The constructor calls `_disableInitializers()` — the bare implementation
///      cannot be used directly and is intended for cloning only.
///   2. For each position, deploy a clone via `PeripheryFactory.clonePMH`. The factory
///      calls `resolveTokenId` on this implementation to append the two market IDs to
///      the standard 62-byte immutable args, giving a 126-byte blob:
///         `[positionOwner(20)][collateralToken(20)][borrowToken(20)]`
///         `[collateralDecimals(1)][borrowDecimals(1)]`
///         `[collateralMarketId(32)][borrowMarketId(32)]`
///   3. Call `initialize(...)` on the clone to set per-position state. Each concrete flavour
///      declares its own `initialize`, since the self-liquidation mechanism it configures differs.
///
/// @dev Key difference from Aave / Morpho: Dolomite uses a single `operate` call
///      with a list of `ActionArgs` to perform all operations (deposit, withdraw, borrow,
///      repay). Every position is identified by an `Account.Info { owner, number }` pair —
///      `owner` is always `POSITION_OWNER()`; `number` is passed by the caller per operation.
///
/// @dev Pre-approved allowances set in `__PositionHelperDolomiteBase_init` (no per-call approvals needed):
///   • collateralToken → DOLOMITE_MARGIN : MAX  (Deposit action)
///   • collateralToken → swapModule      : MAX  (self-liq swap)
///   • borrowToken     → DOLOMITE_MARGIN : MAX  (repay via Deposit action)
///   • borrowToken     → target          : MAX  (depositOnTarget)
///   • borrowToken     → flashModule     : MAX  (flash repayment)
///   • target shares   → target          : MAX  (requestRedeem)
///
/// @dev Required positionOwner one-time setup:
///   | Operation                   | Mechanism                                                    |
///   |-----------------------------|--------------------------------------------------------------|
///   | supply / withdraw / borrow  | DOLOMITE_MARGIN.setOperators([{operator: helper, true}])     |
///   | repay                       | borrowToken.approve(helper, MAX)                             |
///   | requestRedemption           | vaultShares.approve(helper, MAX)                             |
///   | cancelRedemption / claim    | helper must hold WITHDRAWAL_MANAGER_ROLE on vault            |
///
///   A single `setOperators` call grants the helper the right to act on positionOwner's
///   Dolomite sub-account (withdraw collateral and borrow on their behalf).
abstract contract PositionHelperDolomiteBase is PositionHelperBase {
    using SafeERC20 for IERC20;
    using DolomitePositionViewLib for IDolomiteMargin;

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @dev Byte offsets for the two extra immutable args appended by the factory.
    uint256 internal constant COLLATERAL_MARKET_ID_OFFSET = 62;
    uint256 internal constant BORROW_MARKET_ID_OFFSET = 94;

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @dev Reverts when a concrete flavour's dedicated liquidation mechanism and the
    ///      flash+swap modules are both absent. At least one liquidation mechanism must be
    ///      configured at initialization.
    error MissingLiquidationMechanism();
    /// @dev Reverts when a non-admin, non-operator caller attempts a transfer.
    error SenderNeitherAdminNorOperator(address caller);
    /// @dev Reverts when an operator (non-admin) caller's transfer leaves either sub-account
    ///      touched by the transfer with its LTV in the self-liquidation danger zone. Only
    ///      admin may proceed in that state.
    error AccountLeftInSelfLiqZone(address caller);
    /// @dev Reverts when the caller passes a marketId that is neither COLLATERAL_MARKET_ID nor BORROW_MARKET_ID.
    error InvalidMarketId(uint256 marketId);

    // ── Transfer guards ───────────────────────────────────────────────────────

    /// @dev Validates `marketId` and the caller's role ahead of a sub-account transfer. Plain
    ///      internal functions (unlike modifiers, which get inlined into every function that uses
    ///      them) are compiled once and shared via `JUMP` — called from both
    ///      `transferToDefaultAccount` and `transferFromDefaultAccount` instead of a modifier.
    ///      A caller with neither the admin nor the operator role may never transfer.
    function _requireCanTransfer(uint256 marketId) internal view returns (bool isAdmin) {
        isAdmin = hasRole(POSITION_ADMIN_ROLE, msg.sender);
        if (!isAdmin && !hasRole(POSITION_OPERATOR_ROLE, msg.sender)) {
            revert SenderNeitherAdminNorOperator(msg.sender);
        }
        if (marketId != COLLATERAL_MARKET_ID() && marketId != BORROW_MARKET_ID()) {
            revert InvalidMarketId(marketId);
        }
    }

    /// @dev Admin may always transfer between sub-accounts. Operator may only transfer if, after
    ///      the transfer of collateral or debt completes, both `otherAccountNumber` and
    ///      `ACCOUNT_NUMBER` remain below the self-liquidation danger zone (liquidation threshold
    ///      minus selfLiqThrBuffer) — checked post-transfer since that's exactly the state the
    ///      transfer itself could push into the danger zone. Which of the two is the "source" and
    ///      which is the "destination" doesn't matter: both must end up safe regardless of
    ///      transfer direction.
    function _requireTransferLeftAccountsSafe(bool isAdmin, uint256 otherAccountNumber) internal view {
        if (!isAdmin && (!_isSafe(otherAccountNumber) || !_isSafe(ACCOUNT_NUMBER))) {
            revert AccountLeftInSelfLiqZone(msg.sender);
        }
    }

    /// @dev True when `accountNr`'s LTV is below the self-liquidation danger zone
    ///      (liquidation threshold minus selfLiqThrBuffer), and `accountNr` holds only the
    ///      configured collateral/borrow market pair.
    ///
    ///      `_getCurrentLtvInWad` sums USD value across every market the account holds, while
    ///      `_getLiquidationThresholdForAccount` derives its threshold only from
    ///      COLLATERAL_MARKET_ID/BORROW_MARKET_ID's margin premiums. If `accountNr` also holds
    ///      other markets — e.g. a sub-account the caller uses for unrelated positions — that
    ///      comparison no longer bounds the account's real liquidation risk, so an operator
    ///      transfer could leave it closer to liquidation than the buffer permits. Such an
    ///      account is therefore treated as unsafe rather than trusted; only admin may still
    ///      transfer against it.
    function _isSafe(uint256 accountNr) internal view returns (bool) {
        (bool singleCollateral, bool singleDebt) = _isSingleCollateralAndDebtMarket(accountNr);
        if (!singleCollateral || !singleDebt) return false;
        return (uint256(_getCurrentLtvInWad(accountNr)) + PMHSLib.fetch().selfLiqThrBufferInWad)
            < _getLiquidationThresholdForAccount(accountNr);
    }

    // ── Immutables (shared by all clones from this implementation) ────────────

    IDolomiteMargin public immutable DOLOMITE_MARGIN;

    /// @dev Dolomite sub-account used for all position operations from this implementation.
    ///      Commonly 0 (the default public account for a given owner), but configurable per
    ///      deployment since some flavours target a non-default sub-account.
    uint256 public immutable ACCOUNT_NUMBER;

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param dolomiteMargin_ Address of the DolomiteMargin contract.
    /// @param accountNumber_  Dolomite sub-account number used for all position operations.
    constructor(address dolomiteMargin_, uint256 accountNumber_) {
        if (dolomiteMargin_ == address(0)) revert IPositionHelperBase.ZeroAddress();
        DOLOMITE_MARGIN = IDolomiteMargin(dolomiteMargin_);
        ACCOUNT_NUMBER = accountNumber_;
        _disableInitializers();
    }

    /// @dev Validates encoded market IDs and sets MAX token allowances for the lifetime of
    ///      this clone. Called once from the concrete flavour's own `initialize(...)`, after
    ///      `__PositionHelperBase_init`.
    function __PositionHelperDolomiteBase_init() internal onlyInitializing {
        DolomiteInitLib.init(
            address(DOLOMITE_MARGIN), COLLATERAL_TOKEN(), BORROW_TOKEN(), COLLATERAL_MARKET_ID(), BORROW_MARKET_ID()
        );
    }

    // ── Clone immutable arg readers ───────────────────────────────────────────

    /// @notice Dolomite market ID for the collateral token. Encoded in clone immutable args.
    function COLLATERAL_MARKET_ID() public pure returns (uint256) {
        return _getArgUint256(COLLATERAL_MARKET_ID_OFFSET);
    }

    /// @notice Dolomite market ID for the borrow token. Encoded in clone immutable args.
    function BORROW_MARKET_ID() public pure returns (uint256) {
        return _getArgUint256(BORROW_MARKET_ID_OFFSET);
    }

    // ── Market ID resolver (called by factory at clone time) ──────────────────

    /// @notice Resolves a token address to its DolomiteMargin market ID.
    ///         Called by `PeripheryFactory._getImmutableArgs` on the implementation
    ///         contract to populate the immutable args of each clone.
    function resolveTokenInfo(address token) external view returns (uint256) {
        return DOLOMITE_MARGIN.getMarketIdByTokenAddress(token);
    }

    // ── Approval check ────────────────────────────────────────────────────────

    /// @dev A single `setOperators([{operator: helper, approved: true}])` call on DolomiteMargin
    ///      grants the helper authority over positionOwner's sub-account for both supply and borrow.
    function _getLenderApprovals()
        internal
        view
        virtual
        override
        returns (bool lenderCollateralApproved, bool lenderDebtDelegated)
    {
        bool isOperator = DOLOMITE_MARGIN.getIsLocalOperator(POSITION_OWNER(), address(this));
        lenderCollateralApproved = isOperator;
        lenderDebtDelegated = isOperator;
    }

    // ── Lender operation implementations ─────────────────────────────────────

    /// @dev Supplies `collateralAmount` of collateralToken into positionOwner's default account (0).
    ///      Unlike Aave there is no receipt token to route — positionOwner is always the account owner.
    function _supply(uint256 collateralAmount, bool transferFromOwner, bool) internal override {
        address positionOwner_ = POSITION_OWNER();
        if (transferFromOwner) {
            IERC20(COLLATERAL_TOKEN()).safeTransferFrom(positionOwner_, address(this), collateralAmount);
        }
        DolomiteAccountActionLib.deposit(
            DOLOMITE_MARGIN, positionOwner_, ACCOUNT_NUMBER, COLLATERAL_MARKET_ID(), collateralAmount, address(this)
        );
        emit IPositionHelperBase.Supplied(collateralAmount);
    }

    /// @dev Withdraws `collateralAmount` from positionOwner's default account (0).
    ///      `transferFromOwner` is unused — there are no aTokens; the helper acts as operator.
    ///      `transferToOwner = true`  → tokens sent directly to positionOwner.
    ///      `transferToOwner = false` → tokens stay in address(this) (e.g. for self-liq flows).
    function _withdraw(uint256 collateralAmount, bool, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        DolomiteAccountActionLib.withdraw(
            DOLOMITE_MARGIN,
            positionOwner_,
            ACCOUNT_NUMBER,
            COLLATERAL_MARKET_ID(),
            collateralAmount,
            transferToOwner ? positionOwner_ : address(this)
        );
        emit IPositionHelperBase.Withdrawn(collateralAmount);
    }

    /// @dev Borrows `borrowAmount` by issuing a Withdraw on the borrow market, creating or
    ///      increasing a negative balance (debt) on positionOwner's default account.
    function _borrow(uint256 borrowAmount, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        DolomiteAccountActionLib.withdraw(
            DOLOMITE_MARGIN,
            positionOwner_,
            ACCOUNT_NUMBER,
            BORROW_MARKET_ID(),
            borrowAmount,
            transferToOwner ? positionOwner_ : address(this)
        );
        emit IPositionHelperBase.Borrowed(borrowAmount);
    }

    /// @dev Repays `borrowAmount` by depositing borrow tokens into positionOwner's default account,
    ///      reducing the negative balance in the borrow market.
    ///      When `transferFromOwner` is false, tokens must already be in address(this).
    function _repayLender(uint256 borrowAmount, bool transferFromOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        if (transferFromOwner) {
            IERC20(BORROW_TOKEN()).safeTransferFrom(positionOwner_, address(this), borrowAmount);
        }
        DolomiteAccountActionLib.deposit(
            DOLOMITE_MARGIN, positionOwner_, ACCOUNT_NUMBER, BORROW_MARKET_ID(), borrowAmount, address(this)
        );
        emit IPositionHelperBase.Repaid(borrowAmount);
    }

    // ── ILenderModule public view overrides ───────────────────────────────────

    function getPosition() public view virtual override returns (uint256, uint256) {
        return _getPosition(ACCOUNT_NUMBER);
    }

    function getCollateralAmount() public view virtual override returns (uint256) {
        return _getCollateralAmount(ACCOUNT_NUMBER);
    }

    function getDebtAmount() public view virtual override returns (uint256) {
        return _getDebtAmount(ACCOUNT_NUMBER);
    }

    function getCurrentLtvInWad() public view override returns (uint64) {
        return _getCurrentLtvInWad(ACCOUNT_NUMBER);
    }

    /// @dev Liquidation threshold = WAD / (WAD + effectiveMarginRatio).
    ///      An account becomes liquidatable when its LTV exceeds this value.
    function getLiquidationThresholdInWad() public view override returns (uint64) {
        return _getLiquidationThresholdForAccount(ACCOUNT_NUMBER);
    }

    /// @dev Delegates to `DolomitePositionViewLib` — see that library for the formula.
    function _getLiquidationThresholdForAccount(uint256 accountNr) internal view returns (uint64) {
        return DOLOMITE_MARGIN.getLiquidationThresholdForAccount(
            POSITION_OWNER(), accountNr, COLLATERAL_MARKET_ID(), BORROW_MARKET_ID()
        );
    }

    /// @dev Dolomite has no separate borrow cap LTV — the margin ratio is both the safety buffer
    ///      and the liquidation trigger. Max LTV equals the liquidation threshold.
    function getMaxLtvInWad() public view override returns (uint64) {
        return _getLiquidationThresholdForAccount(ACCOUNT_NUMBER);
    }

    /// @dev Annualised borrow interest rate on the borrow market, in WAD (1e18 = 100% APR).
    function getBorrowRateInWad() public view override returns (uint64) {
        return DOLOMITE_MARGIN.getBorrowRateInWad(BORROW_MARKET_ID());
    }

    /// @dev Annualised supply interest rate earned on the collateral market, in WAD (1e18 = 100% APR).
    function getSupplyRateInWad() public view override returns (uint64) {
        return DOLOMITE_MARGIN.getSupplyRateInWad(COLLATERAL_MARKET_ID());
    }

    /// @dev Price of 1 wei of collateral expressed in wei of borrow token, in RAY (1e27 = 1.0).
    ///      Delegates to `DolomitePositionViewLib` — see that library for the conversion.
    function collateralPriceInBorrowTokensInRay() public view override returns (uint256) {
        return DOLOMITE_MARGIN.collateralPriceInBorrowTokensInRay(COLLATERAL_MARKET_ID(), BORROW_MARKET_ID());
    }

    /// @dev Fraction of borrow interest passed to suppliers, in WAD.
    ///      This is a single protocol-wide constant — not configurable per market.
    ///      supplyRate = borrowRate × utilization × earningsRate
    function getEarningsRate() public view returns (uint256) {
        return DOLOMITE_MARGIN.getEarningsRate();
    }

    /// @dev Available borrow-token liquidity = actual token balance held by DolomiteMargin.
    ///      Dolomite holds real tokens directly (no aToken indirection), so the protocol
    ///      contract balance is the canonical borrowable ceiling, analogous to
    ///      `IERC20(borrowToken).balanceOf(aTokenAddress)` on Aave V3.
    function getAvailablePoolLiquidity() public view override returns (uint256) {
        return DOLOMITE_MARGIN.getAvailablePoolLiquidity(BORROW_TOKEN());
    }

    // ── Account transfers ─────────────────────────────────────────────────────

    /// @notice Transfers `marketId` tokens (supply or debt) from positionOwner's
    ///         `fromAccountNumber` sub-account to their default account (0).
    ///         `marketId` must be `COLLATERAL_MARKET_ID()` or `BORROW_MARKET_ID()`.
    ///         Pass `type(uint256).max` to move the full signed balance.
    function transferToDefaultAccount(uint256 marketId, uint256 amountWei, uint256 fromAccountNumber) external {
        bool isAdmin = _requireCanTransfer(marketId);
        DolomiteAccountActionLib.transfer(
            DOLOMITE_MARGIN, POSITION_OWNER(), fromAccountNumber, POSITION_OWNER(), ACCOUNT_NUMBER, marketId, amountWei
        );
        _requireTransferLeftAccountsSafe(isAdmin, fromAccountNumber);
    }

    /// @notice Transfers `marketId` tokens (supply or debt) from positionOwner's default
    ///         account (0) to their `toAccountNumber` sub-account.
    ///         `marketId` must be `COLLATERAL_MARKET_ID()` or `BORROW_MARKET_ID()`.
    ///         Pass `type(uint256).max` to move the full signed balance.
    function transferFromDefaultAccount(uint256 marketId, uint256 amountWei, uint256 toAccountNumber) external {
        bool isAdmin = _requireCanTransfer(marketId);
        DolomiteAccountActionLib.transfer(
            DOLOMITE_MARGIN, POSITION_OWNER(), ACCOUNT_NUMBER, POSITION_OWNER(), toAccountNumber, marketId, amountWei
        );
        _requireTransferLeftAccountsSafe(isAdmin, toAccountNumber);
    }

    // ── Internal per-account view helpers ────────────────────────────────────

    /// @dev Returns `(collateral, debt)` in token units for `(POSITION_OWNER, accountNr)`.
    function _getPosition(uint256 accountNr) internal view returns (uint256, uint256) {
        return (_getCollateralAmount(accountNr), _getDebtAmount(accountNr));
    }

    /// @dev Collateral held in `accountNr` in token units.
    ///      Returns 0 if the balance is negative (should not happen for collateral market).
    ///      Delegates to `DolomitePositionViewLib`.
    function _getCollateralAmount(uint256 accountNr) internal view returns (uint256) {
        return DOLOMITE_MARGIN.getCollateralAmount(POSITION_OWNER(), accountNr, COLLATERAL_MARKET_ID());
    }

    /// @dev Debt owed in `accountNr` in token units.
    ///      Returns 0 if the balance is positive (no borrow).
    ///      Delegates to `DolomitePositionViewLib`.
    function _getDebtAmount(uint256 accountNr) internal view returns (uint256) {
        return DOLOMITE_MARGIN.getDebtAmount(POSITION_OWNER(), accountNr, BORROW_MARKET_ID());
    }

    /// @dev Current LTV for `accountNr` in WAD, computed from USD account values.
    ///      Uses getAccountValues which prices all assets in the account — accurate only
    ///      when the account holds exactly the collateral and borrow token and nothing else.
    ///      Delegates to `DolomitePositionViewLib`.
    function _getCurrentLtvInWad(uint256 accountNr) internal view returns (uint64) {
        return DOLOMITE_MARGIN.getCurrentLtvInWad(POSITION_OWNER(), accountNr);
    }

    // ── Single-collateral-position guard ──────────────────────────────────────

    /// @dev Enforces that positionOwner's ACCOUNT_NUMBER sub-account matches the single-collateral,
    ///      single-debt assumption behind this contract's LTV math (see `getCurrentLtvInWad`,
    ///      `getLiquidationThresholdInWad`, `getMaxLtvInWad`): those combine an account-wide
    ///      current LTV with a single-market threshold/max-LTV, which only agree when
    ///      COLLATERAL_MARKET_ID is the sole positive balance and BORROW_MARKET_ID is the sole
    ///      negative balance held by the sub-account. Zero balances are allowed (e.g. before the
    ///      first `deploy`). Shared by every Dolomite flavour cloned from this implementation.
    function _requireSingleCollateralPosition() internal view override {
        (bool singleCollateral, bool singleDebt) = _isSingleCollateralAndDebtMarket(ACCOUNT_NUMBER);
        if (!singleCollateral) revert IPositionHelperBase.MultipleCollateralReservesDetected();
        if (!singleDebt) revert IPositionHelperBase.MultipleDebtReservesDetected();
    }

    /// @dev Delegates to `DolomitePositionViewLib` — see that library for the identity-check logic.
    function _isSingleCollateralAndDebtMarket(uint256 accountNr)
        internal
        view
        returns (bool singleCollateral, bool singleDebt)
    {
        return DOLOMITE_MARGIN.isSingleCollateralAndDebtMarket(
            POSITION_OWNER(), accountNr, COLLATERAL_MARKET_ID(), BORROW_MARKET_ID()
        );
    }
}
