// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    IConcreteStandardVaultImpl,
    ConcreteStandardVaultImplBaseSetup
} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {IUpgradeableVault} from "../../../src/interface/IUpgradeableVault.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";

import {ConcreteV2FeeParamsLib} from "../../../src/lib/Constants.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

contract ManagementFunctionsUnitTest is ConcreteStandardVaultImplBaseSetup {
    address public user1;
    address public user2;
    address public feeRecipient;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        feeRecipient = makeAddr("feeRecipient");

        // Fund user accounts
        asset.mint(user1, 1000000e18);
        asset.mint(user2, 1000000e18);

        // Setup initial state
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), 1000000e18);
        concreteStandardVault.deposit(1000000e18, user1);
        vm.stopPrank();
    }

    // ============================================================================
    // UPDATE MANAGEMENT FEE TESTS
    // ============================================================================

    function testUpdateManagementFee() public {
        vm.prank(factoryOwner);
        concreteStandardVault.updateManagementFeeRecipient(feeRecipient);

        vm.expectEmit(true, true, false, true);
        emit IConcreteStandardVaultImpl.ManagementFeeUpdated(500);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee, abi.encode(uint16(500))
        ); // 5%

        (uint16 fee, address recipient, uint32 lastAccrual,,) = concreteStandardVault.getFeeConfig();
        assertEq(fee, 500);
        assertEq(recipient, feeRecipient);
        assertGt(lastAccrual, 0);
    }

    function testUpdateManagementFeeZero() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee, abi.encode(uint16(0))
        );
        (uint16 fee,,,,) = concreteStandardVault.getFeeConfig();
        assertEq(fee, 0);
    }

    function testUpdateManagementFeeExceedsMaximum() public {
        vm.prank(factoryOwner);
        concreteStandardVault.updateManagementFeeRecipient(feeRecipient);
        vm.expectRevert(IConcreteStandardVaultImpl.ManagementFeeExceedsMaximum.selector);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee,
            abi.encode(uint16(ConcreteV2FeeParamsLib.MAX_MANAGEMENT_FEE + 1))
        );
    }

    function testUpdateManagementFeeUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.VAULT_MANAGER
            )
        );
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee, abi.encode(uint16(500))
        );
    }

    function testUpdateManagementFeeRecipient() public {
        vm.expectEmit(true, true, false, true);
        emit IConcreteStandardVaultImpl.ManagementFeeRecipientUpdated(feeRecipient);
        vm.prank(factoryOwner);
        concreteStandardVault.updateManagementFeeRecipient(feeRecipient);

        (, address recipient, uint32 lastAccrual,,) = concreteStandardVault.getFeeConfig();
        assertEq(recipient, feeRecipient);
        assertGt(lastAccrual, 0);
    }

    function testUpdateManagementFeeRecipientZeroAddress() public {
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteStandardVaultImpl.InvalidFeeRecipient.selector);
        concreteStandardVault.updateManagementFeeRecipient(address(0));
    }

    function testUpdateManagementFeeRecipientUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(IUpgradeableVault.InvalidFactoryOwner.selector);
        concreteStandardVault.updateManagementFeeRecipient(feeRecipient);
    }

    function testUpdatePerformanceFee() public {
        vm.prank(factoryOwner);
        concreteStandardVault.updatePerformanceFeeRecipient(feeRecipient);

        vm.expectEmit(true, true, false, true);
        emit IConcreteStandardVaultImpl.PerformanceFeeUpdated(300);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(uint16(300))
        ); // 3%

        (,,, uint16 fee, address recipient) = concreteStandardVault.getFeeConfig();
        assertEq(fee, 300);
        assertEq(recipient, feeRecipient);
    }

    function testUpdatePerformanceFeeZero() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(uint16(0))
        );

        (,,, uint16 fee,) = concreteStandardVault.getFeeConfig();
        assertEq(fee, 0);
    }

    function testUpdatePerformanceFeeExceedsMaximum() public {
        vm.prank(factoryOwner);
        concreteStandardVault.updatePerformanceFeeRecipient(feeRecipient);
        vm.expectRevert(IConcreteStandardVaultImpl.PerformanceFeeExceedsMaximum.selector);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee,
            abi.encode(uint16(ConcreteV2FeeParamsLib.MAX_PERFORMANCE_FEE + 1))
        );
    }

    function testUpdatePerformanceFeeUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.VAULT_MANAGER
            )
        );
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(uint16(300))
        );
    }

    function testUpdatePerformanceFeeRecipient() public {
        vm.expectEmit(true, true, false, true);
        emit IConcreteStandardVaultImpl.PerformanceFeeRecipientUpdated(feeRecipient);
        vm.prank(factoryOwner);
        concreteStandardVault.updatePerformanceFeeRecipient(feeRecipient);
        (,,,, address recipient) = concreteStandardVault.getFeeConfig();

        assertEq(recipient, feeRecipient);
    }

    function testUpdatePerformanceFeeRecipientZeroAddress() public {
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteStandardVaultImpl.InvalidFeeRecipient.selector);
        concreteStandardVault.updatePerformanceFeeRecipient(address(0));
    }

    function testUpdatePerformanceFeeRecipientUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(IUpgradeableVault.InvalidFactoryOwner.selector);
        concreteStandardVault.updatePerformanceFeeRecipient(feeRecipient);
    }

    function testUpdateFeesTriggersYieldAccrual() public {
        // Set management fee and recipient
        vm.prank(factoryOwner);
        concreteStandardVault.updateManagementFeeRecipient(feeRecipient);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee, abi.encode(uint16(100))
        );

        // Set performance fee and recipient
        vm.prank(factoryOwner);
        concreteStandardVault.updatePerformanceFeeRecipient(feeRecipient);
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(uint16(100))
        );

        // Fast forward time
        vm.warp(block.timestamp + 1 days);

        // Update fees again - should trigger yield accrual
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee, abi.encode(uint16(200))
        );

        // Check that lastManagementFeeAccrual was updated
        (,, uint32 lastAccrual,,) = concreteStandardVault.getFeeConfig();
        assertEq(lastAccrual, block.timestamp);
    }

    function testSetDepositLimits() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(1000000e18, 1000000e18)
        );

        (uint256 maxDepositAmount, uint256 minDepositAmount) = concreteStandardVault.getDepositLimits();
        assertEq(maxDepositAmount, 1000000e18);
        assertEq(minDepositAmount, 1000000e18);
    }

    function testSetDepositLimitsUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.VAULT_MANAGER
            )
        );
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(1000000e18, 1000000e18)
        );
    }

    function testSetDepositLimitsInvalidLimits() public {
        vm.prank(vaultManager);
        vm.expectRevert(IConcreteStandardVaultImpl.InvalidDepositLimits.selector);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(1000000e18, 1000000e17)
        );
    }

    function testSetWithdrawLimits() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(1000000e18, 1000000e18)
        );

        (uint256 maxWithdrawAmount, uint256 minWithdrawAmount) = concreteStandardVault.getWithdrawLimits();
        assertEq(maxWithdrawAmount, 1000000e18);
        assertEq(minWithdrawAmount, 1000000e18);
    }

    function testSetWithdrawLimitsUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.VAULT_MANAGER
            )
        );
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(1000000e18, 1000000e18)
        );
    }

    function testSetWithdrawLimitsInvalidLimits() public {
        vm.prank(vaultManager);
        vm.expectRevert(IConcreteStandardVaultImpl.InvalidWithdrawLimits.selector);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(1000000e18, 1000000e17)
        );
    }

    // ============================================================================
    // DEFAULT FEE RECIPIENTS TESTS
    // ============================================================================

    function testVaultHasDefaultFeeRecipientsFromFactory() public {
        // Verify management fee recipient is set from factory's default config
        (, address mgmtRecipient,,,) = concreteStandardVault.getFeeConfig();
        assertEq(mgmtRecipient, defaultManagementFeeRecipient, "Management fee recipient should match factory default");

        // Verify performance fee recipient is set from factory's default config
        (,,,, address perfRecipient) = concreteStandardVault.getFeeConfig();
        assertEq(
            perfRecipient, defaultPerformanceFeeRecipient, "Performance fee recipient should match factory default"
        );
    }

    function testDefaultFeeRecipientsAllowSettingFees() public {
        // Since default fee recipients are set, we should be able to set fees without reverting
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee, abi.encode(uint16(500))
        ); // 5%

        (uint16 mgmtFee,,,,) = concreteStandardVault.getFeeConfig();
        assertEq(mgmtFee, 500, "Management fee should be set");

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee, abi.encode(uint16(1000))
        ); // 10%

        (,,, uint16 perfFee,) = concreteStandardVault.getFeeConfig();
        assertEq(perfFee, 1000, "Performance fee should be set");
    }

    function testFactoryOwnerCanUpdateDefaultRecipients() public {
        address newMgmtRecipient = makeAddr("newMgmtRecipient");
        address newPerfRecipient = makeAddr("newPerfRecipient");

        // Update default recipients on factory
        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(newMgmtRecipient, newPerfRecipient);

        // Verify factory config was updated
        (address defaultMgmt, address defaultPerf) = factory.getDefaultEnforcedVaultConfiguration();
        assertEq(defaultMgmt, newMgmtRecipient, "Factory default management fee recipient should be updated");
        assertEq(defaultPerf, newPerfRecipient, "Factory default performance fee recipient should be updated");
    }

    function testNewVaultGetsUpdatedDefaultRecipients() public {
        address newMgmtRecipient = makeAddr("newMgmtRecipient");
        address newPerfRecipient = makeAddr("newPerfRecipient");

        // Update default recipients on factory
        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(newMgmtRecipient, newPerfRecipient);

        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());

        // Create a new vault - it should get the updated default recipients
        ConcreteStandardVaultImpl newVault = ConcreteStandardVaultImpl(
            factory.create(
                vaultImpl,
                vaultOwner,
                abi.encode(address(allocateModule), address(asset), vaultManager, "New Vault", "NV")
            )
        );

        (, address mgmtRecipient,,,) = newVault.getFeeConfig();
        assertEq(mgmtRecipient, newMgmtRecipient, "New vault should have updated management fee recipient");

        (,,,, address perfRecipient) = newVault.getFeeConfig();
        assertEq(perfRecipient, newPerfRecipient, "New vault should have updated performance fee recipient");
    }

    // ============================================================================
    // TWO-STEP OWNERSHIP TESTS
    // ============================================================================

    function test_transferOwnership_setsPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        assertEq(concreteStandardVault.owner(), vaultOwner);
        assertEq(Ownable2StepUpgradeable(address(concreteStandardVault)).pendingOwner(), address(0));

        vm.expectEmit(true, true, false, false);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(vaultOwner, newOwner);

        vm.prank(vaultOwner);
        concreteStandardVault.transferOwnership(newOwner);

        // owner unchanged until accepted
        assertEq(concreteStandardVault.owner(), vaultOwner);
        assertEq(Ownable2StepUpgradeable(address(concreteStandardVault)).pendingOwner(), newOwner);
    }

    function test_acceptOwnership_completesTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(vaultOwner);
        concreteStandardVault.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, false);
        emit OwnableUpgradeable.OwnershipTransferred(vaultOwner, newOwner);

        vm.prank(newOwner);
        Ownable2StepUpgradeable(address(concreteStandardVault)).acceptOwnership();

        assertEq(concreteStandardVault.owner(), newOwner);
        assertEq(Ownable2StepUpgradeable(address(concreteStandardVault)).pendingOwner(), address(0));
    }

    function test_transferOwnership_revertsForNonOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        concreteStandardVault.transferOwnership(newOwner);
    }

    function test_acceptOwnership_revertsForNonPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(vaultOwner);
        concreteStandardVault.transferOwnership(newOwner);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        Ownable2StepUpgradeable(address(concreteStandardVault)).acceptOwnership();
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(IConcreteStandardVaultImpl.RenounceOwnershipDisabled.selector);
        concreteStandardVault.renounceOwnership();
    }

    // ============================================================================
    // LAST ROLE_ADMIN PROTECTION TESTS
    // ============================================================================

    function test_lastRoleAdmin_cannotRevokeItself() public {
        // vaultManager is the sole ROLE_ADMIN granted at initialization.
        assertEq(concreteStandardVault.getRoleMemberCount(RolesLib.ROLE_ADMIN), 1);

        vm.prank(vaultManager);
        vm.expectRevert(IConcreteStandardVaultImpl.CannotRemoveLastRoleAdmin.selector);
        concreteStandardVault.revokeRole(RolesLib.ROLE_ADMIN, vaultManager);

        assertTrue(concreteStandardVault.hasRole(RolesLib.ROLE_ADMIN, vaultManager));
    }

    function test_lastRoleAdmin_cannotRenounceItself() public {
        assertEq(concreteStandardVault.getRoleMemberCount(RolesLib.ROLE_ADMIN), 1);

        vm.prank(vaultManager);
        vm.expectRevert(IConcreteStandardVaultImpl.CannotRemoveLastRoleAdmin.selector);
        concreteStandardVault.renounceRole(RolesLib.ROLE_ADMIN, vaultManager);

        assertTrue(concreteStandardVault.hasRole(RolesLib.ROLE_ADMIN, vaultManager));
    }

    function test_roleAdmin_canSelfRevokeWhenMultipleAdmins() public {
        address newAdmin = makeAddr("newAdmin");

        // Add a second ROLE_ADMIN.
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.ROLE_ADMIN, newAdmin);
        assertEq(concreteStandardVault.getRoleMemberCount(RolesLib.ROLE_ADMIN), 2);

        // With two admins, one can renounce its own admin role.
        vm.prank(vaultManager);
        concreteStandardVault.renounceRole(RolesLib.ROLE_ADMIN, vaultManager);

        assertFalse(concreteStandardVault.hasRole(RolesLib.ROLE_ADMIN, vaultManager));
        assertEq(concreteStandardVault.getRoleMemberCount(RolesLib.ROLE_ADMIN), 1);
    }

    function test_roleAdmin_canRevokeAnotherWhenMultipleAdmins() public {
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.ROLE_ADMIN, newAdmin);
        assertEq(concreteStandardVault.getRoleMemberCount(RolesLib.ROLE_ADMIN), 2);

        // With two admins, an admin can remove the other.
        concreteStandardVault.revokeRole(RolesLib.ROLE_ADMIN, newAdmin);
        vm.stopPrank();

        assertFalse(concreteStandardVault.hasRole(RolesLib.ROLE_ADMIN, newAdmin));
        assertTrue(concreteStandardVault.hasRole(RolesLib.ROLE_ADMIN, vaultManager));
        assertEq(concreteStandardVault.getRoleMemberCount(RolesLib.ROLE_ADMIN), 1);
    }
    // SWEEP DONATED TOKENS TESTS
    // ============================================================================

    function testSweepDonatedTokens_UnderlyingAsset() public {
        uint256 donationAmount = 500e18;
        address sweepRecipient = makeAddr("sweepRecipient");

        // Directly transfer tokens to vault (donation — bypasses deposit)
        asset.mint(address(concreteStandardVault), donationAmount);

        vm.expectEmit(true, true, false, true);
        emit IConcreteStandardVaultImpl.DonationSwept(address(asset), sweepRecipient, donationAmount);

        vm.prank(vaultManager);
        concreteStandardVault.sweepDonatedTokens(address(asset), sweepRecipient);

        assertEq(asset.balanceOf(sweepRecipient), donationAmount);
    }

    function testSweepDonatedTokens_NoDonation() public {
        // No donation — should be a no-op
        vm.prank(vaultManager);
        concreteStandardVault.sweepDonatedTokens(address(asset), vaultManager);

        assertEq(asset.balanceOf(vaultManager), 0);
    }

    function testSweepDonatedTokens_Unauthorized() public {
        asset.mint(address(concreteStandardVault), 100e18);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, RolesLib.VAULT_MANAGER
            )
        );
        concreteStandardVault.sweepDonatedTokens(address(asset), user1);
    }

    function testSweepDonatedTokens_ZeroRecipient() public {
        asset.mint(address(concreteStandardVault), 100e18);

        vm.prank(vaultManager);
        vm.expectRevert(IConcreteStandardVaultImpl.InvalidReceiver.selector);
        concreteStandardVault.sweepDonatedTokens(address(asset), address(0));
    }
}
