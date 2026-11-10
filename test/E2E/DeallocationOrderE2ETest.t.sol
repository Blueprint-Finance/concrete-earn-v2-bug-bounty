// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplBaseSetup} from "../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {IAllocateModule} from "../../src/interface/IAllocateModule.sol";
import {ERC4626StrategyMock} from "../mock/ERC4626StrategyMock.sol";
import {IConcreteStandardVaultImpl} from "../../src/interface/IConcreteStandardVaultImpl.sol";
import {AddStrategyWithDeallocationOrder} from "../common/AddStrategyWithDeallocationOrder.sol";

contract DeallocationOrderE2ETest is ConcreteStandardVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    address public user1;
    address public user2;

    ERC4626StrategyMock public strategy1;
    ERC4626StrategyMock public strategy2;
    ERC4626StrategyMock public strategy3;

    uint256 public constant INITIAL_DEPOSIT = 1000e18;
    uint256 public constant STRATEGY_ALLOCATION = 300e18;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy strategies
        strategy1 = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
        strategy2 = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
        strategy3 = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));

        vm.label(address(strategy1), "strategy1");
        vm.label(address(strategy2), "strategy2");
        vm.label(address(strategy3), "strategy3");
        vm.label(user1, "user1");
        vm.label(user2, "user2");

        // Add strategies to vault
        addStrategyWithDeallocationOrder(
            address(strategy1), address(concreteStandardVault), allocator, strategyOperator
        );
        addStrategyWithDeallocationOrder(
            address(strategy2), address(concreteStandardVault), allocator, strategyOperator
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

    function testWithdrawalsFollowDeallocationOrder() public {
        // Setup: Users deposit and allocate to all strategies
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _depositAsUser(user2, INITIAL_DEPOSIT);

        // Allocate to all strategies (allocate all available funds)
        uint256 totalDeposited = INITIAL_DEPOSIT * 2; // From both users
        uint256 allocationPerStrategy = totalDeposited / 3; // Equal allocation to each strategy
        _allocateToStrategy(address(strategy1), allocationPerStrategy);
        _allocateToStrategy(address(strategy2), allocationPerStrategy);
        _allocateToStrategy(address(strategy3), allocationPerStrategy);

        // Set deallocation order to be reversed (3, 2, 1)
        address[] memory reversedOrder = new address[](3);
        reversedOrder[0] = address(strategy3);
        reversedOrder[1] = address(strategy2);
        reversedOrder[2] = address(strategy1);

        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(reversedOrder);

        // Verify deallocation order is set correctly
        address[] memory currentOrder = concreteStandardVault.getDeallocationOrder();
        assertEq(currentOrder[0], address(strategy3));
        assertEq(currentOrder[1], address(strategy2));
        assertEq(currentOrder[2], address(strategy1));

        // Calculate withdrawal amount that will deplete strategy3 and most of strategy2
        // We need to withdraw more than one strategy's allocation to test the order
        uint256 withdrawalAmount = allocationPerStrategy + allocationPerStrategy / 2;

        // Record initial balances
        uint256 strategy1InitialBalance = strategy1.totalAllocatedValue();
        uint256 strategy2InitialBalance = strategy2.totalAllocatedValue();

        // Perform withdrawal
        vm.prank(user1);
        concreteStandardVault.withdraw(withdrawalAmount, user1, user1);

        // Verify withdrawal followed deallocation order:
        // 1. strategy3 should be completely depleted (first in order)
        // 2. strategy2 should be completely depleted (second in order)
        // 3. strategy1 should remain unchanged (third in order)

        uint256 strategy1FinalBalance = strategy1.totalAllocatedValue();
        uint256 strategy2FinalBalance = strategy2.totalAllocatedValue();
        uint256 strategy3FinalBalance = strategy3.totalAllocatedValue();

        // Strategy3 should be depleted (first in deallocation order)
        assertEq(strategy3FinalBalance, 0, "Strategy3 should be depleted first");

        // Strategy2 should be partially depleted (second in deallocation order)
        // It should have less than its initial balance since it was used after strategy3
        assertTrue(strategy2FinalBalance < strategy2InitialBalance, "Strategy2 should be partially depleted");
        assertTrue(strategy2FinalBalance > 0, "Strategy2 should not be completely depleted");

        // Strategy1 should remain unchanged (third in deallocation order)
        assertEq(strategy1FinalBalance, strategy1InitialBalance, "Strategy1 should remain unchanged");
    }

    function testCannotAddNonExistentStrategyToDeallocationOrder() public {
        // Try to add a strategy that doesn't exist in the vault
        address nonExistentStrategy = makeAddr("nonExistentStrategy");

        address[] memory invalidOrder = new address[](1);
        invalidOrder[0] = nonExistentStrategy;

        vm.prank(allocator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyDoesNotExist.selector);
        concreteStandardVault.setDeallocationOrder(invalidOrder);
    }

    function testCannotAddZeroAddressToDeallocationOrder() public {
        // Try to add zero address to deallocation order
        address[] memory invalidOrder = new address[](1);
        invalidOrder[0] = address(0);

        vm.prank(allocator);
        vm.expectRevert(); // Zero address will cause a revert, but we don't have a specific error for it
        concreteStandardVault.setDeallocationOrder(invalidOrder);
    }

    function testCannotRemoveStrategyInDeallocationOrder() public {
        // Try to remove a strategy that is in the deallocation order
        vm.prank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyHasAllocation.selector);
        concreteStandardVault.removeStrategy(address(strategy1));
    }

    function testCanRemoveStrategyAfterRemovingFromDeallocationOrder() public {
        // First, remove strategy1 from deallocation order
        address[] memory newOrder = new address[](2);
        newOrder[0] = address(strategy2);
        newOrder[1] = address(strategy3);

        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(newOrder);

        // Now remove strategy1 from deallocation order completely
        address[] memory emptyOrder = new address[](0);
        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(emptyOrder);

        // Now we should be able to remove strategy1
        vm.prank(strategyOperator);
        concreteStandardVault.removeStrategy(address(strategy1));

        // Verify strategy1 was removed
        address[] memory strategies = concreteStandardVault.getStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            assertTrue(strategies[i] != address(strategy1), "Strategy1 should be removed");
        }
    }

    function testHaltedStrategyWithAllocationRemovedViaLossRealizationCleansOrder() public {
        // Allocate some funds to strategy1 while it is Active (allocate skips Halted strategies)
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(strategy1), STRATEGY_ALLOCATION);

        // Halt strategy1
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(strategy1));

        // Verify strategy1 is halted
        IConcreteStandardVaultImpl.StrategyData memory strategyData =
            concreteStandardVault.getStrategyData(address(strategy1));
        assertEq(uint256(strategyData.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Halted));

        // A Halted strategy that still holds an allocation cannot be removed directly; it must be
        // reconciled first. Realizing the loss removes it and cleans the deallocation order too.
        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(strategy1), address(0));

        // Verify strategy1 was removed
        address[] memory strategies = concreteStandardVault.getStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            assertTrue(strategies[i] != address(strategy1), "Strategy1 should be removed");
        }
    }

    /// @dev Verifies that removeStrategy removes ALL instances of a duplicated strategy from deallocation order
    ///      while preserving relative order. E.g. [A,B,C,D,A,J] → [B,C,D,J] when removing A.
    function testRemoveStrategyWithDuplicatesInDeallocationOrderPreservesOrder() public {
        // Set deallocation order with strategy1 duplicated: [strategy1, strategy2, strategy3, strategy1]
        address[] memory orderWithDuplicates = new address[](4);
        orderWithDuplicates[0] = address(strategy1);
        orderWithDuplicates[1] = address(strategy2);
        orderWithDuplicates[2] = address(strategy3);
        orderWithDuplicates[3] = address(strategy1);

        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(orderWithDuplicates);

        // Verify initial order
        address[] memory initialOrder = concreteStandardVault.getDeallocationOrder();
        assertEq(initialOrder.length, 4);
        assertEq(initialOrder[0], address(strategy1));
        assertEq(initialOrder[1], address(strategy2));
        assertEq(initialOrder[2], address(strategy3));
        assertEq(initialOrder[3], address(strategy1));

        // Allocate to strategy1 while Active, then halt it; a Halted strategy with allocation is
        // reconciled and removed via reconcileHaltedStrategy (which also cleans the order).
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(strategy1), STRATEGY_ALLOCATION);

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(strategy1));

        // Remove strategy1 - should remove BOTH instances
        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(strategy1), address(0));

        // Verify all instances removed and order preserved: [strategy2, strategy3]
        address[] memory deallocationOrder = concreteStandardVault.getDeallocationOrder();
        assertEq(deallocationOrder.length, 2, "Should have 2 strategies after removing duplicated strategy1");
        assertEq(deallocationOrder[0], address(strategy2), "First should be strategy2");
        assertEq(deallocationOrder[1], address(strategy3), "Second should be strategy3");

        // Double-check no strategy1 remains
        for (uint256 i = 0; i < deallocationOrder.length; i++) {
            assertTrue(
                deallocationOrder[i] != address(strategy1), "Deallocation order must not contain removed strategy"
            );
        }
    }

    /// @dev Verifies invariant: deallocationOrder ⊆ strategies after strategy removal
    function testDeallocationOrderInvariantAfterStrategyRemoval() public {
        // Set deallocation order [strategy1, strategy2, strategy3]
        address[] memory order = new address[](3);
        order[0] = address(strategy1);
        order[1] = address(strategy2);
        order[2] = address(strategy3);

        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(order);

        // Allocate to strategy1 while Active, then halt and remove it (middle of order) via loss
        // realization, since a Halted strategy with allocation can no longer be removed directly.
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _allocateToStrategy(address(strategy1), STRATEGY_ALLOCATION);

        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(strategy1));

        vm.prank(strategyOperator);
        concreteStandardVault.reconcileHaltedStrategy(address(strategy1), address(0));

        // Invariant: deallocation order must not contain removed strategy
        address[] memory deallocationOrder = concreteStandardVault.getDeallocationOrder();
        for (uint256 i = 0; i < deallocationOrder.length; i++) {
            assertTrue(
                deallocationOrder[i] != address(strategy1), "Deallocation order must not contain removed strategy"
            );
        }

        // Order of remaining strategies must be preserved: [strategy2, strategy3]
        assertEq(deallocationOrder.length, 2, "Deallocation order should have 2 strategies");
        assertEq(deallocationOrder[0], address(strategy2), "First in order should be strategy2");
        assertEq(deallocationOrder[1], address(strategy3), "Second in order should be strategy3");
    }

    function testCannotAddHaltedStrategyToDeallocationOrder() public {
        // First, halt strategy1
        vm.prank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(strategy1));

        // Verify strategy1 is halted
        IConcreteStandardVaultImpl.StrategyData memory strategyData =
            concreteStandardVault.getStrategyData(address(strategy1));
        assertEq(uint256(strategyData.status), uint256(IConcreteStandardVaultImpl.StrategyStatus.Halted));

        // Try to add the halted strategy to deallocation order
        address[] memory invalidOrder = new address[](1);
        invalidOrder[0] = address(strategy1);

        vm.prank(allocator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyIsHalted.selector);
        concreteStandardVault.setDeallocationOrder(invalidOrder);
    }

    // Helper functions

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

    function testMaxWithdrawFollowDeallocationOrder() public {
        // Setup: Users deposit and allocate to all strategies
        _depositAsUser(user1, INITIAL_DEPOSIT);
        _depositAsUser(user2, INITIAL_DEPOSIT);

        // Allocate to all strategies (allocate all available funds)
        uint256 totalDeposited = INITIAL_DEPOSIT * 2; // From both users
        uint256 allocationPerStrategy = totalDeposited / 3; // Equal allocation to each strategy
        _allocateToStrategy(address(strategy1), allocationPerStrategy);
        _allocateToStrategy(address(strategy2), allocationPerStrategy);
        _allocateToStrategy(address(strategy3), allocationPerStrategy);

        // Set deallocation order to be reversed (3, 2, 1)
        address[] memory reversedOrder = new address[](1);
        reversedOrder[0] = address(strategy3);

        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(reversedOrder);

        // Verify deallocation order is set correctly
        address[] memory currentOrder = concreteStandardVault.getDeallocationOrder();
        assertEq(currentOrder[0], address(strategy3));

        uint256 maxWithdrawable = concreteStandardVault.maxWithdraw(user1);
        // Perform withdrawal
        vm.prank(user1);
        concreteStandardVault.withdraw(maxWithdrawable, user1, user1);
    }
}
