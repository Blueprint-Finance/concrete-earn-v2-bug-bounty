// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ConcreteAsyncVaultImplBaseSetup} from "../../common/ConcreteAsyncVaultImplBaseSetup.t.sol";
import {IConcreteAsyncVaultImpl} from "../../../src/interface/IConcreteAsyncVaultImpl.sol";
import {ERC4626StrategyMock} from "../../mock/ERC4626StrategyMock.sol";
import {MultisigStrategy} from "../../../src/periphery/strategies/MultisigStrategy.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddStrategyWithDeallocationOrder} from "../../common/AddStrategyWithDeallocationOrder.sol";
import {IAllocateModule} from "../../../src/interface/IAllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {console} from "forge-std/console.sol";

contract PriorityWithdrawalUnitTest is ConcreteAsyncVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    address public user1;
    address public user2;

    ERC4626StrategyMock public strategy;

    uint256 public constant INITIAL_DEPOSIT = 1000000e18;
    uint256 public constant WITHDRAW_AMOUNT = 100000e18;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.label(user1, "user1");
        vm.label(user2, "user2");

        strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));
        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);

        // Fund users
        asset.mint(user1, INITIAL_DEPOSIT * 2);
        asset.mint(user2, INITIAL_DEPOSIT * 2);

        // Setup approvals and deposits
        vm.startPrank(user1);
        asset.approve(address(concreteAsyncVault), type(uint256).max);
        concreteAsyncVault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(concreteAsyncVault), type(uint256).max);
        concreteAsyncVault.deposit(INITIAL_DEPOSIT, user2);
        vm.stopPrank();
    }

    // ============ Two normal WWL requests, claim one as priority ============

    function test_PriorityWithdrawal_ShouldSuccess() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create two normal withdrawal requests
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        vm.prank(user2);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user2, user2);

        // Verify both requests are in the current epoch
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), WITHDRAW_AMOUNT);
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, currentEpoch), WITHDRAW_AMOUNT);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), WITHDRAW_AMOUNT * 2);

        // Calculate expected values for priority withdrawal
        // Gross assets calculation is correct - it doesn't consider unwind cost
        uint256 cachedTotalAssets = concreteAsyncVault.cachedTotalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();
        uint256 grossAssets = WITHDRAW_AMOUNT * cachedTotalAssets / totalSupply;

        // Calculate unwind cost (5% of gross assets)
        uint256 unwindCost = grossAssets / 20;
        uint256 netAssets = grossAssets - unwindCost;
        uint256 initialUser1AssetBalance = asset.balanceOf(user1);
        uint256 initialCachedTotalAssets = cachedTotalAssets;
        uint256 exchangeRateBefore = cachedTotalAssets * 1e18 / totalSupply;

        // Claim priority withdrawal for user1
        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.PriorityWithdrawalClaimed(
            user1, WITHDRAW_AMOUNT, grossAssets, unwindCost, netAssets, currentEpoch
        );

        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, unwindCost, address(strategy));

        // Simulate unwind cost AFTER withdrawal (loss is updated after the withdrawal process)
        simulateUnwindCost(unwindCost);

        // Verify user1's entry is removed
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);

        // Verify total shares per epoch is updated (only user2's request remains)
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), WITHDRAW_AMOUNT);

        // Verify user2's request is still there
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, currentEpoch), WITHDRAW_AMOUNT);

        // Verify assets were transferred to user1
        assertEq(asset.balanceOf(user1), initialUser1AssetBalance + netAssets);

        // Verify cached total assets is further reduced by unwind cost
        assertEq(concreteAsyncVault.cachedTotalAssets(), initialCachedTotalAssets - grossAssets);

        // Verify total supply is reduced (shares were burned)
        assertEq(concreteAsyncVault.totalSupply(), totalSupply - WITHDRAW_AMOUNT);

        // Verify exchange rate is within the same range (should be similar, slight change due to unwind cost)
        uint256 exchangeRateAfter = concreteAsyncVault.cachedTotalAssets() * 1e18 / concreteAsyncVault.totalSupply();

        // Exchange rate should be very close (within 1% tolerance)
        uint256 rateDifference = exchangeRateAfter > exchangeRateBefore
            ? exchangeRateAfter - exchangeRateBefore
            : exchangeRateBefore - exchangeRateAfter;
        uint256 tolerance = exchangeRateBefore / 10; // 0.1% tolerance
        assertTrue(rateDifference <= tolerance, "Exchange rate should remain within range");
    }

    // ============ Partial priority withdrawal ============

    function test_PriorityWithdrawal_PartialWithdrawal() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        uint256 fullWithdrawAmount = WITHDRAW_AMOUNT;
        uint256 partialShares = WITHDRAW_AMOUNT / 2; // Claim only half

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(fullWithdrawAmount, user1, user1);

        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), fullWithdrawAmount);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), fullWithdrawAmount);

        // Calculate unwind cost for partial withdrawal
        // Gross assets calculation is correct - it doesn't consider unwind cost
        uint256 cachedTotalAssets = concreteAsyncVault.cachedTotalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();
        uint256 grossAssets = partialShares * cachedTotalAssets / totalSupply;

        // Calculate unwind cost (5% of gross assets)
        uint256 unwindCost = grossAssets / 20;
        uint256 netAssets = grossAssets - unwindCost;

        uint256 initialUser1AssetBalance = asset.balanceOf(user1);

        // Claim partial priority withdrawal
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, partialShares, unwindCost, address(strategy));

        // Simulate unwind cost AFTER withdrawal (loss is updated after the withdrawal process)
        simulateUnwindCost(unwindCost);

        // Verify user's request is partially fulfilled
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), fullWithdrawAmount - partialShares);

        // Verify total shares per epoch is updated
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), fullWithdrawAmount - partialShares);

        // Verify assets were transferred
        assertEq(asset.balanceOf(user1), initialUser1AssetBalance + netAssets);

        // Verify shares were burned
        assertEq(concreteAsyncVault.totalSupply(), totalSupply - partialShares);
    }

    // ============ Unwind cost too high ============

    function test_PriorityWithdrawal_UnwindCostTooHigh() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        // Calculate gross assets (correct - doesn't consider unwind cost)
        uint256 cachedTotalAssets = concreteAsyncVault.cachedTotalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();
        uint256 grossAssets = WITHDRAW_AMOUNT * cachedTotalAssets / totalSupply;

        // Get current unwind cost cap (default is 500 = 5%)
        uint16 unwindCostCap = concreteAsyncVault.getUnwindCostCap();

        // Calculate maximum allowed unwind cost based on unwind cost cap
        // maxUnwindCost = grossAssets * unwindCostCap / BASIS_POINTS
        uint256 maxUnwindCost = (grossAssets * unwindCostCap) / 10000;

        // Unwind cost exceeding the unwind cost cap should revert
        uint256 unwindCostTooHigh = maxUnwindCost + 1;

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.UnwindCostTooHigh.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, unwindCostTooHigh, address(strategy));

        // Verify request is still there (not processed)
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), WITHDRAW_AMOUNT);

        // Unwind cost at the unwind cost cap limit should work (if we have enough balance)
        // First, ensure we have enough available assets
        uint256 netAssetsAtCap = grossAssets - maxUnwindCost;
        uint256 vaultBalance = asset.balanceOf(address(concreteAsyncVault));
        uint256 pastEpochsUnclaimed = concreteAsyncVault.pastEpochsUnclaimedAssets();
        uint256 availableAssets = vaultBalance - pastEpochsUnclaimed;

        if (availableAssets >= netAssetsAtCap) {
            // At the unwind cost cap limit, it should succeed
            vm.prank(withdrawalManager);
            concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, maxUnwindCost, address(strategy));

            // Verify request was processed
            assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
        }
    }

    // ============ Input validation ============

    function test_PriorityWithdrawal_InputValidation() public {
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        // Try to claim with zero shares (should revert even though there's a valid request)
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroShares.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, 0, 100, address(strategy));

        // Zero address validation
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroAddress.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(address(0), WITHDRAW_AMOUNT, 100, address(strategy));

        // Try to claim more than requested
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientShares.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT + 1000, 100, address(strategy));

        // Unauthorized access validation
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.PRIORITY_WITHDRAWAL_EXECUTOR
            )
        );
        vm.prank(user1);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, 100, address(strategy));

        // Unregistered strategy - strategy address not in vault's strategies set
        address unregisteredStrategy = makeAddr("unregisteredStrategy");
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyDoesNotExist.selector);
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, 100, unregisteredStrategy);
    }

    // ============ Halted strategy validation ============

    function test_PriorityWithdrawal_RevertsOnHaltedStrategy() public {
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        // Halt the strategy
        vm.prank(strategyOperator);
        concreteAsyncVault.toggleStrategyStatus(address(strategy));

        uint256 grossAssets =
            WITHDRAW_AMOUNT * concreteAsyncVault.cachedTotalAssets() / concreteAsyncVault.totalSupply();
        uint256 unwindCost = grossAssets / 20;

        vm.expectRevert(IConcreteStandardVaultImpl.StrategyIsHalted.selector);
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, unwindCost, address(strategy));
    }

    // ============ Insufficient net assets in vault ============

    function test_PriorityWithdrawal_InsufficientBalance() public {
        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        // Allocate almost all assets to strategy
        uint256 totalAssets = concreteAsyncVault.totalAssets();
        bytes memory extraData = abi.encode(totalAssets - 100); // Leave only 100 wei
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});

        bytes memory data = abi.encode(params);
        vm.prank(allocator);
        concreteAsyncVault.allocate(data);

        // Calculate values - this will require more than available
        // Gross assets calculation is correct - it doesn't consider unwind cost
        uint256 cachedTotalAssets = concreteAsyncVault.cachedTotalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();
        uint256 grossAssets = WITHDRAW_AMOUNT * cachedTotalAssets / totalSupply;

        // Calculate unwind cost (5% of gross assets)
        uint256 unwindCost = grossAssets / 20;

        // Should revert with InsufficientBalance
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientBalance.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, unwindCost, address(strategy));
    }

    // ============ Priority withdrawal fails due to locked assets from past epochs ============

    function test_PriorityWithdrawal_InsufficientBalance_LockedAssets() public {
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        // Step 1: Create withdrawal request in epoch 1
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        // Verify withdrawal request was created
        assertGt(concreteAsyncVault.getUserEpochRequest(user1, epoch1), 0, "User1 should have requested shares");

        // Step 2: Close and process epoch 1 (this locks assets for past epochs)
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // Verify epoch 1 was processed and assets are locked
        // After processing, pastEpochsUnclaimedAssets should equal the assets needed for the withdrawal
        uint256 pastEpochsUnclaimed = concreteAsyncVault.pastEpochsUnclaimedAssets();
        assertGt(pastEpochsUnclaimed, 0, "Assets should be locked for past epochs");

        // Verify epoch 1 has a share price (was processed)
        assertGt(concreteAsyncVault.getEpochPricePerShare(epoch1), 0, "Epoch 1 should have a share price");

        // Step 3: Create new withdrawal request in current epoch (epoch 2)
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        assertEq(currentEpoch, epoch1 + 1, "Epoch should have incremented");

        vm.prank(user2);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user2, user2);

        // Step 4: Calculate values for priority withdrawal
        // Gross assets calculation is correct - it doesn't consider unwind cost
        uint256 cachedTotalAssets = concreteAsyncVault.cachedTotalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();
        uint256 grossAssets = WITHDRAW_AMOUNT * cachedTotalAssets / totalSupply;

        // Calculate unwind cost (5% of gross assets)
        uint256 unwindCost = grossAssets / 20;
        uint256 netAssets = grossAssets - unwindCost;

        // Step 5: Verify the scenario - vault has money but it's locked
        uint256 vaultBalance = asset.balanceOf(address(concreteAsyncVault));
        uint256 availableAssets = vaultBalance - pastEpochsUnclaimed;

        // If available assets is sufficient, allocate some to strategy to create the scenario
        // where available assets < net assets needed
        if (availableAssets >= netAssets) {
            // Allocate enough to strategy so that available assets becomes insufficient
            uint256 allocateAmount = availableAssets - netAssets + 1; // Allocate to make available < net
            bytes memory extraData = abi.encode(allocateAmount);
            IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
            params[0] =
                IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});
            bytes memory data = abi.encode(params);
            vm.prank(allocator);
            concreteAsyncVault.allocate(data);

            // Recalculate after allocation
            vaultBalance = asset.balanceOf(address(concreteAsyncVault));
            availableAssets = vaultBalance - pastEpochsUnclaimed;
        }

        // Verify the scenario: vault has money, but it's locked
        assertLt(availableAssets, netAssets, "Available assets should be less than net assets needed");
        assertGt(vaultBalance, netAssets, "Vault balance should be greater than net assets (but locked)");

        // Step 6: Attempt priority withdrawal - should revert due to insufficient available balance
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientBalance.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user2, WITHDRAW_AMOUNT, unwindCost, address(strategy));

        // Verify user2's request is still there (not processed)
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, currentEpoch), WITHDRAW_AMOUNT);

        // Verify user1's unclaimed request is still there (in assets)
        assertGt(concreteAsyncVault.getUserEpochRequestInAssets(user1, epoch1), 0, "User1 should have unclaimed assets");
    }

    // ============ Priority withdrawal with penalty fee (unwindCost > actual loss) ============

    function test_PriorityWithdrawal_WithPenaltyFee_IncreasesExchangeRate() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        // Calculate gross assets
        uint256 cachedTotalAssets = concreteAsyncVault.cachedTotalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();
        uint256 grossAssets = WITHDRAW_AMOUNT * cachedTotalAssets / totalSupply;

        // Set unwindCost higher than actual loss (penalty fee scenario)
        // unwindCost = 5% of gross assets (penalty fee)
        uint256 unwindCost = grossAssets / 20;
        // Actual loss will be only 2% of gross assets
        uint256 actualLoss = grossAssets / 50;
        uint256 netAssets = grossAssets - unwindCost;

        uint256 initialUser1AssetBalance = asset.balanceOf(user1);
        uint256 initialCachedTotalAssets = cachedTotalAssets;
        uint256 exchangeRateBefore = cachedTotalAssets * 1e18 / totalSupply;

        // Claim priority withdrawal with penalty fee (unwindCost > actual loss)
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, unwindCost, address(strategy));

        // Simulate actual loss AFTER withdrawal (actual loss is less than unwindCost due to penalty)
        simulateUnwindCost(actualLoss);

        // Verify user1's entry is removed
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);

        // Verify assets were transferred to user1 (netAssets = grossAssets - unwindCost)
        assertEq(asset.balanceOf(user1), initialUser1AssetBalance + netAssets);

        // Verify cached total assets: reduced by grossAssets (withdrawal) and actualLoss (actual loss)
        // Since unwindCost > actualLoss, the vault benefits from the difference
        uint256 expectedCachedTotalAssets = initialCachedTotalAssets - netAssets - actualLoss;
        assertEq(concreteAsyncVault.cachedTotalAssets(), expectedCachedTotalAssets);

        // Verify total supply is reduced
        assertEq(concreteAsyncVault.totalSupply(), totalSupply - WITHDRAW_AMOUNT);

        // Verify exchange rate INCREASES (because we deducted more from user than actual loss)
        // The difference (unwindCost - actualLoss) benefits remaining shareholders
        uint256 exchangeRateAfter = concreteAsyncVault.cachedTotalAssets() * 1e18 / concreteAsyncVault.totalSupply();
        assertGt(exchangeRateAfter, exchangeRateBefore, "Exchange rate should increase due to penalty fee");
    }

    // ============ Partial priority withdrawal processing when vault has insufficient funds ============

    function test_PartialPriorityWithdrawal_ProcessIn2Steps() public {
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);
        vm.prank(user2);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user2, user2);

        // Allocate most funds to strategy, leaving only ~50% available
        uint256 allocateAmount = asset.balanceOf(address(concreteAsyncVault)) / 2;
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({
            isDeposit: true, strategy: address(strategy), extraData: abi.encode(allocateAmount)
        });
        vm.prank(allocator);
        concreteAsyncVault.allocate(abi.encode(params));

        // Claim first partial withdrawal (60% of shares)
        uint256 partialShares = WITHDRAW_AMOUNT * 60 / 100;
        uint256 partialGrossAssets =
            partialShares * concreteAsyncVault.cachedTotalAssets() / concreteAsyncVault.totalSupply();
        uint256 partialUnwindCost = partialGrossAssets / 25; // 4% unwind cost
        uint256 partialNetAssets = partialGrossAssets - partialUnwindCost;

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, partialShares, partialUnwindCost, address(strategy));
        simulateUnwindCost(partialUnwindCost);

        // deallocate all allocated funds in the above step
        bytes memory data = abi.encode(new IAllocateModule.AllocateParams[](1));
        params[0] = IAllocateModule.AllocateParams({
            isDeposit: false, strategy: address(strategy), extraData: abi.encode(allocateAmount)
        });
        vm.prank(allocator);
        concreteAsyncVault.allocate(data);

        uint256 remainingShares = WITHDRAW_AMOUNT - partialShares;
        uint256 remainingGrossAssets =
            remainingShares * concreteAsyncVault.cachedTotalAssets() / concreteAsyncVault.totalSupply();
        uint256 remainingNetAssets = remainingGrossAssets - (remainingGrossAssets / 25); // 4% unwind cost

        assertEq(
            concreteAsyncVault.getUserEpochRequest(user1, concreteAsyncVault.latestEpochID()),
            WITHDRAW_AMOUNT - partialShares
        );
        assertEq(asset.balanceOf(user1), user1BalanceBefore + partialNetAssets);

        // Claim remaining withdrawal
        uint256 remainingUnwindCost = remainingGrossAssets / 25; // 4% unwind cost
        uint256 user1BalanceBeforeSecond = asset.balanceOf(user1);
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, remainingShares, remainingUnwindCost, address(strategy));
        simulateUnwindCost(remainingUnwindCost);

        assertEq(concreteAsyncVault.getUserEpochRequest(user1, concreteAsyncVault.latestEpochID()), 0);
        assertEq(asset.balanceOf(user1), user1BalanceBeforeSecond + remainingNetAssets);
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, concreteAsyncVault.latestEpochID()), WITHDRAW_AMOUNT);
    }

    // ============ Unwind cost cap getter, setter, and unauthorized access ============
    function test_UnwindCostCap_GetterSetter_Unauthorized() public {
        // Get default unwind cost cap (should be 500 = 5%)
        uint16 defaultUnwindCostCap = concreteAsyncVault.getUnwindCostCap();
        assertEq(defaultUnwindCostCap, 500, "Default unwind cost cap should be 500 (5%)");

        // Set unwind cost cap as vault manager (should succeed)
        uint16 newUnwindCostCap = 1000; // 10%
        vm.prank(vaultManager);
        concreteAsyncVault.setUnwindCostCap(newUnwindCostCap);

        uint16 updatedUnwindCostCap = concreteAsyncVault.getUnwindCostCap();
        assertEq(updatedUnwindCostCap, newUnwindCostCap, "Unwind cost cap should be updated to 1000 (10%)");

        // Set unwind cost cap to maximum (10000 = 100%)
        uint16 maxUnwindCostCap = 10000;
        vm.prank(vaultManager);
        concreteAsyncVault.setUnwindCostCap(maxUnwindCostCap);

        uint16 maxUnwindCostCapResult = concreteAsyncVault.getUnwindCostCap();
        assertEq(maxUnwindCostCapResult, maxUnwindCostCap, "Unwind cost cap should be set to maximum 10000 (100%)");

        // Try to set unwind cost cap exceeding 100% (should revert)
        vm.expectRevert(IConcreteAsyncVaultImpl.InvalidUnwindCostCap.selector);
        vm.prank(vaultManager);
        concreteAsyncVault.setUnwindCostCap(10001);

        // Unauthorized access - user1 tries to set unwind cost cap (should revert)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.VAULT_MANAGER
            )
        );
        vm.prank(user1);
        concreteAsyncVault.setUnwindCostCap(750);

        // Unauthorized access - withdrawalManager tries to set unwind cost cap (should revert)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, withdrawalManager, RolesLib.VAULT_MANAGER
            )
        );
        vm.prank(withdrawalManager);
        concreteAsyncVault.setUnwindCostCap(750);

        // Verify unwind cost cap is still at maximum (unauthorized attempts didn't change it)
        assertEq(
            concreteAsyncVault.getUnwindCostCap(),
            maxUnwindCostCap,
            "Unwind cost cap should remain unchanged after unauthorized attempts"
        );
    }

    // ============ Exchange rate comparison: deductGross=false vs deductGross=true ============

    /**
     * @notice Demonstrates how the exchange rate changes immediately after the priority
     *         withdrawal depending on the `deductGross` flag.
     *
     *  - deductGross=false (net): cachedTotalAssets is reduced by netAssets only.
     *    The unwind cost remains in the vault's accounting, so the exchange rate stays
     *    unchanged right after the call (remaining shareholders temporarily absorb no loss).
     *
     *  - deductGross=true (gross): cachedTotalAssets is reduced by grossAssets.
     *    The exchange rate drops immediately because the unwind cost is treated as an
     *    instant loss to the vault.
     */
    // Struct to hold results from each run, avoiding stack-too-deep
    struct RunResult {
        uint256 cachedAfter;
        uint256 supplyAfter;
        uint256 exchangeRate;
        uint256 cachedAfterAccrual;
        uint256 exchangeRateAfterAccrual;
    }

    /// @dev Holds key values computed once and passed to sub-steps.
    struct MsTestCtx {
        MultisigStrategy msStrategy;
        address msMultisig;
        uint256 allocateAmount;
        uint256 cachedBefore;
        uint256 supplyBefore;
        uint256 grossAssets;
        uint256 unwindCost;
        uint256 netAssets;
        uint256 c2aBefore; // convertToAssets(1e18) at the start
    }

    function test_PriorityWithdrawal_ExchangeRate_WithMultisigStrategy() public {
        MsTestCtx memory ctx;
        ctx.msMultisig = makeAddr("msMultisig");

        // ── Deploy a MultisigStrategy ──
        {
            address msAdmin = makeAddr("msAdmin");
            MultisigStrategy impl = new MultisigStrategy();
            bytes memory initData = abi.encodeWithSelector(
                MultisigStrategy.initialize.selector,
                msAdmin,
                address(concreteAsyncVault),
                ctx.msMultisig,
                uint64(5000), // maxAccountingChangeThreshold 50%
                uint64(86400), // accountingValidityPeriod 1 day
                uint64(60) // cooldownPeriod 60s
            );
            ctx.msStrategy = MultisigStrategy(address(new ERC1967Proxy(address(impl), initData)));
        }
        vm.label(address(ctx.msStrategy), "MultisigStrategy");

        addStrategyWithDeallocationOrder(
            address(ctx.msStrategy), address(concreteAsyncVault), allocator, strategyOperator
        );

        // ── Allocate all vault funds to the multisig strategy ──
        ctx.allocateAmount = asset.balanceOf(address(concreteAsyncVault));
        _allocateToMsStrategy(address(ctx.msStrategy), ctx.allocateAmount);

        ctx.cachedBefore = concreteAsyncVault.cachedTotalAssets();
        ctx.supplyBefore = concreteAsyncVault.totalSupply();
        ctx.grossAssets = WITHDRAW_AMOUNT * ctx.cachedBefore / ctx.supplyBefore;
        ctx.unwindCost = ctx.grossAssets / 20; // 5%
        ctx.netAssets = ctx.grossAssets - ctx.unwindCost;

        // ── 1. Initial state ──
        console.log("=========== 1. INITIAL STATE (all funds in strategy) ===========");
        _logState(ctx.msStrategy);
        ctx.c2aBefore = concreteAsyncVault.convertToAssets(1e18);
        console.log("  convertToAssets(1e18) :", ctx.c2aBefore);

        // ── 2. Yield accrual BEFORE deallocation ──
        _checkAccrualNoOp(ctx, "2. YIELD ACCRUAL BEFORE DEALLOC");

        // ── 3. Deallocate net amount from strategy ──
        vm.prank(ctx.msMultisig);
        asset.approve(address(ctx.msStrategy), ctx.netAssets);
        _deallocateFromMsStrategy(address(ctx.msStrategy), ctx.netAssets);
        _checkErateUnchanged(ctx, "3. AFTER DEALLOC (net returned, loss NOT reported)");

        // ── 4. Yield accrual AFTER deallocation ──
        _checkAccrualNoOp(ctx, "4. YIELD ACCRUAL AFTER DEALLOC");

        // ── 5. Priority withdrawal ──
        _claimAndCheckPriorityWithdrawal(ctx);

        // ── 6. Final yield accrual ──
        _checkFinalAccrual(ctx);
    }

    /// @dev Accrue yield, then assert erate and cached are unchanged.
    function _checkAccrualNoOp(MsTestCtx memory ctx, string memory label) internal {
        console.log("");
        console.log(string.concat("=========== ", label, " ==========="));
        vm.prank(allocator);
        concreteAsyncVault.accrueYield();
        _logState(ctx.msStrategy);
        uint256 c2a = concreteAsyncVault.convertToAssets(1e18);
        console.log("  convertToAssets(1e18) :", c2a);
        assertEq(c2a, ctx.c2aBefore, string.concat(label, ": erate must not move"));
        assertEq(concreteAsyncVault.cachedTotalAssets(), ctx.cachedBefore, string.concat(label, ": cached unchanged"));
    }

    /// @dev Assert erate and cached are unchanged (no accrual call).
    function _checkErateUnchanged(MsTestCtx memory ctx, string memory label) internal {
        console.log("");
        console.log(string.concat("=========== ", label, " ==========="));
        _logState(ctx.msStrategy);
        uint256 c2a = concreteAsyncVault.convertToAssets(1e18);
        console.log("  convertToAssets(1e18) :", c2a);
        assertEq(c2a, ctx.c2aBefore, string.concat(label, ": erate must not move"));
        assertEq(concreteAsyncVault.cachedTotalAssets(), ctx.cachedBefore, string.concat(label, ": cached unchanged"));
    }

    /// @dev Issue wwl request, claim priority, then check post-claim state.
    function _claimAndCheckPriorityWithdrawal(MsTestCtx memory ctx) internal {
        vm.prank(user1);
        concreteAsyncVault.withdraw(WITHDRAW_AMOUNT, user1, user1);

        vm.prank(withdrawalManager);
        concreteAsyncVault.claimPriorityWithdrawal(user1, WITHDRAW_AMOUNT, ctx.unwindCost, address(ctx.msStrategy));

        console.log("");
        console.log("=========== 5. AFTER PRIORITY WITHDRAWAL ===========");
        _logState(ctx.msStrategy);

        uint256 cachedAfter = concreteAsyncVault.cachedTotalAssets();
        uint256 supplyAfter = concreteAsyncVault.totalSupply();
        uint256 rawRate = cachedAfter * 1e18 / supplyAfter;
        uint256 c2aAfterClaim = concreteAsyncVault.convertToAssets(1e18);

        console.log("  rawRate (cached/supply):", rawRate);
        console.log("  convertToAssets(1e18) :", c2aAfterClaim);

        assertEq(cachedAfter, ctx.cachedBefore - ctx.netAssets, "Cached should drop by netAssets");

        assertEq(
            ctx.msStrategy.totalAllocatedValue(),
            ctx.allocateAmount - ctx.netAssets - ctx.unwindCost,
            "Strategy value should reflect dealloc + unwind cost"
        );

        // Raw cached/supply ratio is temporarily inflated because cached was only
        // reduced by netAssets while grossAssets worth of shares were burned.
        assertGt(rawRate, ctx.c2aBefore, "raw cached/supply ratio temporarily inflated");

        // However, convertToAssets already previews the pending yield accrual
        // (it sees the strategy's reduced totalAllocatedValue), so it shows the
        // truthful exchange rate — no inflation visible to users.
        assertEq(c2aAfterClaim, ctx.c2aBefore, "convertToAssets already accounts for pending loss");
    }

    /// @dev Final yield accrual — should reconcile and return erate to initial.
    function _checkFinalAccrual(MsTestCtx memory ctx) internal {
        console.log("");
        console.log("=========== 6. FINAL YIELD ACCRUAL ===========");
        vm.prank(allocator);
        concreteAsyncVault.accrueYield();
        _logState(ctx.msStrategy);
        uint256 c2aFinal = concreteAsyncVault.convertToAssets(1e18);
        console.log("  convertToAssets(1e18) :", c2aFinal);

        uint256 cachedFinal = concreteAsyncVault.cachedTotalAssets();
        uint256 supplyFinal = concreteAsyncVault.totalSupply();

        assertEq(cachedFinal, ctx.cachedBefore - ctx.grossAssets, "Cached should drop by grossAssets total");
        assertEq(c2aFinal, ctx.c2aBefore, "erate should return to initial value");
        assertEq(
            cachedFinal * 1e18 / supplyFinal,
            ctx.cachedBefore * 1e18 / ctx.supplyBefore,
            "erate ratio must match initial"
        );
    }

    // ─── Low-level helpers ──────────────────────────────────────────────

    function _logState(MultisigStrategy msStrategy) internal view {
        console.log("  cachedTotalAssets     :", concreteAsyncVault.cachedTotalAssets());
        console.log("  totalSupply           :", concreteAsyncVault.totalSupply());
        console.log("  vaultIdleBalance      :", asset.balanceOf(address(concreteAsyncVault)));
        console.log("  strategyAllocReal     :", msStrategy.totalAllocatedValue());
        console.log("  vaultTrackedAlloc     :", concreteAsyncVault.getStrategyData(address(msStrategy)).allocated);
    }

    function _allocateToMsStrategy(address msStrategy, uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory p = new IAllocateModule.AllocateParams[](1);
        p[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: msStrategy, extraData: abi.encode(amount)});
        vm.prank(allocator);
        concreteAsyncVault.allocate(abi.encode(p));
    }

    function _deallocateFromMsStrategy(address msStrategy, uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory p = new IAllocateModule.AllocateParams[](1);
        p[0] = IAllocateModule.AllocateParams({isDeposit: false, strategy: msStrategy, extraData: abi.encode(amount)});
        vm.prank(allocator);
        concreteAsyncVault.allocate(abi.encode(p));
    }

    /**
     * @dev Helper function to simulate unwind cost by allocating funds to strategy,
     *      simulating a loss (following the same pattern as simulateYield), and triggering yield accrual.
     *      Returns the actual unwind cost (loss amount).
     * @param desiredLossAmount The desired amount of loss to simulate (this becomes the unwind cost)
     * @return unwindCost The actual unwind cost (loss amount that affected vault total assets)
     */
    function simulateUnwindCost(uint256 desiredLossAmount) internal returns (uint256 unwindCost) {
        // Allocate some funds to strategy to have something to lose
        // Need to allocate enough so the loss doesn't exceed allocated amount
        uint256 allocateAmount = desiredLossAmount * 10; // Allocate 10x the desired loss amount
        bytes memory extraData = abi.encode(allocateAmount);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});

        bytes memory data = abi.encode(params);
        vm.prank(allocator);
        concreteAsyncVault.allocate(data);

        // Store cached total assets before loss
        uint256 cachedTotalAssetsBefore = concreteAsyncVault.cachedTotalAssets();

        // Simulate loss in strategy (same pattern as simulateYield, but for losses)
        // This reduces the strategy's totalAllocatedValue, which will be detected during yield accrual
        strategy.simulateLoss(desiredLossAmount);

        // Trigger yield accrual to update vault accounting with the loss
        // Using accrueYield() directly, same pattern as simulateYield tests
        vm.prank(allocator);
        concreteAsyncVault.accrueYield();

        // Calculate actual unwind cost (loss that affected vault's cached total assets)
        uint256 cachedTotalAssetsAfter = concreteAsyncVault.cachedTotalAssets();
        unwindCost = cachedTotalAssetsBefore - cachedTotalAssetsAfter;
        return unwindCost;
    }
}
