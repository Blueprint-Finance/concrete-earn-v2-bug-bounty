// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {ILenderModule} from "../interface/ILenderModule.sol";
import {WAD, RAY, BASIS_POINTS_MAX} from "../lib/Constants.sol";
import {TokenPair} from "../interface/ILoopingPrimitive.sol";

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";
import {IPoolDataProvider} from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AaveV3LenderAdapterStorageLib as AV3LADSL} from "./AaveV3LenderAdapterStorageLib.sol";
import {SimpleLenderOpTraits} from "../traits/LenderTraits.sol";

contract AaveV3LenderAdapter is ILenderModule, Initializable, SimpleLenderOpTraits, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    event StrategySet(address indexed strategy);

    error ZeroAddress();
    error UnsupportedInterestRateMode();
    error InvalidPool();
    error InvalidPriceOracle();
    error InvalidCollateralPrice();
    error InvalidDebtPrice();
    error Unauthorized();
    error ZeroStrategyAddress();

    /// @notice Safety buffer added when sizing a full debt repayment.
    /// @dev Aave-style variable debt is stored in scaled units and converted
    ///      to underlying amounts using ray (1e27) fixed-point arithmetic.
    ///      Conversions between scaled debt and underlying are not perfectly
    ///      invertible due to integer rounding, which can leave a small
    ///      residual debt (1–few minimal units) when repaying an amount
    ///      computed from a quoted balance.
    ///      This buffer intentionally over-sizes the repayment amount to
    ///      guarantee that the entire scaled debt is burned and the position
    ///      can always be fully unwound, without relying on MAX_UINT semantics.
    uint256 internal constant DEFAULT_REPAY_RAY_ROUNDING_BUFFER = 4;
    uint256 internal constant STABLE_RATE_MODE = 1;
    uint256 internal constant VARIABLE_RATE_MODE = 2;

    address public immutable override COLLATERAL_TOKEN;
    uint8 public immutable collateralDecimals;
    address public immutable override BORROW_TOKEN;
    uint8 public immutable borrowDecimals;
    IPoolDataProvider public immutable dataProvider;
    IPoolAddressesProvider public immutable addressesProvider;
    IPool public immutable pool;
    IPriceOracleGetter public immutable priceOracle;

    constructor(address collateralToken_, address borrowToken_, address dataProvider_) {
        _disableInitializers();

        if (collateralToken_ == address(0) || borrowToken_ == address(0) || dataProvider_ == address(0)) {
            revert ZeroAddress();
        }

        COLLATERAL_TOKEN = collateralToken_;
        collateralDecimals = IERC20Metadata(collateralToken_).decimals();
        BORROW_TOKEN = borrowToken_;
        borrowDecimals = IERC20Metadata(borrowToken_).decimals();
        dataProvider = IPoolDataProvider(dataProvider_);

        addressesProvider = dataProvider.ADDRESSES_PROVIDER();
        address poolAddr = addressesProvider.getPool();
        if (poolAddr == address(0)) revert InvalidPool();
        pool = IPool(poolAddr);

        address oracleAddr = addressesProvider.getPriceOracle();
        if (oracleAddr == address(0)) revert InvalidPriceOracle();
        priceOracle = IPriceOracleGetter(oracleAddr);
    }

    function __AaveV3LenderAdapter_init(address admin_, uint256 interestRateMode_) internal virtual {
        if (interestRateMode_ != STABLE_RATE_MODE && interestRateMode_ != VARIABLE_RATE_MODE) {
            revert UnsupportedInterestRateMode();
        }
        if (admin_ == address(0)) revert ZeroAddress();
        __Ownable_init(admin_);
        AV3LADSL.fetch().interestRateMode = interestRateMode_;
    }

    function setStrategy(address strategy_) external onlyOwner {
        if (strategy_ == address(0)) revert ZeroAddress();
        AV3LADSL.fetch().strategy = strategy_;
        emit StrategySet(strategy_);
    }

    // Modifiers
    modifier onlyStrategy() {
        address strategy = AV3LADSL.fetch().strategy;
        if (strategy == address(0)) revert ZeroStrategyAddress();
        require(msg.sender == strategy, Unauthorized());
        _;
    }

    modifier onlyStrategyOrOwner() {
        address strategy = AV3LADSL.fetch().strategy;
        if (strategy == address(0)) revert ZeroStrategyAddress();
        require(msg.sender == strategy || msg.sender == owner(), Unauthorized());
        _;
    }

    // -----------------------------------------------------------------------
    // Supply
    // -----------------------------------------------------------------------

    function supply(uint256 amount) external virtual override onlyStrategyOrOwner {
        if (amount == 0) return;
        // pull amount
        IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        // supply amount
        _supply(amount);
    }

    // This function assumes that the amount is already in the contract.
    function _supply(uint256 amount) internal virtual override {
        IERC20(COLLATERAL_TOKEN).forceApprove(address(pool), amount);
        pool.supply(COLLATERAL_TOKEN, amount, address(this), 0);
    }

    //-----------------------------------------------------------------------
    // Withdraw
    //-----------------------------------------------------------------------

    function withdraw(uint256 amount) external virtual override onlyStrategy {
        if (amount == 0) return;
        _withdraw(amount);
        IERC20(COLLATERAL_TOKEN).safeTransfer(msg.sender, amount);
    }

    function _withdraw(uint256 amount) internal virtual override {
        uint256 withdrawn = pool.withdraw(COLLATERAL_TOKEN, amount, address(this));
    }

    //-----------------------------------------------------------------------
    // Borrow
    //-----------------------------------------------------------------------

    function borrow(uint256 amount) external virtual override onlyStrategy {
        if (amount == 0) return;
        _borrow(amount);
        IERC20(BORROW_TOKEN).safeTransfer(msg.sender, amount);
    }

    function _borrow(uint256 amount) internal virtual override {
        pool.borrow(BORROW_TOKEN, amount, AV3LADSL.fetch().interestRateMode, 0, address(this));
    }

    //-----------------------------------------------------------------------
    // Repay
    //-----------------------------------------------------------------------

    function repay(uint256 amount) external virtual override onlyStrategyOrOwner {
        if (amount == 0) return;
        IERC20(BORROW_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _repay(amount);
    }

    function _repay(uint256 amount) internal virtual override {
        IERC20(BORROW_TOKEN).forceApprove(address(pool), amount);
        pool.repay(BORROW_TOKEN, amount, AV3LADSL.fetch().interestRateMode, address(this));
    }

    // -----------------------------------------------------------------------
    // View helpers
    // -----------------------------------------------------------------------

    function getCollateralAmount() public view virtual override returns (uint256) {
        DataTypes.ReserveData memory reserve = pool.getReserveData(COLLATERAL_TOKEN);
        return IERC20(reserve.aTokenAddress).balanceOf(address(this));
    }

    function getDebtAmount() public view virtual override returns (uint256) {
        DataTypes.ReserveData memory reserve = pool.getReserveData(BORROW_TOKEN);
        address debtTokenAddress = AV3LADSL.fetch().interestRateMode == STABLE_RATE_MODE
            ? reserve.stableDebtTokenAddress
            : reserve.variableDebtTokenAddress;
        uint256 scaledBalance = IERC20(debtTokenAddress).balanceOf(address(this));
        if (scaledBalance == 0) return 0;
        return scaledBalance + _repayRayRoundingBuffer();
    }

    function getBorrowRateInWad() external view virtual override returns (uint64) {
        DataTypes.ReserveData memory reserve = pool.getReserveData(BORROW_TOKEN);
        uint256 borrowRateInRay = AV3LADSL.fetch().interestRateMode == STABLE_RATE_MODE
            ? reserve.currentStableBorrowRate
            : reserve.currentVariableBorrowRate;
        return _rayToWad(borrowRateInRay);
    }

    function getSupplyRateInWad() external view virtual override returns (uint64) {
        DataTypes.ReserveData memory reserve = pool.getReserveData(COLLATERAL_TOKEN);
        return _rayToWad(reserve.currentLiquidityRate);
    }

    function getCurrentEstimatedRewards() external view virtual returns (uint64 rateInWad, uint256 amount) {
        return (0, 0);
    }

    /**
     * @notice Returns the price of one base unit of collateral token in terms of base units of borrow token, quoted in RAY.
     * @dev This is the native-onchain way of quoting prices, so that collateral amounts can be converted into borrow token amounts and vice versa without the need to use decimals.
     * @return The price of one base unit of collateral token in terms of base units of borrow token, quoted in RAY.
     */
    function collateralPriceInBorrowTokensInRay() public view virtual override returns (uint256) {
        // price of one token/display unit (e.g. for WETH it is 1 WETH) in USD
        uint256 collateralPrice = priceOracle.getAssetPrice(COLLATERAL_TOKEN);
        // price of one token/display unit (e.g. for USDC it is 1 USDC) in USD
        uint256 debtPrice = priceOracle.getAssetPrice(BORROW_TOKEN);
        if (collateralPrice == 0) revert InvalidCollateralPrice();
        if (debtPrice == 0) revert InvalidDebtPrice();
        // we would like to quote the price of one base unit (e.g. for WETH it is 1 Wei, so 1 ETH = 10^18 Wei)
        // in terms of borrow token base units (e.g. for USDC it is 1 micro USDC, so 1 USDC = 10^6 micro USDC)
        // and that price is quoted in RAY. So if 1 ETH Wei were worth 1 micro USDC (i.e. very expensive ETH)
        // then the price quote should be 1 RAY.
        if (borrowDecimals >= collateralDecimals) {
            return collateralPrice.mulDiv(RAY, debtPrice) * 10 ** (borrowDecimals - collateralDecimals);
        } else {
            return collateralPrice.mulDiv(RAY, debtPrice) / 10 ** (collateralDecimals - borrowDecimals);
        }
    }

    function getCurrentLtvInWad() public view virtual override returns (uint64) {
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = pool.getUserAccountData(address(this));
        if (totalCollateralBase == 0) return 0;
        return Math.min(Math.mulDiv(totalDebtBase, WAD, totalCollateralBase), type(uint64).max).toUint64();
    }

    function getMaxLtvInWad() public view virtual override returns (uint64) {
        (, uint256 ltv,,,,,,,,) = dataProvider.getReserveConfigurationData(COLLATERAL_TOKEN);
        if (ltv == 0) return 0;
        return Math.mulDiv(ltv, WAD, BASIS_POINTS_MAX).toUint64();
    }

    function getAvailablePoolLiquidity() public view virtual override returns (uint256) {
        DataTypes.ReserveData memory reserve = pool.getReserveData(COLLATERAL_TOKEN);
        if (reserve.aTokenAddress == address(0)) return 0;
        return IERC20(COLLATERAL_TOKEN).balanceOf(reserve.aTokenAddress);
    }

    // -----------------------------------------------------------------------
    // Token And Position related functions
    // -----------------------------------------------------------------------

    function getTokenPair() external view virtual override returns (TokenPair memory) {
        return TokenPair({collateralToken: COLLATERAL_TOKEN, borrowToken: BORROW_TOKEN});
    }

    function getPosition() external view virtual override returns (uint256 collateralAmount, uint256 debtAmount) {
        return (getCollateralAmount(), getDebtAmount());
    }

    function getFullPosition()
        external
        view
        virtual
        override
        returns (uint256 collateralAmount, uint256 debtAmount, uint64 currentLtvInWad, uint256 collateralPriceInRay)
    {
        return (getCollateralAmount(), getDebtAmount(), getCurrentLtvInWad(), collateralPriceInBorrowTokensInRay());
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _rayToWad(uint256 rateInRay) internal pure returns (uint64) {
        if (rateInRay == 0) return 0;
        return Math.mulDiv(rateInRay, WAD, RAY).toUint64();
    }

    /// @notice Safety buffer added when sizing a full debt repayment.
    /// @return The safety buffer.
    /// @dev See explanation above.
    function _repayRayRoundingBuffer() internal pure virtual returns (uint256) {
        return DEFAULT_REPAY_RAY_ROUNDING_BUFFER;
    }

    // -----------------------------------------------------------------------
    // Emergency Functions
    // -----------------------------------------------------------------------

    /**
     * @dev Rescue function to recover tokens (only owner)
     * @param token The token address to rescue
     * @param amount The amount to rescue (0 to rescue all available tokens)
     */
    function rescueToken(address token, uint256 amount) external onlyOwner {
        uint256 rescueAmount = amount == 0 ? IERC20(token).balanceOf(address(this)) : amount;
        IERC20(token).safeTransfer(msg.sender, rescueAmount);
    }
}
