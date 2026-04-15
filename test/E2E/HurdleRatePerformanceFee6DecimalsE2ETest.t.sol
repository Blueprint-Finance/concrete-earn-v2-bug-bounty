// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    TestBaseSetup,
    IConcreteStandardVaultImpl,
    ConcreteStandardVaultImpl,
    IContractId
} from "../common/TestBaseSetup.t.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {ERC4626StrategyMock} from "../mock/ERC4626StrategyMock.sol";
import {MockHurdleRateOracle} from "../mock/MockHurdleRateOracle.sol";
import {AllocateModule} from "../../src/module/AllocateModule.sol";
import {IAllocateModule} from "../../src/interface/IAllocateModule.sol";
import {IHurdleRateOracle} from "../../src/interface/IHurdleRateOracle.sol";
import {InvariantUtils} from "../invariant/helpers/InvariantUtils.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../src/lib/Roles.sol";
import {AddStrategyWithDeallocationOrder} from "../common/AddStrategyWithDeallocationOrder.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

contract ERC20Mock6Decimals is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Mirrors HurdleRatePerformanceFeeE2ETest but with a 6-decimal asset
///      while the hurdle oracle stays at 18-decimal precision.
contract HurdleRatePerformanceFee6DecimalsE2ETest is TestBaseSetup, AddStrategyWithDeallocationOrder {
    uint16 public constant PERFORMANCE_FEE_BPS = 1000; // 10% performance fee
    uint256 public constant INITIAL_DEPOSIT = 1000e6;
    uint256 public constant YIELD_AMOUNT = 100e6; // 10% yield
    uint8 public constant ORACLE_DECIMALS = 18;
    uint256 public constant ORACLE_PRECISION = 1e18;

    address public vaultOwner;
    address public vaultManager;
    address public hookManager;
    address public strategyOperator;
    address public allocator;
    address public user1;
    address public performanceFeeRecipient;

    ERC20Mock6Decimals public asset;
    AllocateModule public allocateModule;
    ConcreteStandardVaultImpl public concreteStandardVault;
    ERC4626StrategyMock public strategy;
    MockHurdleRateOracle public hurdleOracle;

    function setUp() public override {
        TestBaseSetup.setUp();

        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        hookManager = makeAddr("hookManager");
        strategyOperator = makeAddr("strategyOperator");
        allocator = makeAddr("allocator");
        user1 = makeAddr("user1");
        performanceFeeRecipient = makeAddr("performanceFeeRecipient");

        asset = new ERC20Mock6Decimals();
        allocateModule = new AllocateModule();

        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        concreteStandardVault = ConcreteStandardVaultImpl(
            factory.create(
                vaultImpl,
                vaultOwner,
                abi.encode(address(allocateModule), address(asset), vaultManager, "Concrete Vault 6d", "CV6d")
            )
        );

        vm.label(address(concreteStandardVault), "concreteStandardVault6d");
        vm.label(address(asset), "asset6d");

        vm.startPrank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.STRATEGY_MANAGER, strategyOperator);
        concreteStandardVault.grantRole(RolesLib.ALLOCATOR, allocator);
        concreteStandardVault.grantRole(RolesLib.HOOK_MANAGER, hookManager);
        vm.stopPrank();

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

    // ── Sanity: vault is 6 decimals, oracle is 18 ────────────────────────

    function testDecimals() public view {
        assertEq(concreteStandardVault.decimals(), 6);
        assertEq(hurdleOracle.precision(), 1e18);
    }

    // ── Standard path: 10% fee on yield above hurdle ─────────────────────

    function testHurdleFeeOnExcess_6decimals() public {
        uint256 yieldAboveHurdle = 1e6;

        hurdleOracle.setHurdleRate(1.1e18);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        _allocateToStrategy(500e6);
        _simulateYield(YIELD_AMOUNT + yieldAboveHurdle + 10); // +10 to overcome mock strategy rounding

        uint256 oneShare = 10 ** concreteStandardVault.decimals();
        uint256 expectedPreFeeRate =
            Math.mulDiv(oneShare, INITIAL_DEPOSIT + YIELD_AMOUNT + yieldAboveHurdle, INITIAL_DEPOSIT);
        assertApproxEqAbs(
            concreteStandardVault.convertToAssets(oneShare),
            expectedPreFeeRate,
            1,
            "Pre-fee rate should reflect full yield"
        );

        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);
        uint256 expectedFeeAmount = yieldAboveHurdle / 10; // 10% performance fee

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient) - recipientBefore;
        uint256 feeAssetValue = concreteStandardVault.previewRedeem(feeSharesMinted);
        assertApproxEqAbs(feeAssetValue, expectedFeeAmount, 1, "Fee value should be 10% of yield above hurdle");
        assertGt(feeSharesMinted, 0, "Fee should be non-zero when PPS > hurdle");
    }

    // ── 100% fee: exchange rate tracks hurdle ────────────────────────────

    function testFullPerformanceFee_exchangeRateMatchesHurdle_6decimals() public {
        uint256 hurdleRate = 1.05e18;
        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(10_000); // 100%

        _allocateToStrategy(500e6);
        _simulateYield(YIELD_AMOUNT);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 oneShare = 10 ** concreteStandardVault.decimals();
        uint256 postFeeRate = concreteStandardVault.convertToAssets(oneShare);
        uint256 expectedRate = Math.mulDiv(hurdleRate, oneShare, ORACLE_PRECISION);
        assertApproxEqAbs(postFeeRate, expectedRate, 1, "At 100% fee, exchange rate should track hurdle");
    }

    // ── Fuzz: 100% fee – hurdle vs yield interaction ─────────────────────

    function testFuzz_fullPerformanceFee_hurdleRate_6decimals(uint256 yieldAmount, uint256 hurdleRate) public {
        yieldAmount = bound(yieldAmount, 1e6, 500e6);
        hurdleRate = bound(hurdleRate, 1e18, 2e18);

        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.setHurdleRateOracle(IHurdleRateOracle(address(hurdleOracle)));

        vm.prank(vaultManager);
        concreteStandardVault.updatePerformanceFee(10_000); // 100%

        _allocateToStrategy(500e6);
        _simulateYield(yieldAmount);

        uint256 oneShare = 10 ** concreteStandardVault.decimals();
        uint256 preFeeRate = concreteStandardVault.convertToAssets(oneShare);
        uint256 preFeeRateScaled = Math.mulDiv(preFeeRate, ORACLE_PRECISION, oneShare);
        uint256 recipientBefore = concreteStandardVault.balanceOf(performanceFeeRecipient);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 postFeeRate = concreteStandardVault.convertToAssets(oneShare);
        uint256 feeSharesMinted = concreteStandardVault.balanceOf(performanceFeeRecipient) - recipientBefore;

        if (preFeeRateScaled <= hurdleRate) {
            uint256 expectedRate = Math.mulDiv(oneShare, INITIAL_DEPOSIT + yieldAmount, INITIAL_DEPOSIT);
            assertEq(feeSharesMinted, 0, "No fee when rate <= hurdle");
            assertApproxEqAbs(postFeeRate, expectedRate, 1, "Exchange rate should reflect full yield");
        } else {
            uint256 expectedRate = Math.mulDiv(hurdleRate, oneShare, ORACLE_PRECISION);
            assertGt(feeSharesMinted, 0, "Fee should be taken when rate > hurdle");
            assertApproxEqAbs(postFeeRate, expectedRate, 1, "Exchange rate should track hurdle at 100% fee");
        }
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
