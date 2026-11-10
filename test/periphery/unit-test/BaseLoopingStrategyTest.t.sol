// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {IAllocateModule} from "../../../src/interface/IAllocateModule.sol";
import {MultisigStrategy} from "../../../src/periphery/strategies/MultisigStrategy.sol";
import {BaseStrategy} from "../../../src/periphery/strategies/BaseStrategy.sol";
import {BaseLoopingStrategy} from "../../../src/periphery/strategies/BaseLoopingStrategy.sol";
import {IBaseStrategy} from "../../../src/periphery/interface/IBaseStrategy.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {IStrategyTemplate, StrategyType} from "../../../src/interface/IStrategyTemplate.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {PositionAccountingLib} from "../../../src/periphery/lib/PositionAccountingLib.sol";
import {AddStrategyWithDeallocationOrder} from "../../common/AddStrategyWithDeallocationOrder.sol";
import {WAD, RAY} from "../../../src/periphery/lib/Constants.sol";
import {IBaseLoopingStrategy, PreviewOperationResult} from "../../../src/periphery/interface/IBaseLoopingStrategy.sol";
import {LenderPosition, LeverageData, ILoopingPrimitive} from "../../../src/periphery/interface/ILoopingPrimitive.sol";
import {LeverageOperation, LoopModality, LoopModalityLib} from "../../../src/periphery/lib/Looping/LoopModalityLib.sol";
import {LoopingPrimitiveLib} from "../../../src/periphery/lib/Looping/LoopingPrimitiveLib.sol";
import {FlashLoanParams} from "../../../src/periphery/interface/ILoopingPrimitive.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";

import {MockLoopingStrategy} from "../mock/MockLoopingStrategy.sol";
import {MockLenderModule} from "../mock/MockLenderModule.sol";

import {MockFlashModule} from "../mock/MockFlashModule.sol";
import {MockSwapper} from "../mock/MockSwapper.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {ILenderModule} from "../../../src/periphery/interface/ILenderModule.sol";
import {ILenderStaging} from "../../../src/periphery/interface/ILenderStaging.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

contract BaseLoopingStrategyTest is ConcreteStandardVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    using LoopModalityLib for LoopModality;
    using Math for uint256;

    address public user1;
    address public admin;
    address public operator;

    uint256 public priceOfCollateralInBorrowInRay;
    uint64 public maxLtvInWad;
    uint64 public flashPremiumInWad;

    ERC20Mock public borrowToken;
    MockSwapper public swapModule;
    MockFlashModule public flashModule;
    MockLenderModule public lenderModule;
    IBaseLoopingStrategy public loopingStrategy;

    uint256 public constant INITIAL_DEPOSIT = 1000e18;
    uint256 public constant STRATEGY_ALLOCATION = 500e18;

    uint64 defaultTargetLtvInWad = uint64(7 * WAD / 10);
    uint64 defaultLtvAdditiveDeviationInWad = uint64(WAD / 50);
    uint64 defaultMaxSlippageInWad = uint64(WAD / 100);
    uint64 defaultSwapperSlippageInWad = uint64(WAD / 200);
    uint256 defaultFlashCollateralEpsilon = 1e13; // it's like a small fraction of a token unit.

    address defaultSlippageSurplusReceiver;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();

        user1 = makeAddr("user1");
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        defaultSlippageSurplusReceiver = makeAddr("slippageSurplusReceiver");

        // deploy lender
        priceOfCollateralInBorrowInRay = RAY;
        maxLtvInWad = uint64(WAD * 8 / 10);
        borrowToken = new ERC20Mock("BorrowAsset", "BA");
        flashPremiumInWad = uint64(WAD / 200);
        lenderModule =
            new MockLenderModule(address(asset), address(borrowToken), priceOfCollateralInBorrowInRay, maxLtvInWad);
        flashModule = new MockFlashModule(admin, flashPremiumInWad);
        swapModule = new MockSwapper(admin);
        // Deploy MultisigStrategy
        loopingStrategy = deployAndInitializeLoopingStrategy();

        vm.label(address(loopingStrategy), "LoopingStrategy");
        vm.label(user1, "user1");
        vm.label(admin, "admin");
        vm.label(operator, "operator");
        vm.label(address(flashModule), "FlashModule");
        vm.label(address(swapModule), "SwapModule");
        vm.label(address(lenderModule), "LenderModule");

        // Add strategy to vault
        addStrategyWithDeallocationOrder(
            address(loopingStrategy), address(concreteStandardVault), allocator, strategyOperator
        );

        // Give users some tokens
        asset.mint(user1, INITIAL_DEPOSIT * 2);

        // Grant operator role to operator for accounting tests
        vm.prank(admin);
        IAccessControl(address(loopingStrategy)).grantRole(PeripheryRolesLib.OPERATOR_ROLE, operator);
    }

    function testAllocateFundsToNonLoopingEnabledStrategy() public {
        // Setup: User deposits to vault
        _depositAsUser(user1, INITIAL_DEPOSIT);

        // Allocate funds to strategy through vault
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
    }

    function testAdjustLeverageWithDefaultValues() public {
        // liquidityCap set to type(uint256).max
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        // Setup: User deposits to vault
        _depositAsUser(user1, INITIAL_DEPOSIT);

        // Allocate funds to strategy through vault
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);

        // Enable looping (this doesn't trigger a flash loan yet)
        vm.prank(admin);
        loopingStrategy.enableLooping(
            address(flashModule),
            address(swapModule),
            defaultTargetLtvInWad,
            defaultFlashCollateralEpsilon,
            defaultLtvAdditiveDeviationInWad,
            defaultMaxSlippageInWad,
            false
        );

        // Construct expected loopModality for adjustLeverage
        // For adjustLeverage with isAllocation=true and allocOrDeallocAmount=0:
        // - allocateFloating = true
        // - adjustFlashToAvailableLiquidity = false (from enableLooping call)
        // - After _updateLoopModality: loopSupply = true, plainOperation = false (since targetLtv >= currentLtv)
        LoopModality expectedLoopModality = LoopModalityLib.init(true).setLoopSupply(true).setPlainOperation(false);
        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(0, true, defaultTargetLtvInWad, defaultMaxSlippageInWad);

        // expect operation == LeverageOperation.LoopSupplyAndAllocate
        assertEq(
            uint8(result.operation),
            uint8(LeverageOperation.LoopSupplyAndAllocate),
            "Operation is not LoopSupplyAndAllocate"
        );

        vm.startPrank(operator);
        // vm.expectEmit(true, true, true, true, address(loopingStrategy));
        uint256 floatingAmountUnused;
        {
            MockSwapper.Rate memory rate = swapModule.getRate(address(borrowToken), address(asset));
            uint256 collateralAmountOut = result.pairedTokenAmount.mulDiv(rate.numerator, rate.denominator);
            uint256 paybackAmount = result.flashAmount.mulDiv(WAD + result.flashPremiumQuoteInWad, WAD);
            floatingAmountUnused = collateralAmountOut.mulDiv(WAD - rate.slippageInWad, WAD) - paybackAmount;
        }
        emit ILoopingPrimitive.ExecuteFlash(
            expectedLoopModality,
            result.flashAmount,
            result.flashAmount.mulDiv(result.flashPremiumQuoteInWad, WAD),
            result.pairedTokenAmount,
            result.floatingAmount,
            floatingAmountUnused
        );
        // Wind up position (this triggers the flash loan)
        loopingStrategy.adjustLeverage(defaultMaxSlippageInWad, defaultTargetLtvInWad, false);
        vm.stopPrank();

        // should be very close approximate target ltv
        assertApproxEqAbs(
            uint256(loopingStrategy.getCurrentLtvInWad()),
            uint256(defaultTargetLtvInWad),
            1e6,
            "Lender reported LTV is not close to target LTV"
        );
    }

    function testAdjustLeverageWithSlightlyDifferentTargetLtv() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // get current ltv
        uint64 currentLtv = loopingStrategy.getCurrentLtvInWad();
        // get current target ltv
        uint64 currentTargetLtv = loopingStrategy.getTargetLtvInWad();
        // get current deviation ltv
        uint64 currentDeviationLtv = loopingStrategy.getLtvAdditiveDeviationInWad();
        // adjust to target ltv - deviation
        uint64 newTargetLtv = currentTargetLtv - currentDeviationLtv + 1;
        // adjust leverage
        vm.prank(operator);
        loopingStrategy.adjustLeverage(defaultMaxSlippageInWad, newTargetLtv, false);
        // get new ltv
        uint64 newLtv = loopingStrategy.getCurrentLtvInWad();
        // assert that they are very close to each other
        assertApproxEqAbs(newLtv, newTargetLtv, 1e6, "New LTV is not the correct one");

        // now set target ltv to current target ltv + deviation - 1
        uint64 newTargetLtv2 = currentTargetLtv + currentDeviationLtv;
        // adjust leverage
        vm.prank(operator);
        loopingStrategy.adjustLeverage(defaultMaxSlippageInWad, newTargetLtv2, false);
        // get new ltv
        uint64 newLtv2 = loopingStrategy.getCurrentLtvInWad();
        // assert that they are very close to each other
        assertApproxEqAbs(newLtv2, newTargetLtv2, 1e6, "New LTV is not the correct one");
    }

    function testAdjustLeverageAboveMaxLtvExpectRevert() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // get max ltv
        uint64 maxLtvInWad = ILenderModule(loopingStrategy.lenderModule()).getMaxLtvInWad();
        // set target ltv to max ltv + deviation
        uint64 newTargetLtv = maxLtvInWad + 1;
        // adjust leverage
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseLoopingStrategy.TargetLtvPlusDeviationAboveMaxLtv.selector,
                newTargetLtv,
                defaultLtvAdditiveDeviationInWad,
                maxLtvInWad
            )
        );
        loopingStrategy.adjustLeverage(defaultMaxSlippageInWad, newTargetLtv, false);
    }

    function testAdjustLeverageToZero() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        uint64 currentTargetLtv = loopingStrategy.getTargetLtvInWad();
        uint64 currentDeviationLtv = loopingStrategy.getLtvAdditiveDeviationInWad();
        uint64 newTargetLtv = 0;
        // adjust leverage
        // total allocated before adjustment
        uint256 totalAllocatedBefore = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log("Total allocated before adjustment", totalAllocatedBefore);
        vm.prank(operator);
        loopingStrategy.adjustLeverage(defaultMaxSlippageInWad, newTargetLtv, true);
        // get new ltv
        uint64 newLtv = loopingStrategy.getCurrentLtvInWad();

        // asssert that new ltv is zero
        assertEq(newLtv, 0, "New LTV is not zero");

        // new totalAllocated at the strategy
        uint256 newTotalAllocated = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log("New total allocated after adjustment", newTotalAllocated);
        console.log("Total allocated difference", int256(newTotalAllocated) - int256(totalAllocatedBefore));
        // console log out the default premium and the max slippage
        console.log("Default premium", flashModule.flashPremiumInWad());
        console.log("Max slippage", defaultMaxSlippageInWad);
        // assert that they are very close to each other
    }

    function testAdjustPermissionlessly() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // first let the price drop by 20%
        uint256 newCollateralPrice = RAY * (100 - 20) / 100;
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);

        // get current ltv
        uint64 currentLtv = loopingStrategy.getCurrentLtvInWad();
        // check that the ltv is out of bounds
        // assert(currentLtv < defaultTargetLtvInWad - defaultLtvAdditiveDeviationInWad);
        assert(currentLtv > defaultTargetLtvInWad + defaultLtvAdditiveDeviationInWad);
        // adjust leverage back up
        vm.prank(user1);
        loopingStrategy.adjustLeverage();
        // assert that the ltv is the correct one
        assertApproxEqAbs(
            loopingStrategy.getCurrentLtvInWad(), defaultTargetLtvInWad, 1e6, "New LTV is not the correct one"
        );

        // whooops, price goes up by 20%
        newCollateralPrice = RAY * (100 + 20) / 100;
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);

        currentLtv = loopingStrategy.getCurrentLtvInWad();
        assert(currentLtv < defaultTargetLtvInWad - defaultLtvAdditiveDeviationInWad);
        // get current ltv
        currentLtv = loopingStrategy.getCurrentLtvInWad();
        console.log("Max allowed ltv", defaultTargetLtvInWad + defaultLtvAdditiveDeviationInWad);
        // check that the ltv is out of bounds
        // assert(currentLtv < defaultTargetLtvInWad - defaultLtvAdditiveDeviationInWad);
    }

    function testMaxWithdrawalWithDonation() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), INITIAL_DEPOSIT);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // get total assets reported (before donation)
        uint256 totalAssetsReportedBefore = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log("Total assets reported before donation", totalAssetsReportedBefore);
        vm.prank(user1);
        IERC20(address(asset)).transfer(address(loopingStrategy), INITIAL_DEPOSIT);
        assertEq(IERC20(address(asset)).balanceOf(address(loopingStrategy)), INITIAL_DEPOSIT);

        // get total assets reported ()
        uint256 totalAssetsReportedAfter = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log(
            "Total assets reported difference", int256(totalAssetsReportedAfter) - int256(totalAssetsReportedBefore)
        );
        // get vault balance of user
        // get max withdrawal amount
        uint256 maxWithdrawalAmount = IStrategyTemplate(address(loopingStrategy)).maxWithdraw();
        // user withdraws all the funds
        // get vault balance of user
        _redeemAsUser(user1, INITIAL_DEPOSIT);
        assertApproxEqAbs(loopingStrategy.getCurrentLtvInWad(), 0, 1e6, "New LTV is not the correct one");
    }

    function testDellocateAndRepayLoop() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // check that deallocation amount and LTV are correct.
        // either decrease ltv or increase and request a lot.
        // get current balance
        uint256 currentBalance = asset.balanceOf(address(loopingStrategy));
        uint64 newTargetLtv = defaultTargetLtvInWad * 3 / 4;
        uint256 deallocationAmount = STRATEGY_ALLOCATION / 2;
        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(deallocationAmount, false, newTargetLtv, defaultMaxSlippageInWad);
        // check the view function for lender data and error info
        _deallocateFromStrategy(address(loopingStrategy), deallocationAmount);
        // vm.prank(operator);

        // loopingStrategy.adjustLeverage(defaultMaxSlippageInWad, newTargetLtv, true);
    }

    function testDeallocateAndRepayWithLoopSupply() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // check that the ltv is the correct one
        uint64 currentLtv = loopingStrategy.getCurrentLtvInWad();
        // print current ltv
        console.log("Current LTV before collateral price goes up", currentLtv);
        // change collateralPrice by some amount so that the ltv goes down by some amount, so i guess collateral
        // price goes up by 20%
        uint256 newCollateralPrice = RAY * (100 + 20) / 100;
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);

        FlashLoanParams memory params = FlashLoanParams({
            collateralAmount: lenderModule.getCollateralAmount(address(loopingStrategy)),
            debtAmount: lenderModule.getDebtAmount(address(loopingStrategy)),
            floatingAmount: 0,
            collateralPriceInRay: newCollateralPrice,
            targetLtvInWad: defaultTargetLtvInWad,
            maxSlippageInWad: defaultMaxSlippageInWad
        });
        uint256 deallocationAmount = LoopingPrimitiveLib.deallocationBound(params);
        console.log("Deallocation amount", deallocationAmount);

        // get current ltv
        currentLtv = loopingStrategy.getCurrentLtvInWad();
        console.log("Current LTV after collateral price goes up", currentLtv);

        // deallocate half of the deallocation amount
        _deallocateFromStrategy(address(loopingStrategy), deallocationAmount / 2);

        // // deallocate and repay
        // _deallocateFromStrategy(address(loopingStrategy), deallocationAmount);
        // // check that the ltv is the correct one
        currentLtv = loopingStrategy.getCurrentLtvInWad();
        console.log("Current LTV after deallocating the entire deallocation amount", currentLtv);
        assertApproxEqAbs(
            uint256(currentLtv), uint256(defaultTargetLtvInWad), 1e6, "Current LTV is not the correct one"
        );
    }

    function testDeallocateOnlyFloatingAmount() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // check that the ltv is the correct one
        uint256 collateralFloatingAmount = IERC20(address(asset)).balanceOf(address(loopingStrategy));
        _deallocateFromStrategy(address(loopingStrategy), collateralFloatingAmount);
        // check that the ltv is the correct one
        uint64 currentLtv = loopingStrategy.getCurrentLtvInWad();
        assertApproxEqAbs(
            uint256(currentLtv), uint256(defaultTargetLtvInWad), 1e6, "Current LTV is not the correct one"
        );
    }

    function testDeallocationAndRepayByWithdrawFromLender() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // check that the ltv is the correct one

        uint256 newCollateralPrice = RAY * (100 + 20) / 100;
        // get collateral floating amount of strategy
        uint256 currentFloatingAmount = IERC20(address(asset)).balanceOf(address(loopingStrategy));
        //  _deallocateFromStrategy(address(loopingStrategy), collateralFloatingAmount);
        currentFloatingAmount = IERC20(address(asset)).balanceOf(address(loopingStrategy));
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);
        FlashLoanParams memory params = FlashLoanParams({
            collateralAmount: lenderModule.getCollateralAmount(address(loopingStrategy)),
            debtAmount: lenderModule.getDebtAmount(address(loopingStrategy)),
            floatingAmount: 0, // this number is not important for the computation of the deallocation bound.
            collateralPriceInRay: newCollateralPrice,
            targetLtvInWad: defaultTargetLtvInWad,
            maxSlippageInWad: defaultMaxSlippageInWad
        });

        uint256 deallocationAmount = LoopingPrimitiveLib.deallocationBound(params);

        _deallocateFromStrategy(address(loopingStrategy), deallocationAmount + currentFloatingAmount);
    }

    function testAllocationAndLoopRepayBelowAllocationLowerBound() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // increase the ltv by lowering the price of the collateral
        uint256 newCollateralPrice = RAY * (100 - 20) / 100;
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);
        uint256 currentFloatingAmount = IERC20(address(asset)).balanceOf(address(loopingStrategy));

        FlashLoanParams memory params = FlashLoanParams({
            collateralAmount: lenderModule.getCollateralAmount(address(loopingStrategy)),
            debtAmount: lenderModule.getDebtAmount(address(loopingStrategy)),
            floatingAmount: 0,
            collateralPriceInRay: newCollateralPrice,
            targetLtvInWad: defaultTargetLtvInWad,
            maxSlippageInWad: defaultMaxSlippageInWad
        });
        (uint64 premiumInWad, bool dependsOnLiquidity) = flashModule.flashPremiumMaxInWad(address(asset));
        uint256 allocationBound = LoopingPrimitiveLib.allocationLowerBound(params, premiumInWad);
        uint256 allocationAmount = allocationBound / 2;
        _allocateToStrategy(address(loopingStrategy), allocationAmount - currentFloatingAmount);
        //
        uint64 currentLtv = loopingStrategy.getCurrentLtvInWad();
        assertApproxEqAbs(
            uint256(currentLtv), uint256(defaultTargetLtvInWad), 1e6, "Current LTV is not the correct one"
        );
    }

    function testAllocationAndLoopRepayAboveAllocationLowerBound() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // increase the ltv by lowering the price of the collateral
        uint256 newCollateralPrice = RAY * (100 - 20) / 100;
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);
        uint256 currentFloatingAmount = IERC20(address(asset)).balanceOf(address(loopingStrategy));

        FlashLoanParams memory params = FlashLoanParams({
            collateralAmount: lenderModule.getCollateralAmount(address(loopingStrategy)),
            debtAmount: lenderModule.getDebtAmount(address(loopingStrategy)),
            floatingAmount: 0,
            collateralPriceInRay: newCollateralPrice,
            targetLtvInWad: defaultTargetLtvInWad,
            maxSlippageInWad: defaultMaxSlippageInWad
        });
        (uint64 premiumInWad,) = flashModule.flashPremiumMaxInWad(address(asset));
        uint256 allocationLowerBound = LoopingPrimitiveLib.allocationLowerBound(params, premiumInWad);
        uint256 allocationUpperBound = LoopingPrimitiveLib.allocationUpperBound(params);
        uint256 allocationAmount = (allocationUpperBound + allocationLowerBound) / 2;

        _allocateToStrategy(address(loopingStrategy), allocationAmount - currentFloatingAmount);

        uint64 currentLtv = loopingStrategy.getCurrentLtvInWad();
        assertApproxEqAbs(
            uint256(currentLtv), uint256(defaultTargetLtvInWad), 1e6, "Current LTV is not the correct one"
        );
    }

    function testAllocateAndSupplyDirectlyToTheLender() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // increase the ltv by lowering the price of the collateral
        uint256 newCollateralPrice = RAY * (100 - 20) / 100;
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);
        uint256 currentFloatingAmount = IERC20(address(asset)).balanceOf(address(loopingStrategy));

        FlashLoanParams memory params = FlashLoanParams({
            collateralAmount: lenderModule.getCollateralAmount(address(loopingStrategy)),
            debtAmount: lenderModule.getDebtAmount(address(loopingStrategy)),
            floatingAmount: 0,
            collateralPriceInRay: newCollateralPrice,
            targetLtvInWad: defaultTargetLtvInWad,
            maxSlippageInWad: defaultMaxSlippageInWad
        });
        uint256 allocationUpperBound = LoopingPrimitiveLib.allocationUpperBound(params);
        _allocateToStrategy(address(loopingStrategy), allocationUpperBound - currentFloatingAmount);
    }

    function testDeallocationOfEntirePosition() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // set targetLTv to zero
        vm.prank(admin);
        IBaseLoopingStrategy(address(loopingStrategy)).setTargetLtvAndDeviation(0, 1);
        // view value of the position (totalAllocatedValue)
        uint256 totalAllocatedValue = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log("Total allocated value", totalAllocatedValue);
        // deallocate the entire position
        // encode deallocation call

        _deallocateFromStrategy(address(loopingStrategy), totalAllocatedValue);
        // view value of the position (totalAllocatedValue)
        totalAllocatedValue = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log("Total allocated value after deallocation", totalAllocatedValue);
        assertEq(totalAllocatedValue, 0, "Total allocated value should be 0");
    }

    function _checkAssetBalanceAtStrategyIsZero(address strategy) internal {
        assertEq(IERC20(address(asset)).balanceOf(address(strategy)), 0, "Asset balance at the strategy should be 0");
    }

    function testDeallocationOfEntirePositionViaEncodedMaxWithdraw() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // assert that asset balance at the strategy is zero
        _checkAssetBalanceAtStrategyIsZero(address(loopingStrategy));
        // encode deallocation call
        _deallocateFromStrategy(address(loopingStrategy), type(uint256).max);
        // assert that asset balance at the strategy is zero
        _checkAssetBalanceAtStrategyIsZero(address(loopingStrategy));

        uint256 totalAllocatedValue = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log("Total allocated value after deallocation", totalAllocatedValue);
        assertEq(totalAllocatedValue, 0, "Total allocated value should be 0");
    }

    function testWithdrawEntirePosition() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );
        // user withdraws the entire position
        // get user shares
        uint256 userShares = concreteStandardVault.balanceOf(user1);
        _redeemAsUser(user1, userShares);
        // assert that positin
        uint256 totalAllocatedValue = IStrategyTemplate(address(loopingStrategy)).totalAllocatedValue();
        console.log("Total allocated value after deallocation", totalAllocatedValue);
        assertEq(totalAllocatedValue, 0, "Total allocated value should be 0");
        // and also check at the lender the current ltv and the collateral and the debt
        uint256 currentLtv = lenderModule.getCurrentLtvInWad();
        console.log("Current LTV at the lender", currentLtv);
        assertEq(currentLtv, 0, "Current LTV at the lender should be 0");
        uint256 collateral = lenderModule.getCollateralAmount(address(loopingStrategy));
        console.log("Collateral at the lender", collateral);
        assertEq(collateral, 0, "Collateral at the lender should be 0");
        uint256 debt = lenderModule.getDebtAmount(address(loopingStrategy));
        console.log("Debt at the lender", debt);
        assertEq(debt, 0, "Debt at the lender should be 0");
    }

    // Auxiliary functions

    function _redeemAsUser(address user, uint256 amount) internal {
        // withdraw from the vault
        vm.startPrank(user1);
        concreteStandardVault.redeem(amount, user1, user1);
        vm.stopPrank();
    }

    function deployAndInitializeLoopingStrategy() internal returns (MockLoopingStrategy) {
        MockLoopingStrategy impl = new MockLoopingStrategy();

        bytes memory initData = abi.encodeWithSelector(
            MockLoopingStrategy.initialize.selector,
            admin,
            address(concreteStandardVault),
            address(lenderModule),
            address(flashModule),
            address(swapModule)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return MockLoopingStrategy(address(proxy));
    }

    // Helper functions

    function _setLiquidityCapsToMax() internal {
        vm.startPrank(admin);
        flashModule.setLiquidityCap(address(borrowToken), type(uint256).max);
        flashModule.setLiquidityCap(address(asset), type(uint256).max);
        vm.stopPrank();
    }

    function _enableLoopingAndWindUpPosition(
        uint64 targetLtvInWad,
        uint64 ltvAdditiveDeviationInWad,
        uint64 maxSlippageInWad
    ) internal {
        vm.prank(admin);
        loopingStrategy.enableLooping(
            address(flashModule),
            address(swapModule),
            targetLtvInWad,
            defaultFlashCollateralEpsilon,
            ltvAdditiveDeviationInWad,
            maxSlippageInWad,
            false
        );
        vm.prank(operator);
        loopingStrategy.adjustLeverage(defaultMaxSlippageInWad, defaultTargetLtvInWad, false);
    }

    function _depositAsUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(concreteStandardVault), amount);
        concreteStandardVault.deposit(amount, user);
        vm.stopPrank();
    }

    function _setCollateralPriceOnLenderAndSwapper(uint256 collateralPriceInBorrowInRay, uint256 slippageInWad)
        internal
    {
        priceOfCollateralInBorrowInRay = collateralPriceInBorrowInRay;

        vm.startPrank(admin);
        lenderModule.setPriceOfCollateralInBorrowInRay(collateralPriceInBorrowInRay);
        swapModule.setRate(address(asset), address(borrowToken), collateralPriceInBorrowInRay, RAY);
        swapModule.setRate(address(borrowToken), address(asset), RAY, collateralPriceInBorrowInRay);
        swapModule.setSlippage(address(asset), address(borrowToken), slippageInWad);
        swapModule.setSlippage(address(borrowToken), address(asset), slippageInWad);
        vm.stopPrank();
    }

    function _allocateToStrategy(address strategyAddress, uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] =
            IAllocateModule.AllocateParams({strategy: strategyAddress, isDeposit: true, extraData: abi.encode(amount)});

        bytes memory allocateData = abi.encode(params);

        vm.prank(allocator);
        concreteStandardVault.allocate(allocateData);
    }

    function _deallocateFromStrategy(address strategyAddress, uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({
            strategy: strategyAddress, isDeposit: false, extraData: abi.encode(amount)
        });

        bytes memory allocateData = abi.encode(params);

        vm.prank(allocator);
        concreteStandardVault.allocate(allocateData);
    }

    //--------------------------------------------------------
    // Preview Operation Tests - Verify Operation Types and Equity Calculations
    //--------------------------------------------------------

    function testPreviewOperation_PlainSupply() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);

        // Don't enable looping - this will result in PlainSupply
        uint256 allocationAmount = 100e18;

        // Get current state
        LenderPosition memory positionBefore = loopingStrategy.getLenderPosition();
        uint256 stagedBefore = ILenderStaging(address(lenderModule)).staged();
        uint256 expectedEquityBefore = positionBefore.equity + stagedBefore;

        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(allocationAmount, true, 0, defaultMaxSlippageInWad);

        // Verify operation type
        assertEq(uint8(result.operation), uint8(LeverageOperation.PlainSupply), "Operation should be PlainSupply");
        assertFalse(ltvUpperBoundReached, "Should not have LTV upper bound error");
        assertFalse(deallocationHigherThanEquity, "Should not have deallocation error");
        assertFalse(insufficientFlashLiquidity, "Should not have liquidity error");

        // For PlainSupply: equityAfter = equityBefore + allocationAmount (no loss)
        uint256 expectedEquityAfter = expectedEquityBefore + allocationAmount;
        assertEq(result.positionEquityBeforeOperation, expectedEquityBefore, "Equity before should match");
        assertEq(result.positionEquityAfterOperation, expectedEquityAfter, "Equity after should match");
        assertEq(result.maximumLoss, 0, "Maximum loss should be 0 for plain supply");
    }

    function testPreviewOperation_PlainWithdraw() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);

        // Don't enable looping - this will result in PlainWithdraw
        uint256 deallocationAmount = 100e18;

        // Get current state
        LenderPosition memory positionBefore = loopingStrategy.getLenderPosition();
        uint256 stagedBefore = ILenderStaging(address(lenderModule)).staged();
        uint256 expectedEquityBefore = positionBefore.equity + stagedBefore;

        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(deallocationAmount, false, 0, defaultMaxSlippageInWad);

        // Verify operation type
        assertEq(uint8(result.operation), uint8(LeverageOperation.PlainWithdraw), "Operation should be PlainWithdraw");

        // For PlainWithdraw: equityAfter = equityBefore - deallocationAmount (no loss)
        uint256 expectedEquityAfter = expectedEquityBefore - deallocationAmount;
        assertEq(result.positionEquityBeforeOperation, expectedEquityBefore, "Equity before should match");
        assertEq(result.positionEquityAfterOperation, expectedEquityAfter, "Equity after should match");
        assertEq(result.maximumLoss, 0, "Maximum loss should be 0 for plain withdraw");
    }

    function testPreviewOperation_LoopSupplyAndAllocate() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // Get current state
        LenderPosition memory positionBefore = loopingStrategy.getLenderPosition();
        uint256 stagedBefore = ILenderStaging(address(lenderModule)).staged();
        uint256 expectedEquityBefore = positionBefore.equity + stagedBefore;

        // Allocate with targetLtv >= currentLtv to trigger LoopSupplyAndAllocate
        uint256 allocationAmount = 50e18;
        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(allocationAmount, true, defaultTargetLtvInWad, defaultMaxSlippageInWad);

        // Verify operation type
        assertEq(
            uint8(result.operation),
            uint8(LeverageOperation.LoopSupplyAndAllocate),
            "Operation should be LoopSupplyAndAllocate"
        );
        assertFalse(ltvUpperBoundReached, "Should not have LTV upper bound error");
        assertFalse(deallocationHigherThanEquity, "Should not have deallocation error");
        assertFalse(insufficientFlashLiquidity, "Should not have liquidity error");

        // Verify equity calculations
        assertEq(result.positionEquityBeforeOperation, expectedEquityBefore, "Equity before should match");

        // Calculate expected swap surplus
        // The preview uses maxSlippage, but actual swap uses swapperSlippage
        // Surplus = difference in slippage applied
        uint256 swapSurplus = 0; // For LoopSupplyAndAllocate, swap is collateral->borrow, surplus is minimal
        uint256 expectedEquityAfter = result.positionEquityAfterOperation;

        // Verify maximumLoss accounts for swap costs
        // For allocation: maximumLoss = equityBefore + allocAmount - equityAfter
        int256 expectedMaximumLoss =
            int256(expectedEquityBefore) + int256(allocationAmount) - int256(expectedEquityAfter);
        assertApproxEqAbs(
            uint256(result.maximumLoss > 0 ? result.maximumLoss : -result.maximumLoss),
            uint256(expectedMaximumLoss > 0 ? expectedMaximumLoss : -expectedMaximumLoss),
            1e15, // Allow small rounding differences
            "Maximum loss should account for swap costs"
        );
    }

    function testPreviewOperation_LoopSupplyAndDeallocate() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // Increase collateral price to lower LTV, then deallocate with higher targetLtv to trigger LoopSupplyAndDeallocate
        uint256 newCollateralPrice = RAY * 120 / 100; // 20% increase
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);

        // Get current state
        LenderPosition memory positionBefore = loopingStrategy.getLenderPosition();
        uint256 stagedBefore = ILenderStaging(address(lenderModule)).staged();
        uint256 expectedEquityBefore = positionBefore.equity + stagedBefore;

        uint256 deallocationAmount = 50e18;
        uint64 higherTargetLtv = defaultTargetLtvInWad + defaultLtvAdditiveDeviationInWad;
        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(deallocationAmount, false, higherTargetLtv, defaultMaxSlippageInWad);

        // Verify operation type
        assertEq(
            uint8(result.operation),
            uint8(LeverageOperation.LoopSupplyAndDeallocate),
            "Operation should be LoopSupplyAndDeallocate"
        );

        // Verify equity calculations
        assertEq(result.positionEquityBeforeOperation, expectedEquityBefore, "Equity before should match");

        // For deallocation: maximumLoss = equityBefore - deallocAmount - equityAfter
        int256 expectedMaximumLoss =
            int256(expectedEquityBefore) - int256(deallocationAmount) - int256(result.positionEquityAfterOperation);
        assertApproxEqAbs(
            uint256(result.maximumLoss > 0 ? result.maximumLoss : -result.maximumLoss),
            uint256(expectedMaximumLoss > 0 ? expectedMaximumLoss : -expectedMaximumLoss),
            1e15,
            "Maximum loss should account for swap costs"
        );
    }

    function testPreviewOperation_LoopWithdrawAndAllocate_Uncapped() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // Lower collateral price to increase LTV, then allocate with lower targetLtv to trigger LoopWithdrawAndAllocate
        uint256 newCollateralPrice = RAY * 80 / 100; // 20% decrease
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);

        // Get current state
        LenderPosition memory positionBefore = loopingStrategy.getLenderPosition();
        uint256 stagedBefore = ILenderStaging(address(lenderModule)).staged();
        uint256 expectedEquityBefore = positionBefore.equity + stagedBefore;

        FlashLoanParams memory params = FlashLoanParams({
            collateralAmount: lenderModule.getCollateralAmount(address(loopingStrategy)),
            debtAmount: lenderModule.getDebtAmount(address(loopingStrategy)),
            floatingAmount: 0,
            collateralPriceInRay: newCollateralPrice,
            targetLtvInWad: defaultTargetLtvInWad,
            maxSlippageInWad: defaultMaxSlippageInWad
        });
        (uint64 premiumInWad,) = flashModule.flashPremiumMaxInWad(address(borrowToken));
        uint256 allocationLowerBound = LoopingPrimitiveLib.allocationLowerBound(params, premiumInWad);
        uint256 allocationUpperBound = LoopingPrimitiveLib.allocationUpperBound(params);

        // Use allocation amount <= lowerBound to ensure it's not capped
        // But also ensure it's < allocationUpperBound to get LoopWithdrawAndAllocate
        uint256 allocationAmount = allocationLowerBound;
        if (allocationAmount >= allocationUpperBound && allocationUpperBound > 0) {
            // If lowerBound >= upperBound, use a value below upperBound
            allocationAmount = allocationUpperBound - 1;
        }
        if (allocationLowerBound == 0) {
            // If lowerBound is 0, use a small amount below upperBound
            allocationAmount = allocationUpperBound > 10e18 ? allocationUpperBound - 10e18 : allocationUpperBound / 2;
        }

        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(allocationAmount, true, defaultTargetLtvInWad, defaultMaxSlippageInWad);

        // Verify operation type
        assertEq(
            uint8(result.operation),
            uint8(LeverageOperation.LoopWithdrawAndAllocate),
            "Operation should be LoopWithdrawAndAllocate"
        );
        assertFalse(ltvUpperBoundReached, "Should not have LTV upper bound error");
        assertFalse(deallocationHigherThanEquity, "Should not have deallocation error");
        assertFalse(insufficientFlashLiquidity, "Should not have liquidity error");

        // Verify equity calculations
        assertEq(result.positionEquityBeforeOperation, expectedEquityBefore, "Equity before should match");

        // Verify that floatingAmount is not capped (should equal allocationAmount)
        assertEq(result.floatingAmount, allocationAmount, "Floating amount should not be capped");

        // Verify maximumLoss accounts for swap costs
        int256 expectedMaximumLoss =
            int256(expectedEquityBefore) + int256(allocationAmount) - int256(result.positionEquityAfterOperation);
        assertApproxEqAbs(
            uint256(result.maximumLoss > 0 ? result.maximumLoss : -result.maximumLoss),
            uint256(expectedMaximumLoss > 0 ? expectedMaximumLoss : -expectedMaximumLoss),
            1e15,
            "Maximum loss should account for swap costs"
        );
    }

    function testPreviewOperation_LoopWithdrawAndAllocate_Capped() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // Lower collateral price to increase LTV, then allocate with lower targetLtv to trigger LoopWithdrawAndAllocate
        uint256 newCollateralPrice = RAY * 80 / 100; // 20% decrease
        _setCollateralPriceOnLenderAndSwapper(newCollateralPrice, defaultSwapperSlippageInWad);

        // Get current state
        LenderPosition memory positionBefore = loopingStrategy.getLenderPosition();
        uint256 stagedBefore = ILenderStaging(address(lenderModule)).staged();
        uint256 expectedEquityBefore = positionBefore.equity + stagedBefore;

        FlashLoanParams memory params = FlashLoanParams({
            collateralAmount: lenderModule.getCollateralAmount(address(loopingStrategy)),
            debtAmount: lenderModule.getDebtAmount(address(loopingStrategy)),
            floatingAmount: 0,
            collateralPriceInRay: newCollateralPrice,
            targetLtvInWad: defaultTargetLtvInWad,
            maxSlippageInWad: defaultMaxSlippageInWad
        });
        (uint64 premiumInWad,) = flashModule.flashPremiumMaxInWad(address(borrowToken));
        uint256 allocationLowerBound = LoopingPrimitiveLib.allocationLowerBound(params, premiumInWad);
        uint256 allocationUpperBound = LoopingPrimitiveLib.allocationUpperBound(params);

        // Use allocation amount ABOVE lowerBound but BELOW upperBound to ensure it gets capped
        // and still results in LoopWithdrawAndAllocate
        if (allocationLowerBound == 0 || allocationUpperBound <= allocationLowerBound) {
            // If lowerBound is 0 or upperBound <= lowerBound, we can't test capping, so skip
            return;
        }
        uint256 allocationAmount = (allocationLowerBound + allocationUpperBound) / 2;
        // Ensure it's strictly between the bounds
        if (allocationAmount <= allocationLowerBound) {
            allocationAmount = allocationLowerBound + 1;
        }
        if (allocationAmount >= allocationUpperBound) {
            allocationAmount = allocationUpperBound - 1;
        }

        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(allocationAmount, true, defaultTargetLtvInWad, defaultMaxSlippageInWad);

        // Verify operation type
        assertEq(
            uint8(result.operation),
            uint8(LeverageOperation.LoopWithdrawAndAllocate),
            "Operation should be LoopWithdrawAndAllocate"
        );

        // Verify equity calculations
        assertEq(result.positionEquityBeforeOperation, expectedEquityBefore, "Equity before should match");

        // Verify that floatingAmount is capped to allocationLowerBound (with small tolerance for rounding)
        assertApproxEqAbs(
            result.floatingAmount,
            allocationLowerBound,
            1e15, // Allow small tolerance for rounding differences
            "Floating amount should be capped to allocationLowerBound"
        );
        assertGt(
            allocationAmount,
            allocationLowerBound,
            "Allocation amount should be greater than lower bound to test capping"
        );
        assertLt(
            result.floatingAmount, allocationAmount, "Floating amount should be less than requested allocation (capped)"
        );

        // The unused allocation (allocationAmount - allocationLowerBound) stays as floating surplus
        // This should be reflected in the equity calculation
        uint256 unusedAllocation = allocationAmount - allocationLowerBound;

        // Verify maximumLoss accounts for swap costs and unused allocation
        int256 expectedMaximumLoss =
            int256(expectedEquityBefore) + int256(allocationAmount) - int256(result.positionEquityAfterOperation);
        assertApproxEqAbs(
            uint256(result.maximumLoss > 0 ? result.maximumLoss : -result.maximumLoss),
            uint256(expectedMaximumLoss > 0 ? expectedMaximumLoss : -expectedMaximumLoss),
            1e15,
            "Maximum loss should account for swap costs and unused allocation"
        );
    }

    function testPreviewOperation_LoopWithdrawAndDeallocate() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // Get current state
        LenderPosition memory positionBefore = loopingStrategy.getLenderPosition();
        uint256 stagedBefore = ILenderStaging(address(lenderModule)).staged();
        uint256 expectedEquityBefore = positionBefore.equity + stagedBefore;

        // Deallocate with targetLtv <= currentLtv to trigger LoopWithdrawAndDeallocate
        uint256 deallocationAmount = STRATEGY_ALLOCATION / 2;
        uint64 lowerTargetLtv = defaultTargetLtvInWad * 3 / 4;

        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = loopingStrategy.previewOperation(deallocationAmount, false, lowerTargetLtv, defaultMaxSlippageInWad);

        // Verify operation type
        assertEq(
            uint8(result.operation),
            uint8(LeverageOperation.LoopWithdrawAndDeallocate),
            "Operation should be LoopWithdrawAndDeallocate"
        );
        assertFalse(ltvUpperBoundReached, "Should not have LTV upper bound error");
        assertFalse(deallocationHigherThanEquity, "Should not have deallocation error");
        assertFalse(insufficientFlashLiquidity, "Should not have liquidity error");

        // Verify equity calculations
        assertEq(result.positionEquityBeforeOperation, expectedEquityBefore, "Equity before should match");

        // Verify maximumLoss accounts for swap costs
        int256 expectedMaximumLoss =
            int256(expectedEquityBefore) - int256(deallocationAmount) - int256(result.positionEquityAfterOperation);
        assertApproxEqAbs(
            uint256(result.maximumLoss > 0 ? result.maximumLoss : -result.maximumLoss),
            uint256(expectedMaximumLoss > 0 ? expectedMaximumLoss : -expectedMaximumLoss),
            1e15,
            "Maximum loss should account for swap costs"
        );
    }

    /**
     * @notice Test that maxWithdraw correctly calculates position value when targetLtvInWad == 0
     * @dev This test verifies the fix for HAL-05 where incorrect arguments were passed to
     *      _effectiveCollateralValueOfDebt() in maxWithdrawableGivenLiquidityDepth().
     *      The bug was passing params.collateralAmount and currentLtvInWad() instead of
     *      params.debtAmount and params.collateralPriceInRay.
     */
    function testMaxWithdrawWithZeroTargetLtv() public {
        _setLiquidityCapsToMax();
        _setCollateralPriceOnLenderAndSwapper(RAY, defaultSwapperSlippageInWad);
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(loopingStrategy), STRATEGY_ALLOCATION);
        _enableLoopingAndWindUpPosition(
            defaultTargetLtvInWad, defaultLtvAdditiveDeviationInWad, defaultMaxSlippageInWad
        );

        // Get current position state using the strategy's getLenderPosition() method
        LenderPosition memory position = loopingStrategy.getLenderPosition();
        uint256 collateralAmount = position.collateralAmount;
        uint256 debtAmount = position.debtAmount;
        uint256 collateralPriceInRay = position.collateralPriceInRay;
        uint64 maxSlippageInWad = defaultMaxSlippageInWad;

        // Calculate expected position value using the correct formula
        // This uses lenderPositionValue which internally calls _positionValue, which calls
        // _effectiveCollateralValueOfDebt with the correct arguments:
        // debtAmount, collateralPriceInRay, premium, maxSlippage
        uint256 expectedPositionValue = LoopingPrimitiveLib.lenderPositionValue(
            address(flashModule),
            address(borrowToken),
            collateralAmount,
            debtAmount,
            collateralPriceInRay,
            maxSlippageInWad
        );

        // Call maxDeallocate with targetLtvInWad = 0 (this triggers maxWithdrawableGivenLiquidityDepth
        // with targetLtvInWad == 0
        uint256 maxWithdrawable = loopingStrategy.maxDeallocate(0, maxSlippageInWad);

        // The maxWithdrawable should equal the position value (with small tolerance for rounding)
        // This verifies that _effectiveCollateralValueOfDebt is now called with correct arguments:
        // params.debtAmount and params.collateralPriceInRay (not params.collateralAmount and currentLtvInWad)
        assertApproxEqAbs(
            maxWithdrawable,
            expectedPositionValue,
            1e15, // Allow small tolerance for rounding differences
            "maxWithdrawable should equal position value when targetLtvInWad == 0"
        );

        // Verify that the position actually has debt (otherwise the test wouldn't catch the bug)
        assertGt(debtAmount, 0, "Position should have debt to test the fix");
        assertGt(collateralAmount, 0, "Position should have collateral");
    }

    // ── Timelock interface ────────────────────────────────────────────────────

    function testTimelockSetAndGet() public {
        address timelockAddr = makeAddr("timelock");
        BaseStrategy bs = BaseStrategy(address(loopingStrategy));

        (address tl, bool active) = bs.getTimelock();
        assertEq(tl, address(0));
        assertFalse(active);

        vm.prank(admin);
        bs.setTimelock(timelockAddr);

        (tl, active) = bs.getTimelock();
        assertEq(tl, timelockAddr);
        assertFalse(active);
    }

    function testTimelockActivate() public {
        address timelockAddr = makeAddr("timelock");
        BaseStrategy bs = BaseStrategy(address(loopingStrategy));

        vm.startPrank(admin);
        bs.setTimelock(timelockAddr);
        bs.activateTimelock();
        vm.stopPrank();

        (address tl, bool active) = bs.getTimelock();
        assertEq(tl, timelockAddr);
        assertTrue(active);
    }
}
