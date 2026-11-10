// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {IAllocateModule} from "../../../src/interface/IAllocateModule.sol";
import {IHurdleRateOracle} from "../../../src/interface/IHurdleRateOracle.sol";
import {ERC4626StrategyMock} from "../../mock/ERC4626StrategyMock.sol";
import {MockHurdleRateOracle} from "../../mock/MockHurdleRateOracle.sol";
import {InvariantUtils} from "../../invariant/helpers/InvariantUtils.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {AddStrategyWithDeallocationOrder} from "../../common/AddStrategyWithDeallocationOrder.sol";

contract HurdleRatePerformanceFeeFuzzTest is ConcreteStandardVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    address public user1;
    address public performanceFeeRecipient;
    ERC4626StrategyMock public strategy;
    MockHurdleRateOracle public hurdleOracle;
    uint256 public constant INITIAL_DEPOSIT = 1000e18;
    uint256 public constant ORACLE_PRECISION = 1e18;

    /// @dev EIP-7201 base slot for ConcreteStandardVaultImplStorage
    bytes32 private constant STORAGE_BASE = 0xe74d828616eceb28be4a8cf3f9eeee868e1f44ce928ee17a9d7ad296fa52be00;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        performanceFeeRecipient = makeAddr("performanceFeeRecipient");

        strategy = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        hurdleOracle = new MockHurdleRateOracle(18);

        vm.prank(factoryOwner);
        concreteStandardVault.updatePerformanceFeeRecipient(performanceFeeRecipient);

        asset.mint(user1, INITIAL_DEPOSIT);
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), INITIAL_DEPOSIT);
        concreteStandardVault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
    }

    function testFuzzHurdleRate_feeOnlyOnExcess(
        uint16 performanceFee,
        uint256 positiveYield,
        uint256 allocateAmount,
        uint256 hurdleRate
    ) public {
        performanceFee = uint16(bound(performanceFee, 1, 1000));
        allocateAmount = bound(allocateAmount, 1, INITIAL_DEPOSIT);
        positiveYield = bound(positiveYield, 1, INITIAL_DEPOSIT / 2);
        hurdleRate = bound(hurdleRate, 1e18, 1.5e18);

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(performanceFee)
        );

        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.HurdleRateOracle,
            abi.encode(IHurdleRateOracle(address(hurdleOracle)))
        );

        _allocateToStrategy(allocateAmount);
        _simulateYield(positiveYield);

        uint256 totalSupplyBefore = concreteStandardVault.totalSupply();
        uint256 cachedAssetsBefore = concreteStandardVault.cachedTotalAssets();
        uint256 netYield = _getActualYield();
        uint256 postYieldAssets = cachedAssetsBefore + netYield;

        uint256 hurdleAssets = Math.mulDiv(hurdleRate, totalSupplyBefore, ORACLE_PRECISION);

        uint256 expectedFeeAmount;
        if (postYieldAssets > hurdleAssets && netYield > 0) {
            uint256 excessAboveHurdle = postYieldAssets - hurdleAssets;
            uint256 feeableYield = netYield < excessAboveHurdle ? netYield : excessAboveHurdle;
            expectedFeeAmount = Math.mulDiv(feeableYield, performanceFee, 10_000);
        }

        uint256 expectedShares;
        if (expectedFeeAmount > 0) {
            expectedShares = InvariantUtils.convertToShares(
                expectedFeeAmount, totalSupplyBefore, postYieldAssets - expectedFeeAmount, Math.Rounding.Floor
            );
        }

        assertEq(concreteStandardVault.balanceOf(performanceFeeRecipient), 0);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 actualShares = concreteStandardVault.balanceOf(performanceFeeRecipient);

        if (expectedFeeAmount == 0) {
            assertEq(actualShares, 0, "No fee expected");
        } else {
            assertApproxEqAbs(actualShares, expectedShares, 1, "Fee shares mismatch");
        }
    }

    function testFuzzHurdleRate_noFeeWhenBelowHurdle(
        uint16 performanceFee,
        uint256 positiveYield,
        uint256 allocateAmount
    ) public {
        performanceFee = uint16(bound(performanceFee, 1, 1000));
        allocateAmount = bound(allocateAmount, 1, INITIAL_DEPOSIT);
        positiveYield = bound(positiveYield, 1, INITIAL_DEPOSIT / 4);

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(performanceFee)
        );

        hurdleOracle.setHurdleRate(2e18);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.HurdleRateOracle,
            abi.encode(IHurdleRateOracle(address(hurdleOracle)))
        );

        _allocateToStrategy(allocateAmount);
        _simulateYield(positiveYield);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        assertEq(concreteStandardVault.balanceOf(performanceFeeRecipient), 0, "No fee when below hurdle");
    }

    function testFuzzHurdleRate_reducesFeesVsNoHurdle(
        uint16 performanceFee,
        uint256 positiveYield,
        uint256 allocateAmount
    ) public {
        performanceFee = uint16(bound(performanceFee, 100, 1000));
        allocateAmount = bound(allocateAmount, 100e18, INITIAL_DEPOSIT);
        positiveYield = bound(positiveYield, 50e18, INITIAL_DEPOSIT / 2);

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(performanceFee)
        );

        uint256 snapshotId = vm.snapshotState();

        // Run 1: with hurdle at 1.02
        hurdleOracle.setHurdleRate(1.02e18);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.HurdleRateOracle,
            abi.encode(IHurdleRateOracle(address(hurdleOracle)))
        );

        _allocateToStrategy(allocateAmount);
        _simulateYield(positiveYield);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();
        uint256 feeSharesWithHurdle = concreteStandardVault.balanceOf(performanceFeeRecipient);

        vm.revertToState(snapshotId);

        // Run 2: no hurdle
        _allocateToStrategy(allocateAmount);
        _simulateYield(positiveYield);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();
        uint256 feeSharesNoHurdle = concreteStandardVault.balanceOf(performanceFeeRecipient);

        assertLe(feeSharesWithHurdle, feeSharesNoHurdle, "Hurdle should never increase fees");
    }

    function testFuzzHurdleRate_100pctFee_exchangeRateMatchesHurdle(uint256 positiveYield, uint256 hurdleRate) public {
        uint256 allocateAmount = INITIAL_DEPOSIT;
        positiveYield = bound(positiveYield, 10e18, INITIAL_DEPOSIT / 2);
        hurdleRate = bound(hurdleRate, 1e18, 1.4e18);

        hurdleOracle.setHurdleRate(hurdleRate);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.HurdleRateOracle,
            abi.encode(IHurdleRateOracle(address(hurdleOracle)))
        );

        _setPerformanceFeeDirect(10_000);

        _allocateToStrategy(allocateAmount);
        _simulateYield(positiveYield);

        uint256 cachedBefore = concreteStandardVault.cachedTotalAssets();
        uint256 supplyBefore = concreteStandardVault.totalSupply();
        uint256 netYield = _getActualYield();
        uint256 postYieldPPS = Math.mulDiv(cachedBefore + netYield, ORACLE_PRECISION, supplyBefore);

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 totalAssetsAfter = concreteStandardVault.cachedTotalAssets();
        uint256 totalSupplyAfter = concreteStandardVault.totalSupply();
        uint256 postFeeExchangeRate = Math.mulDiv(totalAssetsAfter, ORACLE_PRECISION, totalSupplyAfter);

        if (postYieldPPS > hurdleRate) {
            assertApproxEqAbs(postFeeExchangeRate, hurdleRate, 1, "Post-fee exchange rate should equal hurdle");
        } else {
            assertApproxEqAbs(postFeeExchangeRate, postYieldPPS, 1, "No fee when PPS <= hurdle");
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

    function _setPerformanceFeeDirect(uint16 feeBps) internal {
        bytes32 slot = bytes32(uint256(STORAGE_BASE) + 6);
        bytes32 current = vm.load(address(concreteStandardVault), slot);
        bytes32 cleared = current & ~bytes32(uint256(0xFFFF) << 160);
        bytes32 updated = cleared | bytes32(uint256(feeBps) << 160);
        vm.store(address(concreteStandardVault), slot, updated);
    }
}
