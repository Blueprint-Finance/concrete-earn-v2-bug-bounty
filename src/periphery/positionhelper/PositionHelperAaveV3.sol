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
// Aave V3
// ─────────────────────────────────────────────────────────────────────────────
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";
import {IPoolDataProvider} from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {ICreditDelegationToken} from "@aave/core-v3/contracts/interfaces/ICreditDelegationToken.sol";
import {UserConfiguration} from "@aave/core-v3/contracts/protocol/libraries/configuration/UserConfiguration.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {PositionHelperBase, IPositionHelperBase} from "./PositionHelperBase.sol";
import {PositionManagementHelperStorageLib as PMHSLib} from "../lib/PositionManagementHelperStorageLib.sol";
import {WAD, RAY, BASIS_POINTS_MAX} from "../lib/Constants.sol";

/// @title  PositionHelperAaveV3
/// @notice Concrete, clonable implementation of `PositionHelperBase` that
///         integrates Aave V3 as the lender.
///
/// @dev Clone lifecycle:
///   1. Deploy this implementation once with Aave infrastructure addresses.
///      The constructor calls `_disableInitializers()` — the bare implementation
///      cannot be used directly and is intended for cloning only.
///   2. For each position, deploy a clone using `ClonesWithImmutableArgs.clone`
///      with the same immutable-arg encoding as `PositionHelperBase` (62 bytes):
///        `[positionOwner (20)][collateralToken (20)][borrowToken (20)]`
///        `[collateralDecimals (1)][borrowDecimals (1)]`
///      i.e. `abi.encodePacked(positionOwner, collateralToken, borrowToken, collateralDecimals, borrowDecimals)`.
///   3. Call `initialize(...)` on the clone to set per-position state.
///
/// @dev Pre-approved allowances set in `initialize` (no per-call approvals needed):
///   • collateralToken → pool        : MAX  (supply)
///   • collateralToken → swapModule  : MAX  (self-liq swap)
///   • borrowToken     → pool        : MAX  (repay)
///   • borrowToken     → target      : MAX  (depositOnTarget)
///   • borrowToken     → flashModule : MAX  (flash repayment)
///   • yieldVault shares → yieldVault: MAX  (only relevant if the helper ever holds vault shares)
///
/// @dev Required positionOwner approvals (one-time setup):
///   | Operation           | Token                       | Mechanism                        |
///   |---------------------|-----------------------------|----------------------------------|
///   | supply              | collateralToken             | approve(helper, MAX)             |
///   | withdraw / selfLiq  | aToken (collateral reserve) | approve(helper, MAX)             |
///   | borrow              | debtToken (var or stable)   | approveDelegation(helper, MAX)   |
///   | repay               | borrowToken                 | approve(helper, MAX)             |
///   | requestRedemption   | target vault shares         | approve(helper, MAX)             |
///   | cancelRedemption /  |                             | helper must hold                 |
///   | claimRedemption     | —                           | WITHDRAWAL_MANAGER_ROLE on vault |
contract PositionHelperAaveV3 is PositionHelperBase {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;
    using UserConfiguration for DataTypes.UserConfigurationMap;

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant INTEREST_RATE_MODE = 2;

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @dev The provided token is not a configured Aave V3 reserve in this pool.
    error AaveReserveNotFound(address asset);

    /// @dev The provided borrow token reserve has no variable debt token configured.
    error AaveReserveMissingVariableDebtToken(address asset);

    /// @dev The oracle returned a zero price for the given asset.
    error OracleZeroPrice(address asset);

    // ── Immutables (shared by all clones from this implementation) ────────────

    IPoolDataProvider public immutable DATA_PROVIDER;
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    IPool public immutable POOL;
    IPriceOracleGetter public immutable PRICE_ORACLE;

    function FLAVOUR() public pure virtual returns (uint256) {
        return 1; // position helper aave v3
    }

    function ID() public pure virtual override(PositionHelperBase) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 6, 0);
    }

    /// @dev Token decimals cached to avoid repeated external calls.
    ///      These are fixed per (collateralToken, borrowToken) pair, so storing
    ///      them as implementation-level immutables is NOT appropriate — a single
    ///      implementation may back clones with different pairs.
    ///      They are instead read lazily via IERC20Metadata on each call.
    ///      If gas cost is a concern in a deployment targeting a single pair,
    ///      subclass and override the relevant helpers.

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @dev Sets all immutable Aave V3 infrastructure addresses.
    ///
    ///      `_disableInitializers()` is called here so the bare implementation
    ///      contract cannot be initialized — clones must call `initialize(...)`.
    ///
    /// @param dataProvider_      Aave V3 PoolDataProvider address.
    constructor(address dataProvider_) {
        if (dataProvider_ == address(0)) revert IPositionHelperBase.ZeroAddress();

        DATA_PROVIDER = IPoolDataProvider(dataProvider_);
        ADDRESSES_PROVIDER = IPoolDataProvider(dataProvider_).ADDRESSES_PROVIDER();
        POOL = IPool(IPoolDataProvider(dataProvider_).ADDRESSES_PROVIDER().getPool());
        PRICE_ORACLE = IPriceOracleGetter(IPoolDataProvider(dataProvider_).ADDRESSES_PROVIDER().getPriceOracle());

        // Prevent direct use of the implementation contract.
        // Clones must call initialize().
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
    function initialize(
        address admin_,
        address operator_,
        address yieldVault_,
        address flashModule_,
        address swapModule_,
        uint64 healthyLtvInWad_,
        uint64 healthyLtvDeviationInWad_,
        uint64 selfLiqThrBufferInWad_
    ) external initializer {
        if (flashModule_ == address(0)) {
            revert IPositionHelperBase.InvalidFlashModule();
        }
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
        _ltvRangeIsValid(healthyLtvInWad_, healthyLtvDeviationInWad_, selfLiqThrBufferInWad_);
        __PositionHelperAaveV3_init();
    }

    /// @dev Sets MAX token allowances for the lifetime of this clone.
    ///      Called once from `initialize`; eliminates per-operation approval calls.
    function __PositionHelperAaveV3_init() internal onlyInitializing {
        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        address pool_ = address(POOL);
        address swapModule_ = $.swapModule;
        address flashModule_ = $.flashModule;
        address _yieldVault = $.yieldVault;
        address collateral_ = COLLATERAL_TOKEN();
        address borrow_ = BORROW_TOKEN();

        // Fail fast if the clone was deployed with tokens that are not Aave reserves.
        _validateAaveReserves(collateral_, borrow_);

        // collateralToken: pool pulls for supply; swapModule pulls during self-liq.
        IERC20(collateral_).forceApprove(pool_, type(uint256).max);
        IERC20(collateral_).forceApprove(swapModule_, type(uint256).max);

        // borrowToken: pool pulls for repay; yieldVault pulls for deposit;
        //              flashModule collects (amount + premium) after executeFlash returns.
        IERC20(borrow_).forceApprove(pool_, type(uint256).max);
        IERC20(borrow_).forceApprove(_yieldVault, type(uint256).max);
        IERC20(borrow_).forceApprove(flashModule_, type(uint256).max);

        // Yield vault shares: yieldVault pulls its own shares when processing requestRedeem.
        IERC20(_yieldVault).forceApprove(_yieldVault, type(uint256).max);
    }

    // ── Approval check ────────────────────────────────────────────────────────

    /// @dev Returns Aave-specific approvals: aToken allowance and debt-token delegation.
    function _getLenderApprovals()
        internal
        view
        override
        returns (bool lenderCollateralApproved, bool lenderDebtDelegated)
    {
        address owner = POSITION_OWNER();
        address self = address(this);
        lenderCollateralApproved =
            IERC20(_getATokenAddress(COLLATERAL_TOKEN())).allowance(owner, self) == type(uint256).max;
        lenderDebtDelegated =
            ICreditDelegationToken(_getDebtTokenAddress()).borrowAllowance(owner, self) == type(uint256).max;
    }

    // ── Lender operation implementations ─────────────────────────────────────

    /// @dev Supplies `collateralAmount` of collateralToken to Aave on behalf of positionOwner,
    ///      minting aTokens directly to positionOwner.
    ///      Requires: positionOwner.approve(collateralToken, address(this), MAX)
    function _supply(uint256 collateralAmount, bool transferFromOwner, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        if (transferFromOwner) {
            IERC20(COLLATERAL_TOKEN()).safeTransferFrom(positionOwner_, address(this), collateralAmount);
        }
        address recipient = transferToOwner ? positionOwner_ : address(this);
        POOL.supply(COLLATERAL_TOKEN(), collateralAmount, recipient, 0);
        emit IPositionHelperBase.Supplied(collateralAmount);
    }

    /// @dev Pulls aTokens from positionOwner → redeems underlying via POOL.withdraw.
    ///      Requires: positionOwner.approve(aToken, address(this), MAX)
    function _withdraw(uint256 collateralAmount, bool transferFromOwner, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        if (transferFromOwner) {
            IERC20(_getATokenAddress(COLLATERAL_TOKEN()))
                .safeTransferFrom(positionOwner_, address(this), collateralAmount);
        }
        POOL.withdraw(COLLATERAL_TOKEN(), collateralAmount, address(this));
        if (transferToOwner) {
            IERC20(COLLATERAL_TOKEN()).safeTransfer(positionOwner_, collateralAmount);
        }
        emit IPositionHelperBase.Withdrawn(collateralAmount);
    }

    /// @dev Borrows from Aave on behalf of positionOwner via credit delegation.
    ///      Borrowed tokens arrive in this contract.
    ///      Requires: debtToken.approveDelegation(address(this), MAX) from positionOwner
    function _borrow(uint256 borrowAmount, bool transferToOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        POOL.borrow(BORROW_TOKEN(), borrowAmount, INTEREST_RATE_MODE, 0, positionOwner_);
        if (transferToOwner) {
            IERC20(BORROW_TOKEN()).safeTransfer(positionOwner_, borrowAmount);
        }
        emit IPositionHelperBase.Borrowed(borrowAmount);
    }

    /// @dev Repays `borrowAmount` of borrowToken debt for positionOwner at Aave.
    ///      Requires: positionOwner.approve(borrowToken, address(this), MAX)
    function _repayLender(uint256 borrowAmount, bool transferFromOwner) internal override {
        address positionOwner_ = POSITION_OWNER();
        if (transferFromOwner) {
            IERC20(BORROW_TOKEN()).safeTransferFrom(positionOwner_, address(this), borrowAmount);
        }
        uint256 actualRepaid = POOL.repay(BORROW_TOKEN(), borrowAmount, INTEREST_RATE_MODE, positionOwner_);
        emit IPositionHelperBase.Repaid(actualRepaid);
    }

    // ── ILenderModule public view overrides ───────────────────────────────────

    function getPosition() public view override returns (uint256, uint256) {
        return (getCollateralAmount(), getDebtAmount());
    }

    /// @dev Returns the aToken balance of positionOwner (collateral in token units).
    function getCollateralAmount() public view override returns (uint256) {
        return IERC20(_getATokenAddress(COLLATERAL_TOKEN())).balanceOf(POSITION_OWNER());
    }

    /// @dev Returns the debt token balance of positionOwner (debt in borrow token units).
    function getDebtAmount() public view override returns (uint256) {
        uint256 debtAmount = IERC20(_getDebtTokenAddress()).balanceOf(POSITION_OWNER());
        if (debtAmount == 0) return 0;
        return debtAmount + REPAY_RAY_ROUNDING_BUFFER;
    }

    /// @dev Computes current LTV using Aave's account data (USD-denominated ratio).
    function getCurrentLtvInWad() public view override returns (uint64) {
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = POOL.getUserAccountData(POSITION_OWNER());
        if (totalCollateralBase == 0) return 0;
        return Math.min(totalDebtBase.mulDiv(WAD, totalCollateralBase), type(uint64).max).toUint64();
    }

    /// @dev Returns the account-wide liquidation threshold in WAD, from the same
    ///      `getUserAccountData` call used by `getCurrentLtvInWad`. Aave computes this as the
    ///      collateral-value-weighted average liquidation threshold across every reserve
    ///      POSITION_OWNER() has enabled as collateral — not just COLLATERAL_TOKEN — so it
    ///      stays consistent with the account-wide LTV it is compared against.
    /// @dev Falls back to COLLATERAL_TOKEN's static reserve threshold when the account holds
    ///      no collateral at all (Aave returns 0 for currentLiquidationThreshold in that case),
    ///      so `_ltvRangeIsValid` still validates config against the lender's protocol limits
    ///      rather than reverting on an empty position.
    function getLiquidationThresholdInWad() public view override returns (uint64) {
        (uint256 totalCollateralBase,,, uint256 currentLiquidationThreshold,,) =
            POOL.getUserAccountData(POSITION_OWNER());
        if (totalCollateralBase == 0) {
            (,, currentLiquidationThreshold,,,,,,,) = DATA_PROVIDER.getReserveConfigurationData(COLLATERAL_TOKEN());
        }
        if (currentLiquidationThreshold == 0) return 0;
        return currentLiquidationThreshold.mulDiv(WAD, BASIS_POINTS_MAX).toUint64();
    }

    /// @dev Returns the maximum LTV for the collateral token in WAD.
    function getMaxLtvInWad() public view override returns (uint64) {
        (, uint256 ltv,,,,,,,,) = DATA_PROVIDER.getReserveConfigurationData(COLLATERAL_TOKEN());
        if (ltv == 0) return 0;
        return ltv.mulDiv(WAD, BASIS_POINTS_MAX).toUint64();
    }

    /// @dev Returns the current variable borrow rate in WAD (from Aave reserve data in RAY).
    function getBorrowRateInWad() public view override returns (uint64) {
        DataTypes.ReserveData memory reserve = POOL.getReserveData(BORROW_TOKEN());
        return uint256(reserve.currentVariableBorrowRate).mulDiv(WAD, RAY).toUint64();
    }

    /// @dev Returns the current supply rate in WAD (from Aave reserve data in RAY).
    function getSupplyRateInWad() public view override returns (uint64) {
        DataTypes.ReserveData memory reserve = POOL.getReserveData(COLLATERAL_TOKEN());
        return uint256(reserve.currentLiquidityRate).mulDiv(WAD, RAY).toUint64();
    }

    /// @dev Returns the price of one collateralToken expressed in borrowToken units, in RAY.
    ///
    ///      Formula:
    ///        price = (collateralPriceUSD / borrowPriceUSD)
    ///              * (10 ** borrowDecimals / 10 ** collateralDecimals)
    ///              * RAY
    function collateralPriceInBorrowTokensInRay() public view override returns (uint256) {
        uint256 collateralPrice = PRICE_ORACLE.getAssetPrice(COLLATERAL_TOKEN());
        if (collateralPrice == 0) revert OracleZeroPrice(COLLATERAL_TOKEN());
        uint256 borrowPrice = PRICE_ORACLE.getAssetPrice(BORROW_TOKEN());
        if (borrowPrice == 0) revert OracleZeroPrice(BORROW_TOKEN());
        return collateralPrice.mulDiv(RAY * 10 ** BORROW_DECIMALS(), borrowPrice * 10 ** COLLATERAL_DECIMALS());
    }

    /// @dev Returns the idle borrow-token liquidity sitting in the Aave lending pool.
    function getAvailablePoolLiquidity() public view override returns (uint256) {
        DataTypes.ReserveData memory reserve = POOL.getReserveData(BORROW_TOKEN());
        if (reserve.aTokenAddress == address(0)) return 0;
        return IERC20(BORROW_TOKEN()).balanceOf(reserve.aTokenAddress);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _validateAaveReserves(address collateral, address borrow) internal view {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(collateral);
        if (collateralReserve.aTokenAddress == address(0)) revert AaveReserveNotFound(collateral);

        DataTypes.ReserveData memory borrowReserve = POOL.getReserveData(borrow);
        if (borrowReserve.aTokenAddress == address(0)) revert AaveReserveNotFound(borrow);
        if (borrowReserve.variableDebtTokenAddress == address(0)) revert AaveReserveMissingVariableDebtToken(borrow);
    }

    function _getATokenAddress(address asset) internal view returns (address) {
        return POOL.getReserveData(asset).aTokenAddress;
    }

    function _getDebtTokenAddress() internal view returns (address) {
        DataTypes.ReserveData memory reserve = POOL.getReserveData(BORROW_TOKEN());
        return reserve.variableDebtTokenAddress;
    }

    /// @dev Enforces that positionOwner's Aave account matches the single-collateral,
    ///      single-debt assumption behind this contract's LTV math (see `getCurrentLtvInWad`,
    ///      `getLiquidationThresholdInWad`, `getMaxLtvInWad`): those combine an account-wide
    ///      current LTV with a single-reserve threshold/max-LTV, which only agree when
    ///      COLLATERAL_TOKEN is the sole active collateral reserve and BORROW_TOKEN is the sole
    ///      active debt reserve. Zero active collateral/debt is allowed (e.g. before the first
    ///      `deploy`). The reserve bitmap only reports a count, not identity, so each branch is
    ///      paired with an identity check against the reserve's `id` (its bitmap index).
    function _requireSingleCollateralPosition() internal view override {
        DataTypes.UserConfigurationMap memory cfg = POOL.getUserConfiguration(POSITION_OWNER());

        if (cfg.isUsingAsCollateralAny()) {
            uint256 collateralReserveId = POOL.getReserveData(COLLATERAL_TOKEN()).id;
            if (!cfg.isUsingAsCollateralOne() || !cfg.isUsingAsCollateral(collateralReserveId)) {
                revert IPositionHelperBase.MultipleCollateralReservesDetected();
            }
        }

        if (cfg.isBorrowingAny()) {
            uint256 borrowReserveId = POOL.getReserveData(BORROW_TOKEN()).id;
            if (!cfg.isBorrowingOne() || !cfg.isBorrowing(borrowReserveId)) {
                revert IPositionHelperBase.MultipleDebtReservesDetected();
            }
        }
    }
}
