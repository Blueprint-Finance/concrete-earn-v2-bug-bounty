// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy,
    IConcreteAsyncVaultImpl,
    ConcreteAsyncVaultImpl,
    ConcreteAsyncVaultImplBaseSetup
} from "../../common/ConcreteAsyncVaultImplBaseSetup.t.sol";
import {ConcreteAsyncVaultImpl} from "../../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {IConcreteAsyncVaultImpl} from "../../../src/interface/IConcreteAsyncVaultImpl.sol";
import {ERC4626StrategyMock} from "../../mock/ERC4626StrategyMock.sol";
import {AddStrategyWithDeallocationOrder} from "../../common/AddStrategyWithDeallocationOrder.sol";
import {IAllocateModule} from "../../../src/interface/IAllocateModule.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";

import {console2 as console} from "forge-std/Test.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

contract QueueUnitTest is ConcreteAsyncVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    address public user1;
    address public user2;
    address public user3;
    uint256 public totalAmount = 2000000e18;
    uint256 public initialDepositAmount = 1000000e18;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        vm.label(address(user1), "user1");
        vm.label(address(user2), "user2");
        vm.label(address(user3), "user3");

        // Fund user accounts
        asset.mint(user1, totalAmount);
        asset.mint(user2, totalAmount);
        asset.mint(user3, totalAmount);

        // Setup approvals
        vm.startPrank(user1);
        asset.approve(address(concreteAsyncVault), totalAmount);
        concreteAsyncVault.deposit(initialDepositAmount, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(concreteAsyncVault), totalAmount);
        concreteAsyncVault.deposit(initialDepositAmount, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        asset.approve(address(concreteAsyncVault), totalAmount);
        concreteAsyncVault.deposit(initialDepositAmount, user3);
        vm.stopPrank();
    }

    // ============ Async Vault Specific Tests ============

    function test_Initialization() public view {
        assertEq(concreteAsyncVault.latestEpochID(), 1);
        assertTrue(concreteAsyncVault.pastEpochsUnclaimedAssets() == 0);
        assertTrue(concreteAsyncVault.totalRequestedSharesPerEpoch(1) == 0);
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, 1), 0);
        assertEq(concreteAsyncVault.getEpochPricePerShare(1), 0);
        assertTrue(concreteAsyncVault.isQueueActive() == true);
    }

    //TODO test when isActive is false
    function testWithdrawCreatesPendingRequest() public {
        uint256 withdrawAmount = 100000e18;
        uint256 initialUserBalance = concreteAsyncVault.balanceOf(user1);
        uint256 initialVaultBalance = concreteAsyncVault.balanceOf(address(concreteAsyncVault));
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // expect emit QueuedWithdrawal
        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.QueuedWithdrawal(user1, user1, user1, withdrawAmount, withdrawAmount, currentEpoch);
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Check that shares were transferred to vault
        assertEq(concreteAsyncVault.balanceOf(user1), initialUserBalance - withdrawAmount, "user1 balance");
        assertEq(
            concreteAsyncVault.balanceOf(address(concreteAsyncVault)),
            initialVaultBalance + withdrawAmount,
            "vault balance"
        );

        //Check that request was created
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), withdrawAmount);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), withdrawAmount);
    }

    function testWithdrawCreatesPendingRequestOnBehalfOf() public {
        uint256 withdrawAmount = 100000e18;
        uint256 initialUserBalance = concreteAsyncVault.balanceOf(user1);
        uint256 initialVaultBalance = concreteAsyncVault.balanceOf(address(concreteAsyncVault));
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user2, user1);

        // Check that shares were transferred to vault
        assertEq(concreteAsyncVault.balanceOf(user1), initialUserBalance - withdrawAmount, "user1 balance");
        assertEq(concreteAsyncVault.balanceOf(address(concreteAsyncVault)), initialVaultBalance + withdrawAmount);

        //Check that request was created
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, currentEpoch), withdrawAmount);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), withdrawAmount);
    }

    function testSweepDonatedTokensCannotDrainQueuedShareEscrow() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        address sweepRecipient = makeAddr("sweepRecipient");

        // A queued withdrawal escrows the user's shares into the vault (address(this)).
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);
        assertEq(concreteAsyncVault.balanceOf(address(concreteAsyncVault)), withdrawAmount, "shares escrowed");

        // Sweeping the vault share token must revert instead of draining the escrow.
        vm.prank(vaultManager);
        vm.expectRevert(IConcreteStandardVaultImpl.CannotSweepShareToken.selector);
        concreteAsyncVault.sweepDonatedTokens(address(concreteAsyncVault), sweepRecipient);

        // Escrow is intact, so the user can still cancel and recover the shares.
        assertEq(concreteAsyncVault.balanceOf(address(concreteAsyncVault)), withdrawAmount, "escrow untouched");
        assertEq(concreteAsyncVault.balanceOf(sweepRecipient), 0, "nothing swept");

        vm.prank(user1);
        concreteAsyncVault.cancelRequest(currentEpoch);
        assertEq(concreteAsyncVault.balanceOf(user1), initialDepositAmount, "shares returned on cancel");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0, "request cleared");
    }

    function testCancelRequestPlain() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Cancel request
        vm.prank(user1);
        concreteAsyncVault.cancelRequest(currentEpoch);

        // Check that shares were returned
        assertEq(concreteAsyncVault.balanceOf(user1), 1000000e18); // Original balance
        assertEq(concreteAsyncVault.balanceOf(address(concreteAsyncVault)), 0);

        // Check that request was cleared
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), 0);
    }

    function testCancellationEnabledDefaultsTrue() public view {
        assertTrue(concreteAsyncVault.cancellationEnabled());
    }

    function testConfigureDisablesCancellation() public {
        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.CancellationEnabledSet(false);
        vm.prank(vaultManager);
        concreteAsyncVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.CancellationEnabled, abi.encode(false)
        );

        assertFalse(concreteAsyncVault.cancellationEnabled());
    }

    function testCancelRequestRevertsWhenCancellationDisabled() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create a pending request while cancellation is still enabled.
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Disable cancellation.
        vm.prank(vaultManager);
        concreteAsyncVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.CancellationEnabled, abi.encode(false)
        );

        // Cancelling is now blocked.
        vm.expectRevert(IConcreteAsyncVaultImpl.CancellationDisabled.selector);
        vm.prank(user1);
        concreteAsyncVault.cancelRequest(currentEpoch);
    }

    function testConfigureReenablesCancellation() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        vm.startPrank(vaultManager);
        concreteAsyncVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.CancellationEnabled, abi.encode(false)
        );
        concreteAsyncVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.CancellationEnabled, abi.encode(true)
        );
        vm.stopPrank();
        assertTrue(concreteAsyncVault.cancellationEnabled());

        // Re-enabled: cancel works again.
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);
        vm.prank(user1);
        concreteAsyncVault.cancelRequest(currentEpoch);
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
    }

    function testCancelRequestEpochAlreadyClosed() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Process epoch
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // Try to cancel processed epoch
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.EpochAlreadyClosed.selector, currentEpoch));
        vm.prank(user1);
        concreteAsyncVault.cancelRequest(currentEpoch);
    }

    function testCancelRequestNoRequestingShares() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.NoRequestingShares.selector));
        vm.prank(user1);
        concreteAsyncVault.cancelRequest(currentEpoch);
    }

    function testCancelRequestOnBehalfOf() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.RequestCancelled(user1, withdrawAmount, currentEpoch);
        // Cancel request
        vm.prank(withdrawalManager);
        concreteAsyncVault.cancelRequest(user1, currentEpoch);

        // Check that shares were returned
        assertEq(concreteAsyncVault.balanceOf(user1), 1000000e18); // Original balance
        assertEq(concreteAsyncVault.balanceOf(address(concreteAsyncVault)), 0);

        // Check that request was cleared
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), 0);
    }

    function testProcessEpoch() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        uint256 totalAssets = concreteAsyncVault.totalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();

        // Process epoch

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.EpochProcessed(
            currentEpoch, withdrawAmount, withdrawAmount, (totalAssets / totalSupply) * 10 ** 18
        );
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // Check that epoch was processed
        assertEq(concreteAsyncVault.latestEpochID(), currentEpoch + 1);

        assertEq(
            concreteAsyncVault.getEpochPricePerShare(currentEpoch),
            (totalAssets / totalSupply) * 10 ** 18,
            "epoch price"
        );
        assertEq(
            concreteAsyncVault.pastEpochsUnclaimedAssets(),
            totalAssets - concreteAsyncVault.totalAssets(),
            "redeemable assets"
        );

        //share total assets ratio should stay the same
        assertEq(concreteAsyncVault.totalAssets() / concreteAsyncVault.totalSupply(), totalAssets / totalSupply);
    }

    function testProcessEpochFundsAllocated() public {
        ERC4626StrategyMock strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));

        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);

        uint256 withdrawAmount = 100000e18;

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        uint256 amount = concreteAsyncVault.totalAssets();
        uint256 amount2 = concreteAsyncVault.cachedTotalAssets();
        assertEq(amount, 3000000e18);
        assertEq(amount2, 3000000e18);

        bytes memory extraData = abi.encode(amount);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});

        bytes memory data = abi.encode(params);
        vm.prank(allocator);
        concreteAsyncVault.allocate(data);

        // Process epoch
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientBalance.selector));
        concreteAsyncVault.processEpoch();
        vm.stopPrank();
    }

    function testProcessEpochNoRequestingShares() public {
        vm.startPrank(withdrawalManager);
        // expect emit  emit IConcreteAsyncVaultImpl.EpochProcessed(previousEpochID, requestingShares, assetsNeeded, sharePrice);

        concreteAsyncVault.closeEpoch();
        vm.expectEmit(true, true, true, true, address(concreteAsyncVault));
        uint256 sharePriceNotSet = concreteAsyncVault.getEpochPricePerShare(1);
        uint256 expectedSharePrice = concreteAsyncVault.convertToAssets(10 ** concreteAsyncVault.decimals());
        emit IConcreteAsyncVaultImpl.EpochProcessed(1, 0, 0, expectedSharePrice);
        concreteAsyncVault.processEpoch();
        uint256 sharePriceSet = concreteAsyncVault.getEpochPricePerShare(1);
        vm.stopPrank();
        assertEq(sharePriceNotSet, 0);
        assertEq(sharePriceSet, expectedSharePrice);
    }

    function testProcessEpochUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.WITHDRAWAL_MANAGER
            )
        );
        concreteAsyncVault.processEpoch();
    }

    //This test case was fixed by adding a require check in the allocate function to ensure that the vault has enough balance to process the epoch.
    function testProcessEpochInsufficientBalance() public {
        ERC4626StrategyMock strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));

        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);

        uint256 withdrawAmount = 100000e18;

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        uint256 amount = concreteAsyncVault.totalAssets();
        uint256 amount2 = concreteAsyncVault.cachedTotalAssets();
        assertEq(amount, 3000000e18);
        assertEq(amount2, 3000000e18);

        // Process epoch
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        bytes memory extraData = abi.encode(amount);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});

        bytes memory data = abi.encode(params);
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientBalance.selector));
        vm.prank(allocator);
        concreteAsyncVault.allocate(data);
    }

    function testCloseEpochPreviousEpochNotProcessed() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        uint256 totalAssets = concreteAsyncVault.totalAssets();
        uint256 totalSupply = concreteAsyncVault.totalSupply();

        // Process epoch

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(
            abi.encodeWithSelector(IConcreteAsyncVaultImpl.PreviousEpochNotProcessed.selector, currentEpoch)
        );
        concreteAsyncVault.closeEpoch();
    }

    function testClaimWithdrawal() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Process epoch
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // Claim redemption
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = currentEpoch;

        uint256 initialAssetBalance = asset.balanceOf(user1);
        uint256 initialRedeemableAssets = concreteAsyncVault.pastEpochsUnclaimedAssets();

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.RequestClaimed(user1, withdrawAmount, epochIDs);
        vm.prank(user1);
        concreteAsyncVault.claimWithdrawal(epochIDs);

        // Check that assets were received
        uint256 finalAssetBalance = asset.balanceOf(user1);
        uint256 assetsReceived = finalAssetBalance - initialAssetBalance;
        assertGt(assetsReceived, 0);

        // Check that redeemable assets were reduced
        assertLt(concreteAsyncVault.pastEpochsUnclaimedAssets(), initialRedeemableAssets);

        // Check that request was cleared
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
    }

    function testClaimWithdrawalOnBehalfOf() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.QueuedWithdrawal(user1, user1, user1, withdrawAmount, withdrawAmount, currentEpoch);

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Process epoch

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // Claim redemption
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = currentEpoch;

        uint256 initialAssetBalance = asset.balanceOf(user1);
        uint256 initialRedeemableAssets = concreteAsyncVault.pastEpochsUnclaimedAssets();

        vm.prank(withdrawalManager);
        concreteAsyncVault.claimWithdrawal(user1, epochIDs);

        // Check that assets were received
        uint256 finalAssetBalance = asset.balanceOf(user1);
        uint256 assetsReceived = finalAssetBalance - initialAssetBalance;
        assertGt(assetsReceived, 0);

        // Check that redeemable assets were reduced
        assertLt(concreteAsyncVault.pastEpochsUnclaimedAssets(), initialRedeemableAssets);

        // Check that request was cleared
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
    }

    function testClaimWithdrawalEmptyEpochIDs() public {
        uint256[] memory epochIDs = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.EmptyEpochIDs.selector));
        vm.prank(user1);
        concreteAsyncVault.claimWithdrawal(epochIDs);
    }

    function testClaimWithdrawalNoClaimableRequest() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = currentEpoch;
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.EpochNotProcessed.selector, currentEpoch));
        vm.prank(user1);
        concreteAsyncVault.claimWithdrawal(epochIDs);

        // Check that request was cleared
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
    }

    function testToggleQueueActive() public {
        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.QueueActiveToggled(false);
        vm.prank(vaultManager);
        concreteAsyncVault.toggleQueueActive();
        assertEq(concreteAsyncVault.isQueueActive(), false);
    }

    function testToggleQueueActiveUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.VAULT_MANAGER
            )
        );
        concreteAsyncVault.toggleQueueActive();
    }

    function testClaimWithdrawalDisableQueue() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        ERC4626StrategyMock strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));

        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);
        uint256 withdrawAmount = 1000000e18;

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Process epoch

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // Claim redemption

        vm.prank(vaultManager);
        concreteAsyncVault.toggleQueueActive();

        // Check that queue is disabled
        assertEq(concreteAsyncVault.isQueueActive(), false);

        bytes memory extraData = abi.encode(2 * withdrawAmount);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});

        bytes memory data = abi.encode(params);
        vm.prank(allocator);
        concreteAsyncVault.allocate(data);

        uint256 initialAssetBalance = asset.balanceOf(user2);
        //withdraw should skip queue and go to standard vault implementation
        vm.prank(user2);
        concreteAsyncVault.withdraw(withdrawAmount, user2, user2);

        // Check that assets were received
        assertEq(asset.balanceOf(user2), initialAssetBalance + withdrawAmount);
        assertEq(asset.balanceOf(address(concreteAsyncVault)), withdrawAmount);

        //userone should be able to claim withdrawal
        vm.prank(user1);
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = currentEpoch;

        concreteAsyncVault.claimWithdrawal(epochIDs);

        assertEq(asset.balanceOf(user1), initialAssetBalance + withdrawAmount);
        assertEq(asset.balanceOf(address(concreteAsyncVault)), 0);
        assertEq(concreteAsyncVault.totalAssets(), withdrawAmount);
        assertEq(concreteAsyncVault.cachedTotalAssets(), withdrawAmount);
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0);
    }

    function testMoveRequestToNextEpoch() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Close the epoch so we can move from closed → active
        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        uint256 activeEpoch = concreteAsyncVault.latestEpochID();

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.RequestMovedToNextEpoch(user1, withdrawAmount, currentEpoch, activeEpoch);
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user1, currentEpoch, type(uint256).max);

        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, activeEpoch), withdrawAmount);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), 0);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(activeEpoch), withdrawAmount);
    }

    function testMoveRequestToNextEpochUnauthorized() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.WITHDRAWAL_MANAGER
            )
        );
        vm.prank(user1);
        concreteAsyncVault.moveRequestToNextEpoch(user1, currentEpoch, type(uint256).max);
    }

    function testMoveRequestToNextEpochNoRequestingShares() public {
        // Close epoch so there is a previous closed epoch
        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        uint256 closedEpoch = concreteAsyncVault.latestEpochID() - 1;

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.NoRequestingShares.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user1, closedEpoch, type(uint256).max);
    }

    function testEpochProcessingWithYield() public {
        // 1. Add a strategy
        ERC4626StrategyMock strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));

        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);

        // 3. Create 2 requests of withdrawal
        uint256 withdrawAmount1 = 100000e18;
        uint256 withdrawAmount2 = 100000e18;

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount1, user1, user1);

        vm.prank(user2);
        concreteAsyncVault.redeem(withdrawAmount2, user2, user2);

        // Verify that the requests are in the current epoch
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), withdrawAmount1);
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, currentEpoch), withdrawAmount2);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), withdrawAmount1 + withdrawAmount2);

        // 4. Disable the queue
        vm.prank(vaultManager);
        concreteAsyncVault.toggleQueueActive();
        assertFalse(concreteAsyncVault.isQueueActive());

        bytes memory extraData = abi.encode(1000000e18);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});

        bytes memory data = abi.encode(params);
        vm.prank(allocator);
        concreteAsyncVault.allocate(data);

        // 5. Add yield using simulateYield
        uint256 yieldAmount = 300000e18; // 10% yield

        asset.mint(address(this), yieldAmount);
        asset.approve(address(strategy), yieldAmount);
        strategy.simulateYield(yieldAmount);

        // 7. Process the epoch

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // 8. Verify that the share value of the epoch reflects the yield
        uint256 epochPrice = concreteAsyncVault.getEpochPricePerShare(currentEpoch);
        assertTrue(epochPrice > 0, "Epoch price should be set");

        uint256 expectedPrice = (3000000e18 + yieldAmount) * 10 ** concreteAsyncVault.decimals() / 3000000e18;

        // Verify that the price is close to the expected (with tolerance of 1%)
        uint256 priceDifference = epochPrice > expectedPrice ? epochPrice - expectedPrice : expectedPrice - epochPrice;
        uint256 tolerance = expectedPrice / 100; // 1% tolerance
        assertTrue(priceDifference <= tolerance, "Epoch price should reflect yield");

        // 9. Verify that the users can claim with the new price
        vm.prank(user1);
        uint256 claimable1 = concreteAsyncVault.getUserEpochRequestInAssets(user1, currentEpoch);
        uint256 expectedClaimable1 = withdrawAmount1 * epochPrice / 10 ** concreteAsyncVault.decimals();
        assertEq(claimable1, expectedClaimable1, "User1 should be able to claim with new price");

        // 10. Verify that the epoch was incremented
        assertEq(concreteAsyncVault.latestEpochID(), currentEpoch + 1, "Epoch should be incremented");

        // 11. Verify that the assets are reserved for past epochs
        assertTrue(concreteAsyncVault.pastEpochsUnclaimedAssets() > 0, "Assets should be reserved for past epochs");
    }

    function testClaimWithdrawalZeroAddress() public {
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = concreteAsyncVault.latestEpochID();
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroAddress.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimWithdrawal(address(0), epochIDs);
    }

    function testCancelRequestZeroAddress() public {
        uint256 epochID = concreteAsyncVault.latestEpochID();
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroAddress.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.cancelRequest(address(0), epochID);
    }

    function testMoveRequestToNextEpochZeroAddress() public {
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroAddress.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(address(0), currentEpoch, type(uint256).max);
    }

    function testMoveRequestToNextEpochWrongEpochID() public {
        uint256 withdrawAmount = 100000e18;

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        uint256 activeEpoch = concreteAsyncVault.latestEpochID();

        uint256 closedEpoch = activeEpoch - 1;
        // Pass the active epoch instead of the closed epoch
        vm.expectRevert(
            abi.encodeWithSelector(IConcreteAsyncVaultImpl.EpochMismatch.selector, activeEpoch, closedEpoch)
        );
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user1, activeEpoch, type(uint256).max);
    }

    function testMoveRequestToNextEpochAlreadyProcessed() public {
        uint256 withdrawAmount = 100000e18;
        uint256 closedEpoch = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();

        // Close next epoch so closedEpoch-1 pattern works
        concreteAsyncVault.closeEpoch();
        vm.stopPrank();

        // The original closedEpoch is now processed — but to trigger the
        // EpochAlreadyProcessed check we need epochID == latestEpochID - 1
        // which after two closeEpoch() calls is epoch 2. Epoch 2 was just closed
        // but not processed, so let's process it first.
        // Actually: latestEpochID is now 3. closedEpochID = 2. epoch 2 is NOT processed.
        // epoch 1 IS processed. We need the closed epoch to be processed.
        // Let's process epoch 2, close epoch 3, so that latestEpochID=4, closedEpochID=3.
        // But closedEpochID=3 is not processed. We need to set up so closedEpochID is processed.
        // Simplest: process epoch 2, then try to move from epoch 2 (now processed).

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.processEpoch(); // processes epoch 2
        concreteAsyncVault.closeEpoch(); // latestEpochID = 4, closedEpochID = 3

        // epoch 3 is closed but not processed — but we want to test moving from
        // a processed epoch. The require check is on closedEpochID.
        // closedEpochID = latestEpochID - 1 = 3 which is NOT processed.
        // So the only way to hit EpochAlreadyProcessed is if we process epoch 3 too.
        concreteAsyncVault.processEpoch(); // processes epoch 3
        concreteAsyncVault.closeEpoch(); // latestEpochID = 5, closedEpochID = 4

        // process epoch 4
        concreteAsyncVault.processEpoch(); // processes epoch 4
        vm.stopPrank();

        // Now latestEpochID = 5, closedEpochID = 4, and epoch 4 IS processed
        uint256 processedEpoch = concreteAsyncVault.latestEpochID() - 1;
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.EpochAlreadyProcessed.selector, processedEpoch));
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user1, processedEpoch, type(uint256).max);
    }

    function testMoveRequestToNextEpochInsufficientShares() public {
        uint256 withdrawAmount = 100000e18;
        uint256 closedEpoch = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientShares.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user1, closedEpoch, withdrawAmount + 1);
    }

    function testMoveRequestToNextEpochZeroAmount() public {
        uint256 withdrawAmount = 100000e18;
        uint256 closedEpoch = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroShares.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user1, closedEpoch, 0);
    }

    function testMoveRequestToNextEpochPartialAmount() public {
        uint256 withdrawAmount = 100000e18;
        uint256 partialAmount = 40000e18;
        uint256 closedEpoch = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        uint256 activeEpoch = concreteAsyncVault.latestEpochID();

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.RequestMovedToNextEpoch(user1, partialAmount, closedEpoch, activeEpoch);
        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user1, closedEpoch, partialAmount);

        assertEq(concreteAsyncVault.getUserEpochRequest(user1, closedEpoch), withdrawAmount - partialAmount);
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, activeEpoch), partialAmount);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(closedEpoch), withdrawAmount - partialAmount);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(activeEpoch), partialAmount);
    }

    // ============ Partial Epoch Processing Unit Tests ============

    function testProcessPartialEpochRequest() public {
        uint256 withdrawAmount = 100000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        uint256 totalAssetsBefore = concreteAsyncVault.totalAssets();
        uint256 totalSupplyBefore = concreteAsyncVault.totalSupply();

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        uint256 user1AssetsBefore = asset.balanceOf(user1);

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.PartialEpochRequestProcessed(user1, epoch1, withdrawAmount, withdrawAmount);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        vm.stopPrank();

        assertEq(asset.balanceOf(user1), user1AssetsBefore + withdrawAmount, "user received assets");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), 0, "request zeroed");
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), 0, "epoch total zeroed");
        assertEq(concreteAsyncVault.totalAssets(), totalAssetsBefore - withdrawAmount, "totalAssets reduced");
        assertEq(concreteAsyncVault.totalSupply(), totalSupplyBefore - withdrawAmount, "totalSupply reduced");
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0, "no unclaimed assets reserved");
        assertEq(concreteAsyncVault.getEpochPricePerShare(epoch1), 0, "epoch NOT marked processed");
    }

    function testProcessPartialEpochRequestEpochMismatch() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        // Passing the active epoch (1) when closedEpochID = latestEpoch - 1 = 0
        uint256 expectedClosedEpoch = currentEpoch - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IConcreteAsyncVaultImpl.EpochMismatch.selector, currentEpoch, expectedClosedEpoch)
        );
        vm.prank(withdrawalManager);
        concreteAsyncVault.processPartialEpochRequest(user1, currentEpoch, type(uint256).max);
    }

    function testProcessPartialEpochRequestEpochAlreadyProcessed() public {
        uint256 withdrawAmount = 100000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.EpochAlreadyProcessed.selector, epoch1));
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestZeroAddress() public {
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroAddress.selector));
        concreteAsyncVault.processPartialEpochRequest(address(0), epoch1, type(uint256).max);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestNoRequestingShares() public {
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.NoRequestingShares.selector));
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestInsufficientBalance() public {
        ERC4626StrategyMock strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));
        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);

        uint256 withdrawAmount = 100000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        // Allocate all idle funds to strategy so vault has no liquidity
        uint256 vaultBalance = asset.balanceOf(address(concreteAsyncVault));
        bytes memory extraData = abi.encode(vaultBalance);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});
        vm.prank(allocator);
        concreteAsyncVault.allocate(abi.encode(params));

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientBalance.selector));
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestZeroAmount() public {
        uint256 withdrawAmount = 100_000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroShares.selector));
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, 0);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestAmountExceedsRequest() public {
        uint256 withdrawAmount = 100_000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientShares.selector));
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, withdrawAmount + 1);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestAmountExceedsRequestByOne() public {
        uint256 withdrawAmount = 100_000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        // Process half first, then try to exceed the remainder
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, 50_000e18);

        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientShares.selector));
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, 50_000e18 + 1);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestZeroAssets() public {
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        // Request 1 share while the vault is still 1:1
        vm.prank(user1);
        concreteAsyncVault.redeem(1, user1, user1);

        // Allocate to a strategy and simulate a loss so sharePrice drops below 1e18
        ERC4626StrategyMock strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));
        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);

        uint256 vaultBalance = asset.balanceOf(address(concreteAsyncVault));
        bytes memory extraData = abi.encode(vaultBalance);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});
        vm.prank(allocator);
        concreteAsyncVault.allocate(abi.encode(params));

        strategy.simulateLoss(1e18);

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        // 1 share * sharePrice(< 1e18) / 1e18 → floor → 0 assets
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientAssets.selector));
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, 1);
        vm.stopPrank();
    }

    function testProcessPartialEpochRequestPartialAmount() public {
        uint256 withdrawAmount = 100_000e18;
        uint256 partialShares = 40_000e18;
        uint256 remainingShares = withdrawAmount - partialShares;
        uint256 yieldAmount = 300_000e18; // 10% yield on 3M total

        // Setup strategy and simulate profit so exchange rate > 1:1
        ERC4626StrategyMock strategy = new ERC4626StrategyMock(address(asset), address(concreteAsyncVault));
        addStrategyWithDeallocationOrder(address(strategy), address(concreteAsyncVault), allocator, strategyOperator);

        bytes memory extraData = abi.encode(1_000_000e18);
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({isDeposit: true, strategy: address(strategy), extraData: extraData});
        vm.prank(allocator);
        concreteAsyncVault.allocate(abi.encode(params));

        asset.mint(address(this), yieldAmount);
        asset.approve(address(strategy), yieldAmount);
        strategy.simulateYield(yieldAmount);

        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        uint256 totalAssetsBefore = concreteAsyncVault.totalAssets();
        uint256 totalSupplyBefore = concreteAsyncVault.totalSupply();
        uint256 rateBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;
        assertTrue(rateBefore > 1e18, "rate should be > 1:1 after yield");

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        uint256 user1AssetsBefore = asset.balanceOf(user1);

        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, partialShares);
        vm.stopPrank();

        uint256 receivedAssets = asset.balanceOf(user1) - user1AssetsBefore;
        assertTrue(receivedAssets > partialShares, "assets > shares thanks to yield");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), remainingShares, "remaining request");
        assertEq(
            concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), remainingShares, "epoch total reduced by partial"
        );
        assertEq(concreteAsyncVault.totalAssets(), totalAssetsBefore - receivedAssets, "totalAssets reduced");
        assertEq(concreteAsyncVault.totalSupply(), totalSupplyBefore - partialShares, "totalSupply reduced");
        assertApproxEqAbs(
            concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply(),
            rateBefore,
            1,
            "exchange rate preserved after partial at non-1:1 rate"
        );
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0, "no unclaimed assets reserved");
        assertEq(concreteAsyncVault.getEpochPricePerShare(epoch1), 0, "epoch NOT marked processed");
    }

    function testProcessPartialEpochRequestTwoPartials() public {
        uint256 withdrawAmount = 100_000e18;
        uint256 first = 30_000e18;
        uint256 second = 50_000e18;
        uint256 remaining = withdrawAmount - first - second;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        uint256 totalAssetsBefore = concreteAsyncVault.totalAssets();
        uint256 totalSupplyBefore = concreteAsyncVault.totalSupply();
        uint256 rateBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        uint256 user1AssetsBefore = asset.balanceOf(user1);

        // First partial
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, first);
        assertEq(asset.balanceOf(user1), user1AssetsBefore + first, "after first partial");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), withdrawAmount - first);

        // Second partial
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, second);
        vm.stopPrank();

        assertEq(asset.balanceOf(user1), user1AssetsBefore + first + second, "after second partial");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), remaining, "remaining after two partials");
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), remaining, "epoch total after two partials");
        assertEq(concreteAsyncVault.totalAssets(), totalAssetsBefore - first - second, "totalAssets");
        assertEq(concreteAsyncVault.totalSupply(), totalSupplyBefore - first - second, "totalSupply");
        assertEq(
            concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply(),
            rateBefore,
            "exchange rate preserved after two partials"
        );
    }

    function testProcessPartialEpochRequestUintMaxCapsToBalance() public {
        uint256 withdrawAmount = 100_000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        uint256 totalAssetsBefore = concreteAsyncVault.totalAssets();
        uint256 rateBefore = totalAssetsBefore * 1e18 / concreteAsyncVault.totalSupply();

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        uint256 user1AssetsBefore = asset.balanceOf(user1);

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.PartialEpochRequestProcessed(user1, epoch1, withdrawAmount, withdrawAmount);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        vm.stopPrank();

        assertEq(asset.balanceOf(user1), user1AssetsBefore + withdrawAmount, "user received full amount");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), 0, "request fully consumed");
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), 0, "epoch total zeroed");
        assertEq(
            concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply(),
            rateBefore,
            "exchange rate preserved"
        );
    }

    function testProcessPartialEpochRequestUnauthorized() public {
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.WITHDRAWAL_MANAGER
            )
        );
        vm.prank(user1);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
    }

    function testPausePreventsProcessPartialEpochRequest() public {
        uint256 withdrawAmount = 100000e18;
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(withdrawAmount, user1, user1);

        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteAsyncVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteAsyncVault.pause();

        vm.prank(withdrawalManager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
    }

    function testclaimUsersBatch() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        uint256 previousTotalAssets = concreteAsyncVault.totalAssets();

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        vm.prank(user2);
        concreteAsyncVault.withdraw(withdrawAmount, user2, user2);

        vm.prank(user3);
        concreteAsyncVault.withdraw(withdrawAmount, user3, user3);

        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = currentEpoch;

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.RequestClaimed(user1, withdrawAmount, epochIDs);
        emit IConcreteAsyncVaultImpl.RequestClaimed(user2, withdrawAmount, epochIDs);
        emit IConcreteAsyncVaultImpl.RequestClaimed(user3, withdrawAmount, epochIDs);
        vm.prank(withdrawalManager);

        concreteAsyncVault.claimUsersBatch(users, currentEpoch);

        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), 0);
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, currentEpoch), 0);
        assertEq(concreteAsyncVault.getUserEpochRequest(user3, currentEpoch), 0);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), withdrawAmount * 3);
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0);
        assertEq(concreteAsyncVault.totalAssets(), previousTotalAssets - withdrawAmount * 3);
        assertEq(concreteAsyncVault.cachedTotalAssets(), previousTotalAssets - withdrawAmount * 3);
    }

    function testClaimUsersBatchZeroAddress() public {
        address[] memory users = new address[](0);
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.EmptyUsers.selector));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimUsersBatch(users, currentEpoch);
    }

    function testClaimUsersBatchNoClaimableRequest() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.EpochNotProcessed.selector, currentEpoch));
        vm.prank(withdrawalManager);
        concreteAsyncVault.claimUsersBatch(users, currentEpoch);
    }

    function testClaimUsersBatchUnauthorized() public {
        address[] memory users = new address[](1);
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        users[0] = user1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.WITHDRAWAL_MANAGER
            )
        );
        vm.prank(user1);
        concreteAsyncVault.claimUsersBatch(users, currentEpoch);
    }

    function testWithdrawSpendAllowance() public {
        uint256 withdrawAmount = 100000e18;
        address thirdParty = makeAddr("thirdParty");

        // Fund thirdParty with some assets for gas
        vm.deal(thirdParty, 1 ether);

        // Test case 1: Owner makes withdrawal directly (no allowance needed)
        uint256 initialBalance = concreteAsyncVault.balanceOf(user1);
        uint256 initialAllowance = concreteAsyncVault.allowance(user1, user1);

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Verify shares were transferred to vault (async withdrawal)
        assertEq(concreteAsyncVault.balanceOf(user1), initialBalance - withdrawAmount);
        assertEq(concreteAsyncVault.balanceOf(address(concreteAsyncVault)), withdrawAmount);
        assertEq(concreteAsyncVault.allowance(user1, user1), initialAllowance); // No change in allowance

        // Test case 2: Third party tries to withdraw without allowance (should fail)
        vm.expectRevert();
        vm.prank(thirdParty);
        concreteAsyncVault.withdraw(withdrawAmount, thirdParty, user1);

        // Test case 3: Third party withdraws with allowance (should succeed)
        vm.prank(user1);
        concreteAsyncVault.approve(thirdParty, withdrawAmount);

        uint256 allowanceBefore = concreteAsyncVault.allowance(user1, thirdParty);
        assertEq(allowanceBefore, withdrawAmount);

        vm.prank(thirdParty);
        concreteAsyncVault.withdraw(withdrawAmount, thirdParty, user1);

        // Verify allowance was spent
        uint256 allowanceAfter = concreteAsyncVault.allowance(user1, thirdParty);
        assertEq(allowanceAfter, 0);

        // Verify shares were transferred to vault
        assertEq(concreteAsyncVault.balanceOf(user1), initialBalance - (2 * withdrawAmount));
        assertEq(concreteAsyncVault.balanceOf(address(concreteAsyncVault)), 2 * withdrawAmount);

        // Verify both requests are in the current epoch
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, currentEpoch), withdrawAmount);
        assertEq(concreteAsyncVault.getUserEpochRequest(thirdParty, currentEpoch), withdrawAmount);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(currentEpoch), 2 * withdrawAmount);
    }

    function testWithdrawSpendAllowanceQueueDisabled() public {
        uint256 withdrawAmount = 100000e18;
        address thirdParty = makeAddr("thirdParty");

        // Fund thirdParty with some assets for gas
        vm.deal(thirdParty, 1 ether);

        // Disable queue to test standard withdrawal behavior
        vm.prank(vaultManager);
        concreteAsyncVault.toggleQueueActive();
        assertFalse(concreteAsyncVault.isQueueActive());

        // Test case 1: Owner makes withdrawal directly (no allowance needed)
        uint256 initialAssetBalance = asset.balanceOf(user1);

        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Verify assets were transferred directly (standard withdrawal)
        assertEq(asset.balanceOf(user1), initialAssetBalance + withdrawAmount);

        // Test case 2: Third party tries to withdraw without allowance (should fail)
        vm.prank(thirdParty);
        vm.expectRevert();
        concreteAsyncVault.withdraw(withdrawAmount, thirdParty, user1);

        // Test case 3: Third party withdraws with allowance (should succeed)
        vm.prank(user1);
        concreteAsyncVault.approve(thirdParty, withdrawAmount);

        uint256 allowanceBefore = concreteAsyncVault.allowance(user1, thirdParty);
        assertEq(allowanceBefore, withdrawAmount);

        uint256 initialThirdPartyAssetBalance = asset.balanceOf(thirdParty);

        vm.prank(thirdParty);
        concreteAsyncVault.withdraw(withdrawAmount, thirdParty, user1);

        // Verify allowance was spent
        uint256 allowanceAfter = concreteAsyncVault.allowance(user1, thirdParty);
        assertEq(allowanceAfter, 0);

        // Verify assets were transferred directly
        assertEq(asset.balanceOf(thirdParty), initialThirdPartyAssetBalance + withdrawAmount);
    }

    function testPausePreventsCancelRequest() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Pause the vault
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteAsyncVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteAsyncVault.pause();

        // Should not be able to cancel request when paused
        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteAsyncVault.cancelRequest(currentEpoch);
    }

    function testPausePreventsClaimWithdrawal() public {
        uint256 withdrawAmount = 100000e18;
        uint256 currentEpoch = concreteAsyncVault.latestEpochID();

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Process epoch
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        // Pause the vault
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteAsyncVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteAsyncVault.pause();

        // Should not be able to claim withdrawal when paused
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = currentEpoch;

        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteAsyncVault.claimWithdrawal(epochIDs);
    }

    function testPausePreventsProcessEpoch() public {
        uint256 withdrawAmount = 100000e18;

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Close epoch
        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();

        // Pause the vault
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteAsyncVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteAsyncVault.pause();

        // Should not be able to process epoch when paused
        vm.prank(withdrawalManager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteAsyncVault.processEpoch();
    }

    function testPausePreventsCloseEpoch() public {
        uint256 withdrawAmount = 100000e18;

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Pause the vault
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteAsyncVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteAsyncVault.pause();

        // Should not be able to close epoch when paused
        vm.prank(withdrawalManager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteAsyncVault.closeEpoch();
    }

    function testPausePreventsMoveRequestToNextEpoch() public {
        uint256 withdrawAmount = 100000e18;

        // Create withdrawal request
        vm.prank(user1);
        concreteAsyncVault.withdraw(withdrawAmount, user1, user1);

        // Pause the vault
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteAsyncVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteAsyncVault.pause();

        // Should not be able to move request when paused
        uint256 closedEpoch = concreteAsyncVault.latestEpochID() - 1;
        vm.prank(withdrawalManager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteAsyncVault.moveRequestToNextEpoch(user1, closedEpoch, type(uint256).max);
    }
}
