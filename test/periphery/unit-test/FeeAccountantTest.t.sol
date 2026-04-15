// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeAccountant} from "../../../src/periphery/auxiliary/FeeAccountant.sol";
import {ERC20Mock} from "../../mock/ERC20Mock.sol";
import {ERC4626Mock} from "../../mock/ERC4626Mock.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";

contract FeeAccountantTest is Test {
    FeeAccountant public accountant;
    ERC20Mock public asset;
    ERC4626Mock public vault;

    address public admin = makeAddr("admin");
    address public distributor = makeAddr("distributor");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant INITIAL_ASSETS = 10_000e18;
    uint256 constant VAULT_SHARES = 1_000e18;

    function setUp() public {
        asset = new ERC20Mock();
        vault = new ERC4626Mock(address(asset));

        FeeAccountant impl = new FeeAccountant();
        bytes memory initData = abi.encodeCall(FeeAccountant.initialize, (admin, address(vault)));
        accountant = FeeAccountant(address(new ERC1967Proxy(address(impl), initData)));

        asset.mint(address(vault), INITIAL_ASSETS);
        vault.mint(address(accountant), VAULT_SHARES);

        vm.startPrank(admin);
        accountant.addRecipient(alice);
        accountant.addRecipient(bob);
        accountant.addRecipient(carol);
        vm.stopPrank();
    }

    // ── Initialization ───────────────────────────────────────────────────

    function test_initialize_setsAdminRoles() public view {
        assertTrue(accountant.hasRole(accountant.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(accountant.hasRole(accountant.DISTRIBUTOR_ROLE(), admin));
    }

    function test_initialize_setsVault() public view {
        assertEq(address(accountant.vault()), address(vault));
    }

    function test_initialize_revertsOnZeroAdmin() public {
        FeeAccountant impl = new FeeAccountant();
        bytes memory initData = abi.encodeCall(FeeAccountant.initialize, (address(0), address(vault)));
        vm.expectRevert(FeeAccountant.ZeroAdmin.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsOnZeroVault() public {
        FeeAccountant impl = new FeeAccountant();
        bytes memory initData = abi.encodeCall(FeeAccountant.initialize, (admin, address(0)));
        vm.expectRevert(FeeAccountant.ZeroVault.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        accountant.initialize(admin, address(vault));
    }

    // ── Recipient whitelist management ────────────────────────────────────

    function test_addRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(admin);
        accountant.addRecipient(newRecipient);
        assertTrue(accountant.whitelistedRecipients(newRecipient));
    }

    function test_addRecipient_emitsEvent() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(true, false, false, false);
        emit FeeAccountant.RecipientWhitelisted(newRecipient);
        vm.prank(admin);
        accountant.addRecipient(newRecipient);
    }

    function test_addRecipient_revertsOnZeroAddress() public {
        vm.expectRevert(FeeAccountant.ZeroAddress.selector);
        vm.prank(admin);
        accountant.addRecipient(address(0));
    }

    function test_addRecipient_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, accountant.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(bob);
        accountant.addRecipient(makeAddr("someone"));
    }

    function test_removeRecipient() public {
        vm.prank(admin);
        accountant.removeRecipient(alice);
        assertFalse(accountant.whitelistedRecipients(alice));
    }

    function test_removeRecipient_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit FeeAccountant.RecipientRemovedFromWhitelist(alice);
        vm.prank(admin);
        accountant.removeRecipient(alice);
    }

    function test_removeRecipient_revertsOnZeroAddress() public {
        vm.expectRevert(FeeAccountant.ZeroAddress.selector);
        vm.prank(admin);
        accountant.removeRecipient(address(0));
    }

    function test_removeRecipient_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, accountant.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(bob);
        accountant.removeRecipient(alice);
    }

    // ── Role management ──────────────────────────────────────────────────

    function test_grantDistributorRole() public {
        vm.startPrank(admin);
        accountant.grantRole(accountant.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();
        assertTrue(accountant.hasRole(accountant.DISTRIBUTOR_ROLE(), distributor));
    }

    function test_revokeDistributorRole() public {
        vm.startPrank(admin);
        accountant.grantRole(accountant.DISTRIBUTOR_ROLE(), distributor);
        accountant.revokeRole(accountant.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();
        assertFalse(accountant.hasRole(accountant.DISTRIBUTOR_ROLE(), distributor));
    }

    // ── distributeFeeShares: happy path ──────────────────────────────────

    function test_distribute_singleRecipient() public {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        amounts[0] = 100e18;

        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 100e18);

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.balanceOf(address(accountant)), VAULT_SHARES - 100e18);
    }

    function test_distribute_multipleRecipients() public {
        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = carol;
        amounts[0] = 100e18;
        amounts[1] = 200e18;
        amounts[2] = 50e18;

        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 350e18);

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.balanceOf(bob), 200e18);
        assertEq(vault.balanceOf(carol), 50e18);
    }

    function test_distribute_emitsFeeDistributionEvent() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        uint256 oneShare = 10 ** vault.decimals();
        uint256 sharePrice = vault.convertToAssets(oneShare);

        vm.expectEmit(true, false, false, true);
        emit FeeAccountant.FeeDistribution(address(vault), sharePrice, 300e18);

        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 300e18);
    }

    function test_distribute_emitsFeeTransferredPerRecipient() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        vm.expectEmit(true, true, false, true);
        emit FeeAccountant.FeeTransferred(address(vault), alice, 100e18);
        vm.expectEmit(true, true, false, true);
        emit FeeAccountant.FeeTransferred(address(vault), bob, 200e18);

        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 300e18);
    }

    function test_distribute_sharePriceReflectsVaultState() public {
        uint256 oneShare = 10 ** vault.decimals();
        uint256 priceBefore = vault.convertToAssets(oneShare);

        asset.mint(address(vault), INITIAL_ASSETS);

        uint256 priceAfter = vault.convertToAssets(oneShare);
        assertApproxEqAbs(priceAfter, 2 * priceBefore, 1, "share price should ~double after doubling assets");

        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        amounts[0] = 10e18;

        vm.expectEmit(true, false, false, true);
        emit FeeAccountant.FeeDistribution(address(vault), priceAfter, 10e18);

        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 10e18);
    }

    function test_distribute_entireBalance() public {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        amounts[0] = VAULT_SHARES;

        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, VAULT_SHARES);

        assertEq(vault.balanceOf(address(accountant)), 0);
        assertEq(vault.balanceOf(alice), VAULT_SHARES);
    }

    function test_distribute_withGrantedDistributor() public {
        vm.startPrank(admin);
        accountant.grantRole(accountant.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();

        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        amounts[0] = 50e18;

        vm.prank(distributor);
        accountant.distributeFeeShares(recipients, amounts, 50e18);

        assertEq(vault.balanceOf(alice), 50e18);
    }

    // ── distributeFeeShares: reverts ─────────────────────────────────────

    function test_distribute_revertsIfNotDistributor() public {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        amounts[0] = 10e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, accountant.DISTRIBUTOR_ROLE()
            )
        );
        vm.prank(bob);
        accountant.distributeFeeShares(recipients, amounts, 10e18);
    }

    function test_distribute_revertsOnEmptyArrays() public {
        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(FeeAccountant.EmptyArrays.selector);
        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 0);
    }

    function test_distribute_revertsOnArrayLengthMismatch() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 10e18;

        vm.expectRevert(FeeAccountant.ArrayLengthMismatch.selector);
        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 10e18);
    }

    function test_distribute_revertsOnTotalMismatch() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        vm.expectRevert(abi.encodeWithSelector(FeeAccountant.TotalMismatch.selector, 999e18, 300e18));
        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 999e18);
    }

    function test_distribute_revertsOnNonWhitelistedRecipient() public {
        address outsider = makeAddr("outsider");
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = outsider;
        amounts[0] = 10e18;
        amounts[1] = 20e18;

        vm.expectRevert(abi.encodeWithSelector(FeeAccountant.RecipientNotWhitelisted.selector, outsider));
        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 30e18);
    }

    function test_distribute_revertsAfterRecipientRemoved() public {
        vm.prank(admin);
        accountant.removeRecipient(bob);

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 10e18;
        amounts[1] = 20e18;

        vm.expectRevert(abi.encodeWithSelector(FeeAccountant.RecipientNotWhitelisted.selector, bob));
        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, 30e18);
    }

    function test_distribute_revertsOnInsufficientBalance() public {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        amounts[0] = VAULT_SHARES + 1;

        vm.expectRevert();
        vm.prank(admin);
        accountant.distributeFeeShares(recipients, amounts, VAULT_SHARES + 1);
    }

    // ── rescueToken ───────────────────────────────────────────────────────

    function test_rescueToken() public {
        ERC20Mock stray = new ERC20Mock();
        stray.mint(address(accountant), 500e18);

        vm.prank(admin);
        accountant.rescueToken(address(stray), alice, 500e18);

        assertEq(stray.balanceOf(alice), 500e18);
        assertEq(stray.balanceOf(address(accountant)), 0);
    }

    function test_rescueToken_emitsEvent() public {
        ERC20Mock stray = new ERC20Mock();
        stray.mint(address(accountant), 100e18);

        vm.expectEmit(true, true, false, true);
        emit FeeAccountant.TokenRescued(address(stray), alice, 100e18);

        vm.prank(admin);
        accountant.rescueToken(address(stray), alice, 100e18);
    }

    function test_rescueToken_revertsOnVaultShares() public {
        vm.expectRevert(FeeAccountant.CannotRescueVaultShares.selector);
        vm.prank(admin);
        accountant.rescueToken(address(vault), alice, 50e18);
    }

    function test_rescueToken_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, accountant.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(bob);
        accountant.rescueToken(address(vault), alice, 10e18);
    }

    function test_rescueToken_revertsOnZeroToken() public {
        vm.expectRevert(FeeAccountant.ZeroToken.selector);
        vm.prank(admin);
        accountant.rescueToken(address(0), alice, 10e18);
    }

    function test_rescueToken_revertsOnZeroTo() public {
        vm.expectRevert(FeeAccountant.ZeroRecipient.selector);
        vm.prank(admin);
        accountant.rescueToken(address(asset), address(0), 10e18);
    }

    function test_rescueToken_revertsOnZeroAmount() public {
        vm.expectRevert(FeeAccountant.ZeroAmount.selector);
        vm.prank(admin);
        accountant.rescueToken(address(asset), alice, 0);
    }

    // ── UUPS upgrade authorization ───────────────────────────────────────

    function test_upgrade_revertsIfNotAdmin() public {
        FeeAccountant newImpl = new FeeAccountant();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, accountant.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(bob);
        accountant.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_succeedsAsAdmin() public {
        FeeAccountant newImpl = new FeeAccountant();

        vm.prank(admin);
        accountant.upgradeToAndCall(address(newImpl), "");
    }
}
