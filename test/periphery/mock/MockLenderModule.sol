// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {RAY, WAD} from "../../../src/periphery/lib/Constants.sol";
import {IMintableERC20} from "./ERC20Mock.sol";
import {ILenderModule} from "../../../src/periphery/interface/ILenderModule.sol";
import {ILenderStaging} from "../../../src/periphery/interface/ILenderStaging.sol";
import {TokenPair} from "../../../src/periphery/interface/ILoopingPrimitive.sol";

import {console2 as console} from "forge-std/console2.sol";

contract MockLenderModule is ILenderModule, ILenderStaging {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMintableERC20;

    error ZeroAddress();
    error InsufficientCollateral();
    error InsufficientDebt();
    error ExceededMaxLtv();

    event Supplied(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Borrowed(address indexed account, uint256 amount);
    event Repaid(address indexed account, uint256 amount);
    event PriceUpdated(uint256 newPrice);
    event MaxLtvUpdated(uint64 newMaxLtv);

    IERC20 public immutable _collateralToken;
    IMintableERC20 public immutable _borrowToken;

    uint256 public priceOfCollateralInBorrowInRay;
    uint64 public maxLtvInWad;

    mapping(address => uint256) public collateralAmount;
    mapping(address => uint256) public debtAmount;

    // Testing aid: tracks how many times `withdraw` is called per account.
    mapping(address => uint256) public withdrawCallCount;

    constructor(
        address collateralToken_,
        address borrowToken_,
        uint256 priceOfCollateralInBorrowInRay_,
        uint64 maxLtvInWad_
    ) {
        if (collateralToken_ == address(0) || borrowToken_ == address(0)) {
            revert ZeroAddress();
        }
        _collateralToken = IERC20(collateralToken_);
        _borrowToken = IMintableERC20(borrowToken_);
        priceOfCollateralInBorrowInRay = priceOfCollateralInBorrowInRay_;
        maxLtvInWad = maxLtvInWad_;
    }

    function getTokenPair() external view returns (TokenPair memory) {
        return TokenPair(address(_collateralToken), address(_borrowToken));
    }

    function getPosition() external view returns (uint256, uint256) {
        return (collateralAmount[msg.sender], debtAmount[msg.sender]);
    }

    function getFullPosition() external view returns (uint256, uint256, uint64, uint256) {
        return
            (collateralAmount[msg.sender], debtAmount[msg.sender], getCurrentLtvInWad(), priceOfCollateralInBorrowInRay);
    }

    function getCollateralAmount(address user) external view returns (uint256) {
        return collateralAmount[user];
    }

    function getCollateralAmount() external view returns (uint256) {
        return collateralAmount[msg.sender];
    }

    function getDebtAmount(address user) external view returns (uint256) {
        return debtAmount[user];
    }

    function getDebtAmount() external view returns (uint256) {
        return debtAmount[msg.sender];
    }

    function getAvailablePoolLiquidity() external view returns (uint256) {
        return IERC20(address(_collateralToken)).balanceOf(address(this));
    }

    function supply(uint256 amount) external {
        if (amount == 0) return;
        _collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralAmount[msg.sender] += amount;
        emit Supplied(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) return;
        uint256 userCollateral = collateralAmount[msg.sender];
        if (userCollateral < amount) revert InsufficientCollateral();
        collateralAmount[msg.sender] = userCollateral - amount;
        withdrawCallCount[msg.sender] += 1;
        _enforceMaxLtv(msg.sender);
        _collateralToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external {
        if (amount == 0) return;
        if (collateralAmount[msg.sender] == 0) revert InsufficientCollateral();
        debtAmount[msg.sender] += amount;
        _enforceMaxLtv(msg.sender);
        _borrowToken.mint(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        if (amount == 0) return;
        uint256 userDebt = debtAmount[msg.sender];
        if (userDebt < amount) revert InsufficientDebt();
        debtAmount[msg.sender] = userDebt - amount;
        _borrowToken.safeTransferFrom(msg.sender, address(this), amount);
        _borrowToken.burn(address(this), amount);
        emit Repaid(msg.sender, amount);
    }

    function getCurrentLtvInWad() public view returns (uint64) {
        uint256 collateral = collateralAmount[msg.sender];
        uint256 debt = debtAmount[msg.sender];
        if (debt == 0) return 0;
        if (collateral == 0) return type(uint64).max;
        return uint64(debt.mulDiv(RAY, collateral).mulDiv(WAD, priceOfCollateralInBorrowInRay));
    }

    function getMaxLtvInWad() external view returns (uint64) {
        return maxLtvInWad;
    }

    function setPriceOfCollateralInBorrowInRay(uint256 priceOfCollateralInBorrowInRay_) external {
        priceOfCollateralInBorrowInRay = priceOfCollateralInBorrowInRay_;
        emit PriceUpdated(priceOfCollateralInBorrowInRay_);
    }

    function setMaxLtv(uint64 maxLtvInWad_) external {
        maxLtvInWad = maxLtvInWad_;
        emit MaxLtvUpdated(maxLtvInWad_);
    }

    function _enforceMaxLtv(
        address /*user*/
    )
        internal
        view
    {
        uint256 ltv = getCurrentLtvInWad();
        if (ltv > maxLtvInWad) revert ExceededMaxLtv();
    }

    function getCurrentBorrowRateInWad() external view returns (uint64) {
        return 0;
    }

    function getCurrentLiquidityRateInWad() external view returns (uint64) {
        return 0;
    }

    function getCurrentEstimatedRewards() external view returns (uint64 rateInWad, uint256 amount) {
        return (0, 0);
    }

    function borrowToken() external view returns (address) {
        return address(_borrowToken);
    }

    function collateralToken() external view returns (address) {
        return address(_collateralToken);
    }

    function collateralPriceInBorrowTokensInRay() external view returns (uint256) {
        return priceOfCollateralInBorrowInRay;
    }

    // -----------------------------------------------------------------------
    // Staging
    // -----------------------------------------------------------------------

    uint256 public stagedAmount;
    address public strategy;
    error InsufficientStagedAmount();
    error InvalidSender();

    function setStrategy(address strategy_) external {
        strategy = strategy_;
    }

    function stage(uint256 amount) external {
        if (amount == 0) return;
        _collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        stagedAmount += amount;
    }

    function staged() external view override returns (uint256) {
        return stagedAmount;
    }

    function engage(uint256 amount) external {
        if (amount == 0) return;
        if (stagedAmount < amount) revert InsufficientStagedAmount();
        stagedAmount -= amount;
        collateralAmount[strategy] += amount;
        emit Supplied(strategy, amount);
    }

    function send(uint256 amount) external {
        if (amount == 0) return;
        if (msg.sender == strategy) revert InvalidSender();
        if (stagedAmount < amount) revert InsufficientStagedAmount();
        stagedAmount -= amount;
        _collateralToken.safeTransfer(msg.sender, amount);
    }
}
