// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AaveV3LenderAdapter} from "../../../src/periphery/lenders/AaveV3LenderAdapter.sol";
import {RAY, WAD} from "../../../src/periphery/lib/Constants.sol";
import {console2 as console} from "forge-std/console2.sol";

contract PlainAaveV3LenderAdapter is AaveV3LenderAdapter {
    constructor(address collateralToken_, address borrowToken_, address dataProvider_)
        AaveV3LenderAdapter(collateralToken_, borrowToken_, dataProvider_)
    {}

    function initialize(address admin_, uint256 interestRateMode_) external initializer {
        __AaveV3LenderAdapter_init(admin_, interestRateMode_);
    }
}

contract AaveV3LenderAdapterTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;
    uint256 internal constant STABLE_RATE_MODE = 1;
    uint256 internal constant VARIABLE_RATE_MODE = 2;

    PlainAaveV3LenderAdapter internal adapter;
    address internal strategy;
    address internal unauthorizedUser;

    function setUp() public virtual {
        string memory rpcUrl = "https://mainnet.gateway.tenderly.co/6msaKS4fqn7F8amEqPa14c";
        uint256 forkId = vm.createFork(rpcUrl, 23800000);
        vm.selectFork(forkId);

        // Deploy implementation
        PlainAaveV3LenderAdapter impl = new PlainAaveV3LenderAdapter(WETH, USDC, DATA_PROVIDER);

        // Deploy proxy and initialize
        bytes memory initData = abi.encodeCall(PlainAaveV3LenderAdapter.initialize, (address(this), VARIABLE_RATE_MODE));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        adapter = PlainAaveV3LenderAdapter(address(proxy));

        strategy = address(this);
        adapter.setStrategy(strategy);
    }

    function test_deploy_revertsWhenIncorrectParameters() external {
        vm.expectRevert(AaveV3LenderAdapter.ZeroAddress.selector);
        new PlainAaveV3LenderAdapter(address(0), USDC, DATA_PROVIDER);
        vm.expectRevert(AaveV3LenderAdapter.ZeroAddress.selector);
        new PlainAaveV3LenderAdapter(WETH, address(0), DATA_PROVIDER);
        vm.expectRevert(AaveV3LenderAdapter.ZeroAddress.selector);
        new PlainAaveV3LenderAdapter(WETH, USDC, address(0));
    }

    function test_supply_success() external {
        uint256 supplyAmount = 2 ether;
        _mintAsset(WETH, supplyAmount);

        IERC20(WETH).approve(address(adapter), supplyAmount);
        adapter.supply(supplyAmount);

        assertApproxEqAbs(adapter.getCollateralAmount(), supplyAmount, 1e9, "collateral accounting mismatch");
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(this)), 0, 1e3, "caller balance should be spent");
    }

    function test_withdraw_success() external {
        uint256 supplyAmount = 3 ether;
        _mintAsset(WETH, supplyAmount);

        IERC20(WETH).approve(address(adapter), supplyAmount);
        adapter.supply(supplyAmount);

        uint256 withdrawAmount = supplyAmount / 2;
        adapter.withdraw(withdrawAmount);

        assertApproxEqAbs(
            adapter.getCollateralAmount(), supplyAmount - withdrawAmount, 1e9, "collateral accounting mismatch"
        );
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(this)), withdrawAmount, 1e3, "caller balance should be spent");
    }

    function test_borrow_success() external {
        uint256 supplyAmount = 8 ether;
        _mintAsset(WETH, supplyAmount);
        IERC20(WETH).approve(address(adapter), supplyAmount);
        adapter.supply(supplyAmount);

        uint256 borrowAmount = 10e6; // 10 USDC
        adapter.borrow(borrowAmount);
        uint64 currentLtv = adapter.getCurrentLtvInWad();
        uint64 maxLtv = adapter.getMaxLtvInWad();
        uint256 collateralPriceRay = adapter.collateralPriceInBorrowTokensInRay();
        uint256 collateralValueInBorrowTokens = Math.mulDiv(supplyAmount, collateralPriceRay, RAY);
        uint256 expectedLtv = Math.mulDiv(borrowAmount, WAD, collateralValueInBorrowTokens);
        console.log("expectedLtv", expectedLtv);
        console.log("currentLtv", currentLtv);
        console.log("maxLtv", maxLtv);
        console.log(collateralPriceRay, "collateralPriceRay");
        uint64 liquidityRate = adapter.getSupplyRateInWad();
        console.log("liquidityRate", liquidityRate / 1e15);
        uint64 borrowRate = adapter.getBorrowRateInWad();
        console.log("borrowRate", borrowRate / 1e15);
        assertApproxEqAbs(uint256(currentLtv), expectedLtv, 1e15, "ltv should reflect borrow ratio");
        assertGt(maxLtv, 0, "max ltv should be populated");
        assertLe(currentLtv, maxLtv, "current ltv should be within max");
    }

    function test_borrowAndRepay_success() external {
        uint256 supplyAmount = 6 ether;
        _mintAsset(WETH, supplyAmount);
        IERC20(WETH).approve(address(adapter), supplyAmount);
        adapter.supply(supplyAmount);

        uint256 borrowAmount = 200e6;
        adapter.borrow(borrowAmount);

        assertApproxEqAbs(adapter.getDebtAmount(), borrowAmount, 1e9, "debt mismatch pre repay");

        // Provide an extra buffer to cover interest
        uint256 repayAmount = borrowAmount + 1e5;
        deal(USDC, address(this), repayAmount);
        IERC20(USDC).approve(address(adapter), repayAmount);
        adapter.repay(repayAmount);

        assertLe(adapter.getDebtAmount(), 1, "debt should be cleared");
        assertEq(adapter.getCurrentLtvInWad(), 0, "ltv should reset to zero after repay");

        uint64 maxLtv = adapter.getMaxLtvInWad();
        assertGt(maxLtv, 0, "max ltv should still be available");
    }

    function test_getAvailablePoolLiquidity_success() external {
        uint256 supplyAmount = 5 ether;
        _mintAsset(WETH, supplyAmount);
        IERC20(WETH).approve(address(adapter), supplyAmount);
        // available pool liquidity before supply
        uint256 availablePoolLiquidityBeforeSupply = adapter.getAvailablePoolLiquidity();
        // expect that available pool liquidity is bigger than zero
        assertGt(availablePoolLiquidityBeforeSupply, 0, "available pool liquidity should be bigger than zero");
        adapter.supply(supplyAmount);
        uint256 availablePoolLiquidityAfterSupply = adapter.getAvailablePoolLiquidity();
        assertEq(
            availablePoolLiquidityAfterSupply,
            availablePoolLiquidityBeforeSupply + supplyAmount,
            "available pool liquidity should increase after supply"
        );
    }

    function test_accessControl_revertsWhenCalledByUnauthorizedUser() external {
        // Setup: supply some collateral and borrow (as owner) to enable all operations
        uint256 supplyAmount = 5 ether;
        _mintAsset(WETH, address(this), supplyAmount);
        IERC20(WETH).approve(address(adapter), supplyAmount);
        adapter.supply(supplyAmount);
        unauthorizedUser = makeAddr("unauthorizedUser");
        strategy = makeAddr("strategy");
        adapter.setStrategy(strategy);
        uint256 borrowAmount = 10e6;
        vm.prank(strategy);
        adapter.borrow(borrowAmount);

        // Prepare assets for unauthorized user
        uint256 testAmount = 1 ether;
        _mintAsset(WETH, unauthorizedUser, testAmount);
        _mintAsset(USDC, unauthorizedUser, borrowAmount);

        vm.startPrank(unauthorizedUser);
        // Test supply reverts
        IERC20(WETH).approve(address(adapter), testAmount);
        vm.expectRevert(AaveV3LenderAdapter.Unauthorized.selector);
        adapter.supply(testAmount);
        // Test withdraw reverts
        vm.expectRevert(AaveV3LenderAdapter.Unauthorized.selector);
        adapter.withdraw(testAmount);

        // Test borrow reverts
        vm.expectRevert(AaveV3LenderAdapter.Unauthorized.selector);
        adapter.borrow(borrowAmount);

        // Test repay reverts
        IERC20(USDC).approve(address(adapter), borrowAmount);
        vm.expectRevert(AaveV3LenderAdapter.Unauthorized.selector);
        adapter.repay(borrowAmount);

        vm.stopPrank();
    }

    function _mintAsset(address asset, uint256 amount) internal {
        deal(asset, address(this), amount);
    }

    function _mintAsset(address asset, address to, uint256 amount) internal {
        deal(asset, to, amount);
    }
}
