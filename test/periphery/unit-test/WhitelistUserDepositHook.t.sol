// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {WhitelistUserDepositHook} from "../../../src/periphery/hooks/WhitelistUserDepositHook.sol";
import {UserDepositCapHook} from "../../../src/periphery/hooks/UserDepositCapHook.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {HooksLibV1} from "../../../src/lib/Hooks.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

contract WhitelistUserDepositHookTest is ConcreteStandardVaultImplBaseSetup {
    WhitelistUserDepositHook public hook;

    address alice;
    address bob;
    address charlie;
    address dave;
    address hookOwner;

    uint256 constant VAULT_CAP = 1000 ether;

    event WhitelistSet(address indexed user, bool indexed isWhitelisted);

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();

        // Setup test accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave = makeAddr("dave");
        hookOwner = makeAddr("hookOwner");

        // Deploy the whitelist hook
        hook = new WhitelistUserDepositHook(hookOwner);

        // Configure the vault's deposit cap
        vm.prank(hookOwner);
        hook.setVaultDepositCap(address(concreteStandardVault), VAULT_CAP);

        // Mint assets to test users
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);
        asset.mint(charlie, 10000 ether);
        asset.mint(dave, 10000 ether);

        // Setup hooks on vault
        uint96 flags = uint96(1 << HooksLibV1.PRE_DEPOSIT) | uint96(1 << HooksLibV1.PRE_MINT);
        Hooks memory hooks = Hooks({target: address(hook), flags: flags});

        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Constructor Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_constructor_noDefaultCap() public {
        WhitelistUserDepositHook newHook = new WhitelistUserDepositHook(hookOwner);
        assertEq(newHook.getUserDepositCap(address(concreteStandardVault)), 0);
        assertFalse(newHook.isWhitelisted(alice));
    }

    function test_constructor_revertsInvalidOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new WhitelistUserDepositHook(address(0));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Set Vault Deposit Cap Tests (Inherited functionality)
    // ═════════════════════════════════════════════════════════════════════════════

    function test_setVaultDepositCap() public {
        address newVault = makeAddr("newVault");
        uint256 newCap = 5000 ether;

        vm.expectEmit(true, true, true, true);
        emit UserDepositCapHook.VaultDepositCapSet(newVault, 0, newCap);

        vm.prank(hookOwner);
        hook.setVaultDepositCap(newVault, newCap);

        assertEq(hook.getUserDepositCap(newVault), newCap);
    }

    function test_setVaultDepositCap_updateExisting() public {
        uint256 newCap = 2000 ether;

        vm.expectEmit(true, true, true, true);
        emit UserDepositCapHook.VaultDepositCapSet(address(concreteStandardVault), VAULT_CAP, newCap);

        vm.prank(hookOwner);
        hook.setVaultDepositCap(address(concreteStandardVault), newCap);

        assertEq(hook.getUserDepositCap(address(concreteStandardVault)), newCap);
    }

    function test_setVaultDepositCap_reverts() public {
        //test non-owner reverts
        vm.prank(alice);
        vm.expectRevert();
        hook.setVaultDepositCap(address(concreteStandardVault), 2000 ether);

        //test zero address reverts
        vm.prank(hookOwner);
        vm.expectRevert(abi.encodeWithSelector(UserDepositCapHook.ZeroAddress.selector));
        hook.setVaultDepositCap(address(0), 1000 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Whitelist Management Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_whitelistUsers_addMultipleUsers() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        // Verify none are whitelisted initially
        assertFalse(hook.isWhitelisted(alice));
        assertFalse(hook.isWhitelisted(bob));
        assertFalse(hook.isWhitelisted(charlie));

        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Verify all are whitelisted
        assertTrue(hook.isWhitelisted(alice));
        assertTrue(hook.isWhitelisted(bob));
        assertTrue(hook.isWhitelisted(charlie));
    }

    function test_whitelistUsers_emitsEvents() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.expectEmit(true, true, true, true);
        emit WhitelistSet(alice, true);
        vm.expectEmit(true, true, true, true);
        emit WhitelistSet(bob, true);

        vm.prank(hookOwner);
        hook.whitelistUsers(users);
    }

    function test_whitelistUsers_revertsNonOwner() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(alice);
        vm.expectRevert();
        hook.whitelistUsers(users);
    }

    function test_unWhitelistUsers_removeMultipleUsers() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        // First whitelist them
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        assertTrue(hook.isWhitelisted(alice));
        assertTrue(hook.isWhitelisted(bob));
        assertTrue(hook.isWhitelisted(charlie));

        // Then remove them
        vm.prank(hookOwner);
        hook.unWhitelistUsers(users);

        assertFalse(hook.isWhitelisted(alice));
        assertFalse(hook.isWhitelisted(bob));
        assertFalse(hook.isWhitelisted(charlie));
    }

    function test_unWhitelistUsers_emitsEvents() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        // First whitelist them
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.expectEmit(true, true, true, true);
        emit WhitelistSet(alice, false);
        vm.expectEmit(true, true, true, true);
        emit WhitelistSet(bob, false);

        vm.prank(hookOwner);
        hook.unWhitelistUsers(users);
    }

    function test_unWhitelistUsers_revertsNonOwner() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(alice);
        vm.expectRevert();
        hook.unWhitelistUsers(users);
    }

    function test_whitelistUsers_revertsZeroAddress() public {
        address[] memory users = new address[](1);
        users[0] = address(0);

        vm.prank(hookOwner);
        vm.expectRevert(abi.encodeWithSelector(UserDepositCapHook.ZeroAddress.selector));
        hook.whitelistUsers(users);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Deposit Tests - Whitelist Enforcement (Extra tests beyond UserDepositCapHook)
    // ═════════════════════════════════════════════════════════════════════════════

    function test_deposit_revertsWhenNotWhitelisted() public {
        // Alice is not whitelisted
        assertFalse(hook.isWhitelisted(alice));

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);

        // Should revert with NotWhitelisted
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, alice));
        concreteStandardVault.deposit(100 ether, alice);
        vm.stopPrank();
    }

    function test_deposit_succeedsWhenWhitelisted() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.deposit(500 ether, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), 500 ether);
    }

    function test_deposit_withinVaultCap() public {
        // Whitelist alice first
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);

        //test deposit within cap succeeds
        concreteStandardVault.deposit(VAULT_CAP, alice);

        assertEq(concreteStandardVault.balanceOf(alice), VAULT_CAP);
        vm.stopPrank();
    }

    function test_deposit_exceedsVaultCap() public {
        // Whitelist alice first
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP + 1);

        // Should revert with cap exceeded
        vm.expectRevert(
            abi.encodeWithSelector(
                UserDepositCapHook.UserDepositLimitExceeded.selector, alice, VAULT_CAP + 1, VAULT_CAP
            )
        );
        concreteStandardVault.deposit(VAULT_CAP + 1, alice);
        vm.stopPrank();
    }

    function test_deposit_multipleDepositsWithinCap() public {
        // Whitelist alice first
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);

        // First deposit
        concreteStandardVault.deposit(500 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 500 ether);

        // Second deposit - should succeed
        concreteStandardVault.deposit(500 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), VAULT_CAP);
        vm.stopPrank();
    }

    function test_deposit_multipleDepositsExceedCap() public {
        // Whitelist alice first
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP + 1);

        // First deposit
        concreteStandardVault.deposit(500 ether, alice);

        // Second deposit - should revert
        vm.expectRevert(
            abi.encodeWithSelector(UserDepositCapHook.UserDepositLimitExceeded.selector, alice, 1001 ether, VAULT_CAP)
        );
        concreteStandardVault.deposit(501 ether, alice);
        vm.stopPrank();
    }

    function test_deposit_removedFromWhitelistCannotDeposit() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Alice makes a deposit
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(500 ether, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), 500 ether);

        // Remove alice from whitelist
        vm.prank(hookOwner);
        hook.unWhitelistUsers(users);

        // Alice tries to deposit more - should fail
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, alice));
        concreteStandardVault.deposit(100 ether, alice);
        vm.stopPrank();
    }

    function test_deposit_nonWhitelistedCannotDepositEvenUnderCap() public {
        // Charlie is not whitelisted but wants to deposit under cap
        vm.startPrank(charlie);
        asset.approve(address(concreteStandardVault), 1 ether);

        // Should revert due to whitelist, not cap
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, charlie));
        concreteStandardVault.deposit(1 ether, charlie);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Mint Tests - Whitelist Enforcement (Extra tests)
    // ═════════════════════════════════════════════════════════════════════════════

    function test_mint_revertsWhenNotWhitelisted() public {
        // Bob is not whitelisted
        assertFalse(hook.isWhitelisted(bob));

        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 100 ether);

        // Should revert with NotWhitelisted
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, bob));
        concreteStandardVault.mint(100 ether, bob);
        vm.stopPrank();
    }

    function test_mint_succeedsWhenWhitelisted() public {
        // Whitelist bob
        address[] memory users = new address[](1);
        users[0] = bob;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.mint(500 ether, bob);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(bob), 500 ether);
    }

    function test_mint_withinVaultCap() public {
        // Whitelist alice first
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);

        // Should succeed
        concreteStandardVault.mint(VAULT_CAP, alice);

        assertEq(concreteStandardVault.balanceOf(alice), VAULT_CAP);
        vm.stopPrank();
    }

    function test_mint_exceedsVaultCap() public {
        // Whitelist alice first
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP + 1);

        // first mint should succeed
        concreteStandardVault.mint(500 ether, alice);

        // second mint should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                UserDepositCapHook.UserDepositLimitExceeded.selector, alice, VAULT_CAP + 500 ether, VAULT_CAP
            )
        );
        concreteStandardVault.mint(VAULT_CAP, alice);
        vm.stopPrank();
    }

    function test_mint_nonWhitelistedCannotMint() public {
        // Dave is not whitelisted
        assertFalse(hook.isWhitelisted(dave));

        vm.startPrank(dave);
        asset.approve(address(concreteStandardVault), 100 ether);

        // Should revert with NotWhitelisted
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, dave));
        concreteStandardVault.mint(100 ether, dave);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // View Function Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_canUserDeposit() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Alice has no deposits yet
        bool canDeposit = hook.canUserDeposit(address(concreteStandardVault), alice, 500 ether);

        assertTrue(canDeposit);

        // Make a deposit
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.deposit(500 ether, alice);
        vm.stopPrank();

        // Check if alice can deposit another 500
        canDeposit = hook.canUserDeposit(address(concreteStandardVault), alice, 500 ether);

        assertTrue(canDeposit);

        // expect revert
        vm.expectRevert();
        hook.canUserDeposit(address(concreteStandardVault), alice, 501 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Multiple Users Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_multipleUsers_sameCapForAll() public {
        // Whitelist alice and bob
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Both users should be able to deposit up to vault cap independently
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, bob);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), VAULT_CAP);
        assertEq(concreteStandardVault.balanceOf(bob), VAULT_CAP);
    }

    function test_multipleUsers_cannotExceedCap() public {
        // Whitelist alice and bob
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Alice deposits up to cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, alice);
        vm.stopPrank();

        // Bob deposits up to cap
        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, bob);
        vm.stopPrank();

        // Alice tries to deposit more - should fail
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UserDepositCapHook.UserDepositLimitExceeded.selector, alice, VAULT_CAP + 1, VAULT_CAP
            )
        );
        concreteStandardVault.deposit(1, alice);
        vm.stopPrank();
    }

    function test_multipleUsers_onlyWhitelistedCanDeposit() public {
        // Whitelist only alice and bob (not charlie or dave)
        address[] memory whitelistedUsers = new address[](2);
        whitelistedUsers[0] = alice;
        whitelistedUsers[1] = bob;

        vm.prank(hookOwner);
        hook.whitelistUsers(whitelistedUsers);

        // Alice deposits - should succeed
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.deposit(500 ether, alice);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(alice), 500 ether);

        // Bob deposits - should succeed
        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.deposit(500 ether, bob);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(bob), 500 ether);

        // Charlie (not whitelisted) tries to deposit - should fail
        vm.startPrank(charlie);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, charlie));
        concreteStandardVault.deposit(100 ether, charlie);
        vm.stopPrank();

        // Dave (not whitelisted) tries to deposit - should fail
        vm.startPrank(dave);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, dave));
        concreteStandardVault.deposit(100 ether, dave);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Withdrawal Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_withdraw_allowedRegardlessOfCap() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Alice deposits up to cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, alice);

        // Alice withdraws some funds
        concreteStandardVault.withdraw(500 ether, alice, alice);

        assertEq(concreteStandardVault.balanceOf(alice), 500 ether);
        vm.stopPrank();
    }

    function test_withdraw_worksEvenIfRemovedFromWhitelist() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, alice);
        vm.stopPrank();

        // Remove alice from whitelist
        vm.prank(hookOwner);
        hook.unWhitelistUsers(users);

        // Alice should still be able to withdraw
        vm.startPrank(alice);
        concreteStandardVault.withdraw(500 ether, alice, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), 500 ether);
    }

    function test_depositAfterWithdraw_respectsCap() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Alice deposits up to cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, alice);

        // Alice withdraws 500
        concreteStandardVault.withdraw(500 ether, alice, alice);

        // Alice can now deposit 500 more (back to cap)
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.deposit(500 ether, alice);

        assertEq(concreteStandardVault.balanceOf(alice), VAULT_CAP);
        vm.stopPrank();
    }

    function test_redeem_worksEvenIfNotWhitelisted() public {
        // Whitelist bob
        address[] memory users = new address[](1);
        users[0] = bob;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // Bob mints
        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.mint(500 ether, bob);
        vm.stopPrank();

        // Remove bob from whitelist
        vm.prank(hookOwner);
        hook.unWhitelistUsers(users);

        // Bob should still be able to redeem
        vm.startPrank(bob);
        concreteStandardVault.redeem(250 ether, bob, bob);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(bob), 250 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Integration Tests - Complex Scenarios
    // ═════════════════════════════════════════════════════════════════════════════

    function test_integration_batchWhitelistAndDeposits() public {
        // Batch whitelist multiple users
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = dave;

        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // All make deposits
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 200 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(200 ether, alice);

        vm.prank(bob);
        asset.approve(address(concreteStandardVault), 300 ether);
        vm.prank(bob);
        concreteStandardVault.deposit(300 ether, bob);

        vm.prank(charlie);
        asset.approve(address(concreteStandardVault), 150 ether);
        vm.prank(charlie);
        concreteStandardVault.deposit(150 ether, charlie);

        vm.prank(dave);
        asset.approve(address(concreteStandardVault), 250 ether);
        vm.prank(dave);
        concreteStandardVault.deposit(250 ether, dave);

        // Verify all deposits
        assertEq(concreteStandardVault.balanceOf(alice), 200 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 300 ether);
        assertEq(concreteStandardVault.balanceOf(charlie), 150 ether);
        assertEq(concreteStandardVault.balanceOf(dave), 250 ether);
    }

    function test_integration_partialBatchRemove() public {
        // Whitelist all users
        address[] memory allUsers = new address[](4);
        allUsers[0] = alice;
        allUsers[1] = bob;
        allUsers[2] = charlie;
        allUsers[3] = dave;

        vm.prank(hookOwner);
        hook.whitelistUsers(allUsers);

        // All make deposits
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 200 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(200 ether, alice);

        vm.prank(bob);
        asset.approve(address(concreteStandardVault), 300 ether);
        vm.prank(bob);
        concreteStandardVault.deposit(300 ether, bob);

        // Remove alice and charlie only
        address[] memory usersToRemove = new address[](2);
        usersToRemove[0] = alice;
        usersToRemove[1] = charlie;

        vm.prank(hookOwner);
        hook.unWhitelistUsers(usersToRemove);

        // Verify whitelist status
        assertFalse(hook.isWhitelisted(alice));
        assertTrue(hook.isWhitelisted(bob));
        assertFalse(hook.isWhitelisted(charlie));
        assertTrue(hook.isWhitelisted(dave));

        // Alice cannot deposit anymore
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, alice));
        concreteStandardVault.deposit(100 ether, alice);

        // Bob can still deposit
        vm.prank(bob);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(bob);
        concreteStandardVault.deposit(100 ether, bob);
        assertEq(concreteStandardVault.balanceOf(bob), 400 ether);

        // Dave can deposit (still whitelisted)
        vm.prank(dave);
        asset.approve(address(concreteStandardVault), 400 ether);
        vm.prank(dave);
        concreteStandardVault.deposit(400 ether, dave);
        assertEq(concreteStandardVault.balanceOf(dave), 400 ether);
    }

    function test_integration_fullLifecycle() public {
        // 1. Batch whitelist users
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // 2. All whitelisted users deposit
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 300 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(300 ether, alice);

        vm.prank(bob);
        asset.approve(address(concreteStandardVault), 400 ether);
        vm.prank(bob);
        concreteStandardVault.deposit(400 ether, bob);

        vm.prank(charlie);
        asset.approve(address(concreteStandardVault), 200 ether);
        vm.prank(charlie);
        concreteStandardVault.deposit(200 ether, charlie);

        // 3. Remove charlie from whitelist
        address[] memory removeList = new address[](1);
        removeList[0] = charlie;
        vm.prank(hookOwner);
        hook.unWhitelistUsers(removeList);

        // 4. Charlie cannot deposit more
        vm.prank(charlie);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, charlie));
        concreteStandardVault.deposit(100 ether, charlie);

        // 5. But charlie can still withdraw
        vm.prank(charlie);
        concreteStandardVault.withdraw(100 ether, charlie, charlie);
        assertEq(concreteStandardVault.balanceOf(charlie), 100 ether);

        // 6. Alice and bob can still deposit (within cap)
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(100 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 400 ether);
    }

    function test_integration_readdToWhitelistAfterRemoval() public {
        // 1. Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(hookOwner);
        hook.whitelistUsers(users);

        // 2. Alice deposits
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 300 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(300 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 300 ether);

        // 3. Remove alice from whitelist
        vm.prank(hookOwner);
        hook.unWhitelistUsers(users);
        assertFalse(hook.isWhitelisted(alice));

        // 4. Alice cannot deposit
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WhitelistUserDepositHook.NotWhitelisted.selector, alice));
        concreteStandardVault.deposit(100 ether, alice);

        // 5. Re-add alice to whitelist
        vm.prank(hookOwner);
        hook.whitelistUsers(users);
        assertTrue(hook.isWhitelisted(alice));

        // 6. Alice can deposit again (within cap)
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 400 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(400 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 700 ether);
    }
}

