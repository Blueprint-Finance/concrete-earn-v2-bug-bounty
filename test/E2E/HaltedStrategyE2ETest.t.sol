// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplBaseSetup} from "../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {IAllocateModule} from "../../src/interface/IAllocateModule.sol";
import {ERC4626StrategyMock} from "../mock/ERC4626StrategyMock.sol";
import {ConcreteERC4626Mock} from "../mock/ConcreteERC4626Mock.sol";
import {IConcreteStandardVaultImpl} from "../../src/interface/IConcreteStandardVaultImpl.sol";
import {AddStrategyWithDeallocationOrder} from "../common/AddStrategyWithDeallocationOrder.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../src/lib/Roles.sol";

contract HaltedStrategyE2ETest is ConcreteStandardVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    address public user1;
    address public user2;

    ERC4626StrategyMock public activeStrategy;
    ERC4626StrategyMock public haltedStrategy;
    ERC4626StrategyMock public strategy3;

    uint256 public constant INITIAL_DEPOSIT = 1000e18;
    uint256 public constant STRATEGY_ALLOCATION = 300e18;

    event StrategyStatusToggled(address indexed strategy);

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy strategies
        activeStrategy = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
        haltedStrategy = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
        strategy3 = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));

        vm.label(address(activeStrategy), "activeStrategy");
        vm.label(address(haltedStrategy), "haltedStrategy");
        vm.label(address(strategy3), "strategy3");
        vm.label(user1, "user1");
        vm.label(user2, "user2");

        // Add strategies to vault (all start as Active)
        addStrategyWithDeallocationOrder(
            address(activeStrategy), address(concreteStandardVault), allocator, strategyOperator
        );
        addStrategyWithDeallocationOrder(
            address(haltedStrategy), address(concreteStandardVault), allocator, strategyOperator
        );
        addStrategyWithDeallocationOrder(
            address(strategy3), address(concreteStandardVault), allocator, strategyOperator
        );

        // Give users some tokens
        asset.mint(user1, INITIAL_DEPOSIT * 2);
        asset.mint(user2, INITIAL_DEPOSIT * 2);

        // Give strategies some tokens for yield simulation
        asset.mint(address(this), INITIAL_DEPOSIT * 10);
    }

    function testToggleStrategyFromActiveToHalted() public {
        // Verify strategy starts as Active
        IConcreteStandardVaultImpl.StrategyData memory strategyData =
            concreteStandardVault.getStrategyData(address(haltedStrategy));
        assertEq(uint256(strategyData.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Active));

        // Toggle strategy to Halted
        vm.expectEmit();
        emit StrategyStatusToggled(address(haltedStrategy));

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Verify strategy is now Halted
        strategyData = concreteStandardVault.getStrategyData(address(haltedStrategy));
        assertEq(uint256(strategyData.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Halted));
    }

    function testToggleStrategyFromHaltedToActive() public {
        // First halt the strategy
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Verify strategy is Halted
        IConcreteStandardVaultImpl.StrategyData memory strategyData =
            concreteStandardVault.getStrategyData(address(haltedStrategy));
        assertEq(uint256(strategyData.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Halted));

        // Toggle back to Active
        vm.expectEmit();
        emit StrategyStatusToggled(address(haltedStrategy));

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Verify strategy is now Active again
        strategyData = concreteStandardVault.getStrategyData(address(haltedStrategy));
        assertEq(uint256(strategyData.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Active));
    }

    function testToggleStrategyRevertsForNonExistentStrategy() public {
        address nonExistentStrategy = makeAddr("nonExistentStrategy");

        vm.prank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyDoesNotExist.selector);
        concreteStandardVault.toggleStrategyStatus(nonExistentStrategy);
    }

    function testToggleStrategyRevertsForUnauthorizedUser() public {
        address unauthorizedUser = makeAddr("unauthorizedUser");

        vm.prank(unauthorizedUser);
        vm.expectRevert();
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));
    }

    function testAllocationIgnoresHaltedStrategies() public {
        // Setup: Users deposit funds
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _depositAsUser(user2, INITIAL_DEPOSIT);

        // Halt one strategy
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Allocate to both strategies (halted one should be ignored)
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](2);
        params[0] = IAllocateModule.AllocateParams({
            strategy: address(activeStrategy), isDeposit: true, extraData: abi.encode(400e18)
        });
        params[1] = IAllocateModule.AllocateParams({
            strategy: address(haltedStrategy), isDeposit: true, extraData: abi.encode(400e18)
        });

        bytes memory allocateData = abi.encode(params);

        vm.prank(allocator);
        concreteStandardVault.allocate(allocateData);

        // Verify only active strategy received allocation
        assertEq(activeStrategy.totalAllocatedValue(), 400e18);
        assertEq(haltedStrategy.totalAllocatedValue(), 0);

        // Verify strategy data reflects allocations
        IConcreteStandardVaultImpl.StrategyData memory activeData =
            concreteStandardVault.getStrategyData(address(activeStrategy));
        IConcreteStandardVaultImpl.StrategyData memory haltedData =
            concreteStandardVault.getStrategyData(address(haltedStrategy));

        assertEq(activeData.allocated, 400e18);
        assertEq(haltedData.allocated, 0);
    }

    function testWithdrawalIgnoresHaltedStrategies() public {
        // Setup: Deposit and allocate to both strategies
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _depositAsUser(user2, INITIAL_DEPOSIT);

        // Allocate to both strategies while they're Active
        _allocateToStrategy(address(activeStrategy), 400e18);
        _allocateToStrategy(address(haltedStrategy), 400e18);

        // Halt one strategy after allocation
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Allocate remaining funds to leave minimal idle balance
        _allocateToStrategy(address(strategy3), 1200e18);

        // Capture user1's balance before withdrawal
        uint256 user1BalanceBefore = asset.balanceOf(user1);

        // Attempt large withdrawal that would normally require both strategies
        uint256 withdrawalAmount = 600e18;

        // Should still work, but only use Active strategies for deallocation
        vm.prank(user1);
        concreteStandardVault.withdraw(withdrawalAmount, user1, user1);

        // Verify user received the withdrawal amount (not total balance)
        uint256 user1BalanceAfter = asset.balanceOf(user1);
        uint256 actualWithdrawn = user1BalanceAfter - user1BalanceBefore;
        assertEq(actualWithdrawn, withdrawalAmount);

        // Verify halted strategy allocation remained unchanged
        assertEq(haltedStrategy.totalAllocatedValue(), 400e18);

        // Verify active strategies were used for deallocation
        uint256 activeStrategyRemaining = activeStrategy.totalAllocatedValue();
        uint256 strategy3Remaining = strategy3.totalAllocatedValue();

        // At least one of the active strategies should have been deallocated from
        assertTrue(activeStrategyRemaining < 400e18 || strategy3Remaining < 1200e18);
    }

    function testAccrueYieldIgnoresHaltedStrategies() public {
        // Setup: Deposit and allocate to both strategies
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _depositAsUser(user2, INITIAL_DEPOSIT);

        _allocateToStrategy(address(activeStrategy), 400e18);
        _allocateToStrategy(address(haltedStrategy), 400e18);

        // Halt one strategy after allocation
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Simulate yield in both strategies
        uint256 yieldAmount = 40e18; // 10% yield

        asset.approve(address(activeStrategy), yieldAmount);
        activeStrategy.simulateYield(yieldAmount);

        asset.approve(address(haltedStrategy), yieldAmount);
        haltedStrategy.simulateYield(yieldAmount);

        // Get strategy allocated amounts before yield accrual
        IConcreteStandardVaultImpl.StrategyData memory activeDataBefore =
            concreteStandardVault.getStrategyData(address(activeStrategy));
        IConcreteStandardVaultImpl.StrategyData memory haltedDataBefore =
            concreteStandardVault.getStrategyData(address(haltedStrategy));

        // Get expected yield before accrual
        uint256 expectedActiveYield = _getActualYield(address(activeStrategy));
        uint256 expectedHaltedYield = _getActualYield(address(haltedStrategy));

        // Get total assets deposited before accrual
        uint256 lastTotalAssetsBefore = concreteStandardVault.cachedTotalAssets();

        // Yield accrual should only process Active strategies
        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 lastTotalAssetsAfter = concreteStandardVault.cachedTotalAssets();

        // Only yield from active strategy should be accrued (halted strategy yield ignored)
        // Note: lastTotalAssets is updated by yield accrual and reflects actual accrued amounts
        assertGt(lastTotalAssetsAfter, lastTotalAssetsBefore); // Should increase due to active strategy yield

        // More precise check: total increase should be close to active strategy yield (allowing for fees)
        uint256 actualIncrease = lastTotalAssetsAfter - lastTotalAssetsBefore;
        assertGe(actualIncrease, expectedActiveYield - 2); // Allow small rounding for fees
        assertLt(actualIncrease, expectedActiveYield + expectedHaltedYield); // Should not include halted yield

        // Verify halted strategy's allocated amount wasn't updated
        IConcreteStandardVaultImpl.StrategyData memory haltedDataAfter =
            concreteStandardVault.getStrategyData(address(haltedStrategy));
        assertEq(haltedDataAfter.allocated, haltedDataBefore.allocated); // Should remain unchanged

        // Verify active strategy's allocated amount was updated with the actual net yield
        IConcreteStandardVaultImpl.StrategyData memory activeDataAfter =
            concreteStandardVault.getStrategyData(address(activeStrategy));
        uint256 actualActiveYieldAccrued = activeDataAfter.allocated - activeDataBefore.allocated;
        assertEq(actualActiveYieldAccrued, expectedActiveYield); // Should match the expected yield
    }

    function testRemoveHaltedStrategyWithAllocatedFundsReverts() public {
        // Setup: Deposit and allocate to strategy
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(haltedStrategy), 400e18);

        // Halt the strategy
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // A Halted strategy that still holds an allocation can no longer be removed directly:
        // dropping its `allocated` without adjusting cachedTotalAssets would inflate the derived
        // floating amount (phantom funds). It must be reconciled first.
        vm.prank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyHasAllocation.selector);
        concreteStandardVault.removeStrategy(address(haltedStrategy));
    }

    function testRealizeHaltedStrategyLoss() public {
        // Setup: Deposit and allocate to strategy
        _depositAsUser(user1, INITIAL_DEPOSIT);
        uint256 allocationAmount = 400e18;
        _allocateToStrategy(address(haltedStrategy), allocationAmount);

        uint256 cachedBefore = concreteStandardVault.cachedTotalAssets();

        // Halt the strategy
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        vm.expectEmit(true, false, false, true);
        emit IConcreteStandardVaultImpl.StrategyLossRealized(address(haltedStrategy), allocationAmount);

        // Realize the frozen position as a loss and remove the strategy
        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(0));

        // cachedTotalAssets dropped by the realized loss (no phantom floating left behind)
        assertEq(concreteStandardVault.cachedTotalAssets(), cachedBefore - allocationAmount, "cTA written down by loss");

        // Strategy removed and data cleared
        address[] memory strategies = concreteStandardVault.getStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            assertTrue(strategies[i] != address(haltedStrategy));
        }
        IConcreteStandardVaultImpl.StrategyData memory strategyData =
            concreteStandardVault.getStrategyData(address(haltedStrategy));
        assertEq(uint256(strategyData.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Inactive));
        assertEq(strategyData.allocated, 0);
    }

    function testRealizeHaltedStrategyLossRevertsWhenActive() public {
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(activeStrategy), 400e18);

        vm.prank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyNotHalted.selector);
        concreteStandardVault.reconcileHaltedStrategy(address(activeStrategy), address(0));
    }

    function testRealizeHaltedStrategyLossRevertsWhenNoAllocation() public {
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        vm.prank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyHasNoAllocation.selector);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(0));
    }

    function testMigrateHaltedStrategyPreservesAccounting() public {
        // Setup: Deposit and allocate to the strategy that will become "broken"
        _depositAsUser(user1, INITIAL_DEPOSIT);
        uint256 allocationAmount = 400e18;
        _allocateToStrategy(address(haltedStrategy), allocationAmount);

        uint256 cachedTotalAssetsBefore = concreteStandardVault.cachedTotalAssets();

        // Halt the broken strategy
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Migrate its allocation onto an Active strategy and remove the broken one.
        vm.expectEmit(true, true, false, true);
        emit IConcreteStandardVaultImpl.StrategyAllocationMigrated(
            address(haltedStrategy), address(activeStrategy), allocationAmount
        );

        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(activeStrategy));

        // The migration itself preserves cachedTotalAssets and the aggregate allocation, so the
        // stored accounting (and the derived floating amount) is unchanged — no phantom funds.
        assertEq(
            concreteStandardVault.cachedTotalAssets(),
            cachedTotalAssetsBefore,
            "cachedTotalAssets unchanged after migration"
        );
        // totalAssets() previews accrual, so until the position is physically recovered into the
        // Active destination it surfaces the unbacked allocation as an unrealized loss.
        assertEq(
            concreteStandardVault.totalAssets(),
            cachedTotalAssetsBefore - allocationAmount,
            "totalAssets previews the unbacked allocation as a loss until recovered"
        );
        assertEq(
            concreteStandardVault.getStrategyData(address(activeStrategy)).allocated,
            allocationAmount,
            "allocation migrated to active strategy"
        );

        // Broken strategy removed from the set.
        address[] memory strategies = concreteStandardVault.getStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            assertTrue(strategies[i] != address(haltedStrategy));
        }
    }

    function testMigratedAllocationRealizesLossOnAccrualWhenNotRecovered() public {
        _depositAsUser(user1, INITIAL_DEPOSIT);
        uint256 allocationAmount = 400e18;
        _allocateToStrategy(address(haltedStrategy), allocationAmount);

        uint256 cachedTotalAssetsBefore = concreteStandardVault.cachedTotalAssets();

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(activeStrategy));

        // Funds were NOT recovered into the destination strategy, so it holds 0 while its
        // allocated reads `allocationAmount`. The next accrual realizes the shortfall as a loss.
        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        assertEq(
            concreteStandardVault.cachedTotalAssets(),
            cachedTotalAssetsBefore - allocationAmount,
            "loss realized on accrual when not recovered"
        );
        assertEq(
            concreteStandardVault.getStrategyData(address(activeStrategy)).allocated,
            0,
            "allocation written down to real value"
        );
    }

    function testMigratedAllocationNoLossWhenRecovered() public {
        _depositAsUser(user1, INITIAL_DEPOSIT);
        uint256 allocationAmount = 400e18;
        _allocateToStrategy(address(haltedStrategy), allocationAmount);

        uint256 cachedTotalAssetsBefore = concreteStandardVault.cachedTotalAssets();

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(activeStrategy));

        // Simulate out-of-band recovery: the rescued assets are deposited into the destination
        // strategy's underlying position so its real value matches the migrated allocation.
        ConcreteERC4626Mock underlying = activeStrategy.underlyingVault();
        asset.approve(address(underlying), allocationAmount);
        underlying.deposit(allocationAmount, address(activeStrategy));
        assertEq(activeStrategy.totalAllocatedValue(), allocationAmount, "recovered value in place");

        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        assertEq(concreteStandardVault.cachedTotalAssets(), cachedTotalAssetsBefore, "no loss when fully recovered");
        assertEq(
            concreteStandardVault.getStrategyData(address(activeStrategy)).allocated,
            allocationAmount,
            "allocation intact after recovery"
        );
    }

    function testRealizeHaltedStrategyLossWorksWhilePaused() public {
        _depositAsUser(user1, INITIAL_DEPOSIT);
        uint256 allocationAmount = 400e18;
        _allocateToStrategy(address(haltedStrategy), allocationAmount);

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        uint256 cachedBefore = concreteStandardVault.cachedTotalAssets();

        // Pause the vault (incident response) and confirm reconciliation still works.
        _pauseVault();

        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(0));

        assertEq(concreteStandardVault.cachedTotalAssets(), cachedBefore - allocationAmount);
    }

    function testMigrateHaltedStrategyWorksWhilePaused() public {
        _depositAsUser(user1, INITIAL_DEPOSIT);
        uint256 allocationAmount = 400e18;
        _allocateToStrategy(address(haltedStrategy), allocationAmount);

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Pause the vault (incident response) and confirm migration still works.
        _pauseVault();

        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(activeStrategy));

        assertEq(
            concreteStandardVault.getStrategyData(address(activeStrategy)).allocated,
            allocationAmount,
            "allocation migrated while paused"
        );
    }

    function testMigrateRevertsWhenSourceNotHalted() public {
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(activeStrategy), 400e18);

        vm.prank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyNotHalted.selector);
        concreteStandardVault.reconcileHaltedStrategy(address(activeStrategy), address(strategy3));
    }

    function testMigrateRevertsWhenTargetNotActive() public {
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(haltedStrategy), 400e18);

        // Halt both the source and the intended target.
        vm.startPrank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));
        concreteStandardVault.toggleStrategyStatus(address(strategy3));
        vm.stopPrank();

        vm.prank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyIsHalted.selector);
        concreteStandardVault.reconcileHaltedStrategy(address(haltedStrategy), address(strategy3));
    }

    function testCannotRemoveActiveStrategyWithAllocatedFunds() public {
        // Setup: Deposit and allocate to strategy
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(activeStrategy), 400e18);

        // Should NOT be able to remove active strategy with allocated funds
        vm.prank(strategyOperator);
        vm.expectRevert();
        concreteStandardVault.removeStrategy(address(activeStrategy));
    }

    function testRemoveActiveStrategyWithZeroAllocation() public {
        // Strategy with no allocation should be removable regardless of status
        // First, remove strategy3 from deallocation order
        address[] memory currentOrder = concreteStandardVault.getDeallocationOrder();
        address[] memory newOrder = new address[](currentOrder.length - 1);
        uint256 newIndex = 0;

        for (uint256 i = 0; i < currentOrder.length; i++) {
            if (currentOrder[i] != address(strategy3)) {
                newOrder[newIndex] = currentOrder[i];
                newIndex++;
            }
        }

        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(newOrder);

        // Now remove the strategy
        vm.prank(strategyOperator);
        concreteStandardVault.removeStrategy(address(strategy3));

        // Verify strategy was removed
        address[] memory strategies = concreteStandardVault.getStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            assertTrue(strategies[i] != address(strategy3));
        }
    }

    function testHaltedStrategySkipsAllocationAndWithdrawal() public {
        // Setup: Deposit funds and allocate to active strategy
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _depositAsUser(user2, INITIAL_DEPOSIT);

        _allocateToStrategy(address(activeStrategy), 800e18);
        _allocateToStrategy(address(haltedStrategy), 800e18);

        // Halt one strategy
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(haltedStrategy));

        // Allocate remaining idle funds to test strategy selection
        _allocateToStrategy(address(strategy3), 400e18);

        // Calculate max withdrawable (should only consider active strategies)
        uint256 maxWithdrawable = concreteStandardVault.maxWithdraw(user1);

        // Withdraw the maximum available (should skip halted strategy)
        vm.prank(user1);
        concreteStandardVault.withdraw(maxWithdrawable, user1, user1);

        // Verify halted strategy was not touched
        assertEq(haltedStrategy.totalAllocatedValue(), 800e18);

        // Verify active strategies were used
        assertTrue(activeStrategy.totalAllocatedValue() < 800e18 || strategy3.totalAllocatedValue() < 400e18);
    }

    function testMultipleStrategyStatusToggles() public {
        // Test multiple toggles work correctly
        address[] memory strategiesToToggle = new address[](2);
        strategiesToToggle[0] = address(activeStrategy);
        strategiesToToggle[1] = address(haltedStrategy);

        vm.startPrank(strategyOperator);

        // Toggle both strategies to Halted
        for (uint256 i = 0; i < strategiesToToggle.length; i++) {
            concreteStandardVault.toggleStrategyStatus(strategiesToToggle[i]);

            IConcreteStandardVaultImpl.StrategyData memory data =
                concreteStandardVault.getStrategyData(strategiesToToggle[i]);
            assertEq(uint256(data.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Halted));
        }

        // Toggle both strategies back to Active
        for (uint256 i = 0; i < strategiesToToggle.length; i++) {
            concreteStandardVault.toggleStrategyStatus(strategiesToToggle[i]);

            IConcreteStandardVaultImpl.StrategyData memory data =
                concreteStandardVault.getStrategyData(strategiesToToggle[i]);
            assertEq(uint256(data.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Active));
        }

        vm.stopPrank();
    }

    // Helper functions

    function _getActualYield(address strategy) internal view returns (uint256) {
        uint256 currentValue = ERC4626StrategyMock(strategy).totalAllocatedValue();
        uint256 allocatedAmount = concreteStandardVault.getStrategyData(strategy).allocated;
        return currentValue > allocatedAmount ? currentValue - allocatedAmount : 0;
    }

    function _pauseVault() internal {
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);
        vm.prank(pauser);
        concreteStandardVault.pause();
    }

    function _depositAsUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(concreteStandardVault), amount);
        concreteStandardVault.deposit(amount, user);
        vm.stopPrank();
    }

    function _allocateToStrategy(address strategy, uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({strategy: strategy, isDeposit: true, extraData: abi.encode(amount)});

        bytes memory allocateData = abi.encode(params);

        vm.prank(allocator);
        concreteStandardVault.allocate(allocateData);
    }
}
