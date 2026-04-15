// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplBaseSetup} from "../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {ERC4626StrategyMock} from "../mock/ERC4626StrategyMock.sol";
import {MockHurdleRateOracle} from "../mock/MockHurdleRateOracle.sol";
import {APYRateHurdleOracle} from "../../src/oracle/APYRateHurdleOracle.sol";
import {IAllocateModule} from "../../src/interface/IAllocateModule.sol";
import {IHurdleRateOracle} from "../../src/interface/IHurdleRateOracle.sol";
import {InvariantUtils} from "../invariant/helpers/InvariantUtils.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {AddStrategyWithDeallocationOrder} from "../common/AddStrategyWithDeallocationOrder.sol";
import {console} from "forge-std/console.sol";

contract HurdleRatePerformanceFeeE2ETest is ConcreteStandardVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    uint16 public constant PERFORMANCE_FEE_BPS = 1000; // 10% performance fee
    uint256 public constant INITIAL_DEPOSIT = 1000e18;
    uint256 public constant YIELD_AMOUNT = 100e18; // 10% yield
    uint8 public constant ORACLE_DECIMALS = 18;
    uint256 public constant ORACLE_PRECISION = 1e18;

    address public user1;
    address public performanceFeeRecipient;
    ERC4626StrategyMock public strategy;
    MockHurdleRateOracle public hurdleOracle;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        performanceFeeRecipient = makeAddr("performanceFeeRecipient");

        vm.prank(factoryOwner);
        concreteStandardVault.updatePerformanceFeeRecipient(performanceFeeRecipient);

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(PERFORMANCE_FEE_BPS);

        strategy = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        hurdleOracle = new MockHurdleRateOracle(ORACLE_DECIMALS);
        vm.label(address(hurdleOracle), "hurdleOracle");

        asset.mint(user1, INITIAL_DEPOSIT);
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), INITIAL_DEPOSIT);
        concreteStandardVault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
    }

    // ── No oracle set: standard behavior ────────────────────────────────

    function testNoHurdleOracle_standardFee() public {
        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        uint256 totalSupplyBefore = concreteStandardVault.totalSupply();
        uint256 totalAssetsBefore = concreteStandardVault.cachedTotalAssets();
        uint256 netYield = _getActualYield();
        uint256 postYieldAssets = totalAssetsBefore + netYield;

        // 10% performance fee on full yield (no hurdle)
        uint256 expectedFeeAmount = Math.mulDiv(netYield, PERFORMANCE_FEE_BPS, 10_000);
        uint256 expectedFeeShares = InvariantUtils.convertToShares(
            expectedFeeAmount, totalSupplyBefore, postYieldAssets - expectedFeeAmount, Math.Rounding.Floor
        );

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient);
        assertEq(feeSharesMinted, expectedFeeShares, "Fee shares should match 10% of yield");
        assertGt(feeSharesMinted, 0, "Fee should be non-zero");

        uint256 feeAssetValue = concreteStandardVault.previewRedeem(feeSharesMinted);
        assertApproxEqAbs(feeAssetValue, expectedFeeAmount, 1, "Fee asset value should be 10% of yield");
    }

    // ── Hurdle above current PPS: no fee ────────────────────────────────

    function testHurdleAboveCurrentPPS_noFee() public {
        // Set oracle BEFORE yield so withYieldAccrual during setter is a no-op
        hurdleOracle.setHurdleRate(1.2e18);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 recipientAfter = concreteStandardVault.balanceOf(performanceFeeRecipient);
        assertEq(recipientAfter, recipientBefore, "No fee when PPS <= hurdle");
    }

    // ── Hurdle exactly at post-yield PPS: no fee ────────────────────────

    function testHurdleAtCurrentPPS_noFee() public {
        // Post-yield: 1100e18 assets / 1000e18 shares = 1.1 exchange rate
        hurdleOracle.setHurdleRate(1.1e18);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT + 10); // +10 to overcome mock strategy rounding error
        assertEq(concreteStandardVault.convertToAssets(10 ** concreteStandardVault.decimals()), 1.1e18);

        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 recipientAfter = concreteStandardVault.balanceOf(performanceFeeRecipient);
        assertEq(recipientAfter, recipientBefore, "No fee when PPS == hurdle");
    }

    function testHurdleTinyAmountAbovePPS_smallFee() public {
        uint256 yieldAboveHurdle = 1e18;

        hurdleOracle.setHurdleRate(1.1e18);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT + yieldAboveHurdle + 10); // +10 to overcome mock strategy rounding error
        assertEq(concreteStandardVault.convertToAssets(10 ** concreteStandardVault.decimals()), 1.101e18);
        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);
        uint256 expectedFeeAmount = yieldAboveHurdle / 10; // 10% performance fee

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient) - recipientBefore;
        uint256 feeAssetValue = concreteStandardVault.previewRedeem(feeSharesMinted);
        assertApproxEqAbs(feeAssetValue, expectedFeeAmount, 1, "Fee value should be 10% of yield above hurdle");
        assertGt(feeSharesMinted, 0, "Fee should be non-zero when PPS > hurdle");
    }

    // ── Hurdle below current PPS: fee only on excess ────────────────────

    function testHurdleBelowCurrentPPS_feeOnExcess() public {
        hurdleOracle.setHurdleRate(1.05e18);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        // Post-yield PPS = 1.1, hurdle = 1.05 → excess = (1.1 - 1.05) * 1000 = 50e18
        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);
        uint256 totalSupplyBefore = concreteStandardVault.totalSupply();
        uint256 totalAssetsBefore = concreteStandardVault.cachedTotalAssets();

        uint256 netYield = _getActualYield();
        uint256 postYieldAssets = totalAssetsBefore + netYield;

        uint256 hurdleAssets = Math.mulDiv(1.05e18, totalSupplyBefore, ORACLE_PRECISION);
        uint256 expectedExcess = postYieldAssets - hurdleAssets;
        uint256 expectedFeeAmount = Math.mulDiv(expectedExcess, PERFORMANCE_FEE_BPS, 10_000);
        uint256 expectedFeeShares = InvariantUtils.convertToShares(
            expectedFeeAmount, totalSupplyBefore, postYieldAssets - expectedFeeAmount, Math.Rounding.Floor
        );

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient) - recipientBefore;
        assertEq(feeSharesMinted, expectedFeeShares, "Fee shares should match expected");
        assertGt(feeSharesMinted, 0, "Fee should be non-zero");
    }

    // ── Two accruals: first partial excess, second fully above hurdle ──

    function testTwoAccruals_secondFullyAboveHurdle() public {
        uint256 hurdleRate = 1.05e18;
        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e18);

        uint256 expectedFee1;
        uint256 expectedFee2;

        // ── Accrual 1: yield pushes PPS from 1.0 to 1.1, hurdle is 1.05 ──
        {
            _simulateYield(YIELD_AMOUNT); // +100e18 → 1100 assets / 1000 shares

            uint256 totalSupply = concreteStandardVault.totalSupply();
            uint256 totalAssets = concreteStandardVault.cachedTotalAssets();
            uint256 netYield = _getActualYield();
            uint256 postYieldAssets = totalAssets + netYield;

            uint256 hurdleAssets = Math.mulDiv(hurdleRate, totalSupply, ORACLE_PRECISION);
            uint256 excess = postYieldAssets - hurdleAssets;
            expectedFee1 = Math.mulDiv(excess, PERFORMANCE_FEE_BPS, 10_000);

            vm.prank(allocator);
            concreteStandardVault.accrueYield();

            uint256 feeValue =
                concreteStandardVault.previewRedeem(concreteStandardVault.balanceOf(performanceFeeRecipient));
            assertApproxEqAbs(feeValue, expectedFee1, 1, "Accrual 1: fee should be 10% of excess above hurdle");
        }

        // ── Accrual 2: PPS already above hurdle → full yield is taxed ─────
        {
            _simulateYield(50e18);

            uint256 netYield = _getActualYield();
            expectedFee2 = Math.mulDiv(netYield, PERFORMANCE_FEE_BPS, 10_000);

            uint256 feeSharesBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);

            vm.prank(allocator);
            concreteStandardVault.accrueYield();

            uint256 newFeeShares = concreteStandardVault.balanceOf(performanceFeeRecipient) - feeSharesBefore;
            uint256 feeValue = concreteStandardVault.previewRedeem(newFeeShares);
            assertApproxEqAbs(feeValue, expectedFee2, 2, "Accrual 2: fee should be 10% of full yield");
        }

        // Total fee >= sum because first batch of fee shares appreciated
        uint256 totalFeeValue =
            concreteStandardVault.previewRedeem(concreteStandardVault.balanceOf(performanceFeeRecipient));
        assertGe(
            totalFeeValue, expectedFee1 + expectedFee2 - 2, "Total fee value must be at least the sum of both accruals"
        );
    }

    // ── Fee is reduced compared to no-hurdle case ───────────────────────

    function testHurdleReducesFeeVsNoHurdle() public {
        // Snapshot before any allocation/yield so both runs are identical
        uint256 snapshotId = vm.snapshotState();

        // Run 1: with hurdle at 1.05
        hurdleOracle.setHurdleRate(1.05e18);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();
        uint256 feeSharesWithHurdle = concreteStandardVault.balanceOf(performanceFeeRecipient);

        vm.revertToState(snapshotId);

        // Run 2: no hurdle — standard fee on full net yield
        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();
        uint256 feeSharesNoHurdle = concreteStandardVault.balanceOf(performanceFeeRecipient);

        assertLt(feeSharesWithHurdle, feeSharesNoHurdle, "Hurdle should reduce fees");
        assertGt(feeSharesWithHurdle, 0, "Fees should still be non-zero above hurdle");
    }

    // ── 100% performance fee: exchange rate matches hurdle ──────────────

    function testFullPerformanceFee_exchangeRateMatchesHurdle() public {
        uint256 hurdleRate = 1.05e18;
        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(10_000);

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 postFeeExchangeRate = concreteStandardVault.convertToAssets(10 ** concreteStandardVault.decimals());

        assertApproxEqAbs(
            postFeeExchangeRate, hurdleRate, 1, "At 100% fee, post-fee exchange rate should equal the hurdle rate"
        );
    }

    // ── 100% fee with hurdle at initial PPS: all yield eaten ────────────

    function testFullPerformanceFee_hurdleAtInitialPPS_allYieldTaken() public {
        uint256 hurdleRate = 1e18;
        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(10_000);

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 postFeeExchangeRate = concreteStandardVault.convertToAssets(10 ** concreteStandardVault.decimals());

        assertApproxEqAbs(
            postFeeExchangeRate,
            hurdleRate,
            1,
            "At 100% fee with hurdle at initial PPS, exchange rate should stay at 1.0"
        );
    }

    // ── Unset oracle reverts to standard behavior ───────────────────────

    function testUnsetOracle_revertsToStandardFee() public {
        // Set then unset oracle (no pending yield, so withYieldAccrual is benign)
        hurdleOracle.setHurdleRate(1.05e18);
        vm.startPrank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(0)));
        vm.stopPrank();

        _allocateToStrategy(500e18);
        _simulateYield(YIELD_AMOUNT);

        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);
        uint256 totalSupplyBefore = concreteStandardVault.totalSupply();
        uint256 totalAssetsBefore = concreteStandardVault.cachedTotalAssets();
        uint256 netYield = _getActualYield();

        uint256 expectedFeeAmount = Math.mulDiv(netYield, PERFORMANCE_FEE_BPS, 10_000);
        uint256 expectedFeeShares = InvariantUtils.convertToShares(
            expectedFeeAmount, totalSupplyBefore, totalAssetsBefore + netYield - expectedFeeAmount, Math.Rounding.Floor
        );

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient) - recipientBefore;
        assertEq(feeSharesMinted, expectedFeeShares, "Should match standard (no-hurdle) fee");
    }

    // ── Hurdle with partial yield above threshold ───────────────────────

    function testHurdleWithSmallYield_partiallyAboveHurdle() public {
        hurdleOracle.setHurdleRate(1.01e18);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e18);

        uint256 smallYield = 20e18;
        _simulateYield(smallYield);

        uint256 totalSupplyBefore = concreteStandardVault.totalSupply();
        uint256 totalAssetsBefore = concreteStandardVault.cachedTotalAssets();
        uint256 netYield = _getActualYield();
        uint256 postYieldAssets = totalAssetsBefore + netYield;

        uint256 hurdleAssets = Math.mulDiv(1.01e18, totalSupplyBefore, ORACLE_PRECISION);
        uint256 excessAboveHurdle = postYieldAssets - hurdleAssets;

        assertLt(excessAboveHurdle, netYield, "Excess should be less than full yield");
        uint256 expectedFeeAmount = Math.mulDiv(excessAboveHurdle, PERFORMANCE_FEE_BPS, 10_000);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 feeRecipientBalance = concreteStandardVault.balanceOf(performanceFeeRecipient);
        uint256 feeAssetValue = concreteStandardVault.previewRedeem(feeRecipientBalance);

        assertApproxEqAbs(feeAssetValue, expectedFeeAmount, 2, "Fee value should match excess-based calculation");
    }

    // ── getHurdleRateOracle getter ──────────────────────────────────────

    function testGetHurdleRateOracle() public {
        assertEq(address(concreteStandardVault.getHurdleRateOracle()), address(0));

        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        assertEq(address(concreteStandardVault.getHurdleRateOracle()), address(hurdleOracle));
    }

    // ── 100% fee with real APY oracle over 3 accrual steps ─────────────

    function testFullPerformanceFee_multiStep_exchangeRateTracksAPY() public {
        uint256 targetAPY = 0.1e18; // 10% APY
        uint256 stepDuration = 365.25 days / 3; // ~4 months per step

        APYRateHurdleOracle apyOracle = new APYRateHurdleOracle(address(this));
        apyOracle.configure(1e18, targetAPY, uint40(block.timestamp));

        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(apyOracle)));

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(10_000);
        _allocateToStrategy(500e18);

        for (uint256 step = 1; step <= 5; step++) {
            vm.warp(block.timestamp + stepDuration);

            uint256 hurdleRate = apyOracle.getHurdleRate();

            // Inject yield well above the hurdle so there is always excess
            uint256 generousYield = 200e18;
            _simulateYield(generousYield);

            vm.prank(allocator);
            concreteStandardVault.accrueYield();

            uint256 exchangeRate = concreteStandardVault.convertToAssets(10 ** concreteStandardVault.decimals());
            console.log("step", exchangeRate);
            assertApproxEqRel(
                exchangeRate,
                hurdleRate,
                1e10, // 0.000001% tolerance
                string.concat("Step ", vm.toString(step), ": exchange rate should track hurdle")
            );
        }
    }

    // ── Fuzz: 100% fee – hurdle vs yield interaction ──────────────────

    function testFuzz_fullPerformanceFee_hurdleRate(uint256 yieldAmount, uint256 hurdleRate) public {
        yieldAmount = bound(yieldAmount, 1e18, 500e18);
        hurdleRate = bound(hurdleRate, 1e18, 2e18);

        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(10_000); // 100%

        _allocateToStrategy(500e18);
        _simulateYield(yieldAmount);

        uint256 oneShare = 10 ** concreteStandardVault.decimals();
        uint256 preFeeRate = concreteStandardVault.convertToAssets(oneShare);
        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 postFeeRate = concreteStandardVault.convertToAssets(oneShare);
        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient) - recipientBefore;

        if (preFeeRate <= hurdleRate) {
            uint256 expectedRate = Math.mulDiv(oneShare, INITIAL_DEPOSIT + yieldAmount, INITIAL_DEPOSIT);
            assertEq(feeSharesMinted, 0, "No fee when rate <= hurdle");
            assertApproxEqAbs(postFeeRate, expectedRate, 1, "Exchange rate should reflect full yield");
        } else {
            assertGt(feeSharesMinted, 0, "Fee should be taken when rate > hurdle");
            assertApproxEqAbs(postFeeRate, hurdleRate, 1, "Exchange rate should track hurdle at 100% fee");
        }
    }

    // ── Tiny supply: virtual-shares offset must not break hurdle ────────

    function testHurdle_verySmallTotalSupply_virtualSharesConsistency() public {
        uint256 tinySupply = 4;
        uint256 sharesToRedeem = concreteStandardVault.balanceOf(user1) - tinySupply;
        vm.prank(user1);
        concreteStandardVault.redeem(sharesToRedeem, user1, user1);

        assertEq(concreteStandardVault.totalSupply(), tinySupply);
        assertEq(concreteStandardVault.cachedTotalAssets(), tinySupply);

        uint256 hurdleRate = 1.5e18;
        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(10_000); // 100% to make post-fee rate == hurdle

        _allocateToStrategy(concreteStandardVault.cachedTotalAssets());

        uint256 yieldAmount = 4;
        _simulateYield(yieldAmount + 1); // +1 to overcome mock strategy virtual shares offset

        uint256 totalSupplyBefore = concreteStandardVault.totalSupply();
        uint256 totalAssetsBefore = concreteStandardVault.cachedTotalAssets();
        uint256 netYield = _getActualYield();
        uint256 postYieldAssets = totalAssetsBefore + netYield;

        // Mirror _capNetYieldToExcessAboveHurdleRate (includes +1 virtual offset)
        uint256 hurdleAssets = Math.mulDiv(hurdleRate, totalSupplyBefore + 1, ORACLE_PRECISION);
        uint256 excessAboveHurdle = (postYieldAssets + 1) <= hurdleAssets ? 0 : (postYieldAssets + 1) - hurdleAssets;
        uint256 yieldAboveHurdle = netYield > excessAboveHurdle ? excessAboveHurdle : netYield;

        uint256 expectedFeeAmount = yieldAboveHurdle; // 100% fee
        uint256 expectedFeeShares = InvariantUtils.convertToShares(
            expectedFeeAmount, totalSupplyBefore, postYieldAssets - expectedFeeAmount, Math.Rounding.Floor
        );

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient);
        assertEq(feeSharesMinted, expectedFeeShares, "Fee shares should match expected with tiny supply");
        assertGt(feeSharesMinted, 0, "Fee should be non-zero even with tiny supply");

        uint256 postFeeExchangeRate = concreteStandardVault.convertToAssets(10 ** concreteStandardVault.decimals());
        console.log("postFeeExchangeRate", postFeeExchangeRate);
        assertApproxEqAbs(
            postFeeExchangeRate,
            hurdleRate,
            1,
            "At 100% fee with tiny supply, post-fee exchange rate should equal hurdle rate"
        );
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _allocateToStrategy(uint256 amount) internal {
        bytes memory extraData = abi.encode(amount);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});

        vm.prank(allocator);
        concreteStandardVault.allocate(abi.encode(params));
    }

    function _simulateYield(uint256 yieldAmount) internal {
        asset.mint(address(this), yieldAmount);
        asset.approve(address(strategy), yieldAmount);
        strategy.simulateYield(yieldAmount);
    }

    function _getActualYield() internal view returns (uint256) {
        uint256 currentValue = strategy.totalAllocatedValue();
        uint256 allocatedAmount = concreteStandardVault.getStrategyData(address(strategy)).allocated;
        return currentValue > allocatedAmount ? currentValue - allocatedAmount : 0;
    }
}
