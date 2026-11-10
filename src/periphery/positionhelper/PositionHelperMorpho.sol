// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin
// ─────────────────────────────────────────────────────────────────────────────
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Morpho Blue
// ─────────────────────────────────────────────────────────────────────────────
import {IMorpho, MarketParams, Id, Market, Position} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IIrm} from "@morpho-org/morpho-blue/src/interfaces/IIrm.sol";
import {IOracle} from "@morpho-org/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {PositionHelperBase, IPositionHelperBase} from "./PositionHelperBase.sol";
import {PositionManagementHelperStorageLib as PMHSLib} from "../lib/PositionManagementHelperStorageLib.sol";
import {PositionHelperMorphoStorageLib} from "../lib/PositionHelperMorphoStorageLib.sol";
import {WAD, RAY} from "../lib/Constants.sol";

/// @title  PositionHelperMorpho
/// @notice Concrete, clonable implementation of `PositionHelperBase` that
///         integrates Morpho Blue as the lender.
///
/// @dev Clone lifecycle:
///   1. Deploy this implementation once with the Morpho contract address.
///      The constructor calls `_disableInitializers()` — the bare implementation
///      cannot be used directly and is intended for cloning only.
///   2. For each position, deploy a clone using `ClonesWithImmutableArgs.clone`:
///         `clone(implementation, abi.encodePacked(positionOwner, collateralToken,
///                                                  borrowToken, collateralDecimals,
///                                                  borrowDecimals))`
///   3. Call `initialize(...)` on the clone to set per-position state including the
///      Morpho market params (oracle, irm, lltv).
///
/// @dev Key difference from Aave: Morpho uses isolated markets identified by a
///      `MarketParams` struct (loanToken, collateralToken, oracle, irm, lltv).
///      The `loanToken` and `collateralToken` are encoded in the clone's immutable
///      args (as borrowToken / collateralToken); oracle, irm, and lltv are stored in
///      EIP-7201 storage during `initialize`.
///
/// @dev Pre-approved allowances set in `initialize` (no per-call approvals needed):
///   • collateralToken → MORPHO     : MAX  (supplyCollateral)
///   • collateralToken → swapModule : MAX  (self-liq swap)
///   • borrowToken     → MORPHO     : MAX  (repay)
///   • borrowToken     → target     : MAX  (depositOnTarget)
///   • borrowToken     → flashModule: MAX  (flash repayment)
///   • target shares   → target     : MAX  (requestRedeem)
///
/// @dev Required positionOwner one-time setup:
///   | Operation                   | Mechanism                                         |
///   |-----------------------------|---------------------------------------------------|
///   | supply                      | collateralToken.approve(helper, MAX)              |
///   | withdraw / selfLiq / borrow | morpho.setAuthorization(helper, true)             |
///   | repay                       | borrowToken.approve(helper, MAX)                  |
///   | requestRedemption           | vaultShares.approve(helper, MAX)                  |
///   | cancelRedemption / claim    | helper must hold WITHDRAWAL_MANAGER_ROLE on vault |
///
///   A single `morpho.setAuthorization(helper, true)` call grants the helper the right
///   to withdraw collateral and borrow on positionOwner's behalf.
contract PositionHelperMorpho is PositionHelperBase {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @dev Morpho oracle prices are scaled by 1e36.
    ///      collateral_value_in_loan = collateral_amount * oraclePrice / ORACLE_PRICE_SCALE
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @dev Seconds in a year for borrow rate annualisation.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ── Immutables (shared by all clones from this implementation) ────────────

    IMorpho public immutable MORPHO;

    function FLAVOUR() public pure virtual returns (uint256) {
        return 2; // position helper morpho blue
    }

    function ID() public pure virtual override(PositionHelperBase) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 6, 0);
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @dev The market ID passed to `initialize` has not been created in Morpho Blue.
    error MarketNotFound();

    /// @dev Ensure the market ID corresponds to a market with
    ///      loanToken == BORROW_TOKEN() and collateralToken == COLLATERAL_TOKEN().
    error MarketTokenMismatch();

    /// @dev The market params fetched from Morpho do not round-trip back to the provided market id.

    /// @dev The market oracle address is zero (would make LTV/pricing unusable).
    error MarketOracleIsZero();

    /// @dev The market LLTV is invalid (expects 0 < LLTV <= 1e18).
    error MarketLltvInvalid(uint256 lltv);

    /// @dev The market oracle returned a price that cannot support LTV or price calculations.
    error InvalidOraclePrice(uint256 oraclePrice);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @dev Sets the Morpho contract address as an immutable.
    /// @param morpho_ Address of the Morpho Blue contract.
    constructor(address morpho_) {
        if (morpho_ == address(0)) revert IPositionHelperBase.ZeroAddress();
        MORPHO = IMorpho(morpho_);
        _disableInitializers();
    }

    // ── Per-clone initializer ─────────────────────────────────────────────────

    /// @notice Initializes a freshly cloned instance. Must be called exactly once.
    ///
    /// @param admin_                    Address granted `POSITION_ADMIN_ROLE`.
    /// @param operator_                 Address granted `POSITION_OPERATOR_ROLE`.
    /// @param yieldVault_               Async ERC4626 vault (asset must equal borrowToken).
    /// @param flashModule_              Flash loan module address (IFlashModule).
    /// @param swapModule_               Swap module address (ISwapModule).
    /// @param healthyLtvInWad_          Centre of the desired healthy LTV band, in WAD (1e18 = 100%).
    /// @param healthyLtvDeviationInWad_ Half-width of the healthy LTV band, in WAD. Must be > 0.
    /// @param selfLiqThrBufferInWad_    WAD buffer below liq threshold that triggers self-liq. Must be > 0.
    /// @param marketId_                 Morpho Blue market ID
    function initialize(
        address admin_,
        address operator_,
        address yieldVault_,
        address flashModule_,
        address swapModule_,
        uint64 healthyLtvInWad_,
        uint64 healthyLtvDeviationInWad_,
        uint64 selfLiqThrBufferInWad_,
        Id marketId_
    ) external initializer {
        // Validate that the market exists in Morpho Market.
        if (MORPHO.market(marketId_).lastUpdate == 0) revert MarketNotFound();

        MarketParams memory mp = MORPHO.idToMarketParams(marketId_);
        if (mp.loanToken != BORROW_TOKEN() || mp.collateralToken != COLLATERAL_TOKEN()) {
            revert MarketTokenMismatch();
        }
        if (mp.oracle == address(0)) revert MarketOracleIsZero();
        if (mp.lltv == 0) revert MarketLltvInvalid(mp.lltv);
        if (flashModule_ == address(0)) revert IPositionHelperBase.InvalidFlashModule();
        if (swapModule_ == address(0)) revert IPositionHelperBase.InvalidSwapModule();

        __PositionHelperBase_init(
            admin_,
            operator_,
            yieldVault_,
            flashModule_,
            swapModule_,
            healthyLtvInWad_,
            healthyLtvDeviationInWad_,
            selfLiqThrBufferInWad_
        );

        PositionHelperMorphoStorageLib.MorphoStorage storage $m = PositionHelperMorphoStorageLib.fetch();
        $m.marketId = marketId_;
        $m.oracle = mp.oracle;
        $m.irm = mp.irm;
        $m.lltv = mp.lltv;

        _ltvRangeIsValid(healthyLtvInWad_, healthyLtvDeviationInWad_, selfLiqThrBufferInWad_);

        __PositionHelperMorpho_init();
    }

    /// @dev Sets MAX token allowances for the lifetime of this clone.
    ///      Called once from `initialize`; eliminates per-operation approval calls.
    function __PositionHelperMorpho_init() internal onlyInitializing {
        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        address morpho_ = address(MORPHO);
        address swapModule_ = $.swapModule;
        address flashModule_ = $.flashModule;
        address yieldVault_ = $.yieldVault;
        address collateral_ = COLLATERAL_TOKEN();
        address borrow_ = BORROW_TOKEN();

        // collateralToken: Morpho pulls for supplyCollateral; swapModule pulls during self-liq.
        IERC20(collateral_).forceApprove(morpho_, type(uint256).max);
        IERC20(collateral_).forceApprove(swapModule_, type(uint256).max);

        // borrowToken: Morpho pulls for repay; yieldVault pulls for deposit;
        //              flashModule collects (amount + premium) after executeFlash returns.
        IERC20(borrow_).forceApprove(morpho_, type(uint256).max);
        IERC20(borrow_).forceApprove(yieldVault_, type(uint256).max);
        IERC20(borrow_).forceApprove(flashModule_, type(uint256).max);

        // Yield vault shares: yieldVault pulls its own shares when processing requestRedeem.
        IERC20(yieldVault_).forceApprove(yieldVault_, type(uint256).max);
    }

    // ── Approval check ────────────────────────────────────────────────────────

    /// @dev Returns Morpho-specific approvals.
    ///      In Morpho, a single `setAuthorization(helper, true)` call grants the helper
    ///      the right to both withdraw collateral and borrow on behalf of positionOwner.
    ///      This maps to both `lenderCollateralApproved` and `lenderDebtDelegated`.
    function _getLenderApprovals()
        internal
        view
        override
        returns (bool lenderCollateralApproved, bool lenderDebtDelegated)
    {
        bool authorized = MORPHO.isAuthorized(POSITION_OWNER(), address(this));
        lenderCollateralApproved = authorized;
        lenderDebtDelegated = authorized;
    }

    // ── Lender operation implementations ─────────────────────────────────────

    /// @dev Supplies `collateralAmount` of collateralToken to Morpho on behalf of positionOwner,
    ///      registering the collateral position under positionOwner's address.
    ///      Requires: positionOwner.approve(collateralToken, address(this), MAX)
    function _supply(uint256 collateralAmount, bool transferFromOwner, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        if (transferFromOwner) {
            IERC20(COLLATERAL_TOKEN()).safeTransferFrom(positionOwner_, address(this), collateralAmount);
        }
        /// there is no aToken equivalent in Morpho, so we supply the collateral directly to the positionOwner.
        MORPHO.supplyCollateral(_marketParams(), collateralAmount, positionOwner_, "");
        emit IPositionHelperBase.Supplied(collateralAmount);
    }

    /// @dev Withdraws `collateralAmount` from Morpho on behalf of positionOwner's address.
    ///      Requires: positionOwner has called morpho.setAuthorization(address(this), true).
    ///      transferToOwner is unused: Morpho tracks collateral internally under positionOwner's address.
    function _withdraw(uint256 collateralAmount, bool transferFromOwner, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        address receiver = transferToOwner ? positionOwner_ : address(this);
        // this contract must be authorized by positionOwner via setAuthorization.
        MORPHO.withdrawCollateral(_marketParams(), collateralAmount, positionOwner_, receiver);
        emit IPositionHelperBase.Withdrawn(collateralAmount);
    }

    /// @dev Borrows `borrowAmount` from Morpho on behalf of positionOwner.
    ///      Requires: positionOwner has called morpho.setAuthorization(address(this), true).
    function _borrow(uint256 borrowAmount, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        address receiver = transferToOwner ? positionOwner_ : address(this);
        // borrow(marketParams, assets, shares, onBehalf, receiver)
        // assets = borrowAmount, shares = 0
        MORPHO.borrow(_marketParams(), borrowAmount, 0, positionOwner_, receiver);
        emit IPositionHelperBase.Borrowed(borrowAmount);
    }

    /// @dev Repays `borrowAmount` of debt for positionOwner at Morpho.
    ///
    ///      Full repay (when borrowAmount >= the position's full outstanding debt) uses the
    ///      shares path to avoid the revert on excess borrow amount.
    ///      After calling `accrueInterest` at the start, the market totals are fresh, ensuring
    ///      that `toSharesDown(getDebtAmount(), freshTotals) >= borrowShares` whenever
    ///      `getDebtAmount()` (which also simulates accrual) is passed as `borrowAmount`.
    function _repayLender(uint256 borrowAmount, bool transferFromOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        if (transferFromOwner) {
            IERC20(BORROW_TOKEN()).safeTransferFrom(positionOwner_, address(this), borrowAmount);
        }

        MarketParams memory mp = _marketParams();
        Id id = _marketId();

        uint128 borrowShares = MORPHO.position(id, positionOwner_).borrowShares;
        if (borrowShares == 0) revert IPositionHelperBase.NoDebt();

        // Sync market state so share ↔ asset conversions use current totals.
        MORPHO.accrueInterest(mp);
        Market memory m = MORPHO.market(id);

        // Convert repay amount to shares (floor).  If it covers all borrow shares, use
        // the shares path so the position is fully cleared with no dust remainder.
        uint256 sharesToRepay = borrowAmount.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);

        if (sharesToRepay >= uint256(borrowShares)) {
            // Full repay: Morpho charges toAssetsUp(borrowShares, freshTotals) from this contract.
            // getDebtAmount() returns the same value (via MorphoBalancesLib), so the flash amount
            // exactly covers this charge with no surplus.
            MORPHO.repay(mp, 0, uint256(borrowShares), positionOwner_, "");
        } else {
            // Partial repay: Morpho charges exactly borrowAmount from this contract.
            MORPHO.repay(mp, borrowAmount, 0, positionOwner_, "");
        }

        emit IPositionHelperBase.Repaid(borrowAmount);
    }

    // ── ILenderModule public view overrides ───────────────────────────────────

    function getPosition() public view override returns (uint256, uint256) {
        return (getCollateralAmount(), getDebtAmount());
    }

    /// @dev Returns the raw collateral balance of positionOwner in this Morpho market.
    ///      Collateral in Morpho is always stored as raw token units (no share equivalent).
    function getCollateralAmount() public view override returns (uint256) {
        return MORPHO.position(_marketId(), POSITION_OWNER()).collateral;
    }

    /// @dev Returns the current outstanding borrow, including simulated interest accrual.
    ///      Uses `MorphoBalancesLib.expectedBorrowAssets` to avoid stale-data discrepancies
    ///      between this view and the state that Morpho operates on in `_repay`.
    function getDebtAmount() public view override returns (uint256) {
        return MORPHO.expectedBorrowAssets(_marketParams(), POSITION_OWNER());
    }

    /// @dev Computes the current LTV from collateral and debt using the Morpho market oracle.
    ///      LTV = debt / collateralValue = debt * ORACLE_PRICE_SCALE / (collateral * oraclePrice)
    function getCurrentLtvInWad() public view override returns (uint64) {
        uint256 collateral = getCollateralAmount();
        if (collateral == 0) return 0;
        uint256 debt = getDebtAmount();
        if (debt == 0) return 0;
        uint256 oraclePrice = IOracle(PositionHelperMorphoStorageLib.fetch().oracle).price();
        // collateral value in borrow tokens = collateral * oraclePrice / ORACLE_PRICE_SCALE
        // LTV in WAD = debt * WAD / collateralValue
        uint256 collateralValue = collateral.mulDiv(oraclePrice, ORACLE_PRICE_SCALE);
        if (collateralValue == 0) revert InvalidOraclePrice(oraclePrice);
        uint256 ltv = debt.mulDiv(WAD, collateralValue);
        return Math.min(ltv, type(uint64).max).toUint64();
    }

    /// @dev Morpho has a single LLTV (liquidation LTV) per market, used as both the maximum
    ///      borrow LTV and the liquidation threshold
    function getMaxLtvInWad() public view override returns (uint64) {
        return PositionHelperMorphoStorageLib.fetch().lltv.toUint64();
    }

    /// @dev Same as getMaxLtvInWad(): Morpho's LLTV is the single liquidation threshold.
    function getLiquidationThresholdInWad() public view override returns (uint64) {
        return PositionHelperMorphoStorageLib.fetch().lltv.toUint64();
    }

    /// @dev Returns the annualised borrow rate in WAD by reading the market's IRM.
    ///      `borrowRateView` returns the per-second rate in WAD; multiply by SECONDS_PER_YEAR
    ///      to annualise (linear approximation, consistent with Aave's convention).
    ///      Returns 0 if no IRM is configured for this market (irm == address(0)).
    function getBorrowRateInWad() public view override returns (uint64) {
        address irm = PositionHelperMorphoStorageLib.fetch().irm;
        if (irm == address(0)) return 0;
        MarketParams memory mp = _marketParams();
        Market memory m = MORPHO.market(mp.id());
        uint256 ratePerSecond = IIrm(irm).borrowRateView(mp, m);
        return (ratePerSecond * SECONDS_PER_YEAR).toUint64();
    }

    /// @dev Collateral in Morpho Blue earns no yield (collateral is posted but not lent out).
    ///      Returns 0 unconditionally.
    function getSupplyRateInWad() public view override returns (uint64) {
        return 0;
    }

    /// @dev Returns the price of one collateralToken expressed in borrowToken units, in RAY.
    ///
    ///      The Morpho oracle returns:
    ///        collateral_value_in_loan = collateral_amount * oraclePrice / ORACLE_PRICE_SCALE (1e36)
    ///
    ///      Converting to RAY (1e27):
    ///        rayPrice = oraclePrice * RAY / ORACLE_PRICE_SCALE = oraclePrice / 1e9
    ///
    ///      This is already decimal-adjusted (the oracle accounts for token decimals internally).
    function collateralPriceInBorrowTokensInRay() public view override returns (uint256) {
        uint256 oraclePrice = IOracle(PositionHelperMorphoStorageLib.fetch().oracle).price();
        // Catches both a zero oracle price and dust prices (< 1e9) that truncate to zero in RAY.
        uint256 priceInRay = oraclePrice.mulDiv(RAY, ORACLE_PRICE_SCALE);
        if (priceInRay == 0) revert InvalidOraclePrice(oraclePrice);
        return priceInRay;
    }

    /// @dev Returns the amount of borrow tokens currently available to borrow.
    ///      Available liquidity = totalSupplyAssets − totalBorrowAssets (uses stale market data,
    ///      which is a close approximation; exact value requires a preceding accrueInterest call).
    function getAvailablePoolLiquidity() public view override returns (uint256) {
        Market memory m = MORPHO.market(_marketId());
        uint256 totalSupply = m.totalSupplyAssets;
        uint256 totalBorrow = m.totalBorrowAssets;
        return totalSupply > totalBorrow ? totalSupply - totalBorrow : 0;
    }

    // ── Storage views ─────────────────────────────────────────────────────────

    /// @notice Returns the Morpho Blue market ID for this clone's market.
    function marketId() public view returns (Id) {
        return PositionHelperMorphoStorageLib.fetch().marketId;
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Builds the MarketParams struct from EIP-7201 storage.
    ///      All fields (loanToken, collateralToken, oracle, irm, lltv) were validated and
    ///      cached from Morpho Blue at initialize time.
    function _marketParams() internal view returns (MarketParams memory) {
        PositionHelperMorphoStorageLib.MorphoStorage storage $m = PositionHelperMorphoStorageLib.fetch();
        return MarketParams({
            loanToken: BORROW_TOKEN(),
            collateralToken: COLLATERAL_TOKEN(),
            oracle: $m.oracle,
            irm: $m.irm,
            lltv: $m.lltv
        });
    }

    /// @dev Returns the Morpho market Id for this clone's market.
    function _marketId() internal view returns (Id) {
        return PositionHelperMorphoStorageLib.fetch().marketId;
    }
}
