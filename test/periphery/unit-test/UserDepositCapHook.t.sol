// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {BaseHook} from "../../../src/periphery/hooks/BaseHook.sol";
import {UserDepositCapHook} from "../../../src/periphery/hooks/UserDepositCapHook.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {HooksLibV2} from "../../../src/lib/Hooks.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

contract UserDepositCapHookTest is ConcreteStandardVaultImplBaseSetup {
    UserDepositCapHook public hook;

    address alice;
    address bob;
    address charlie;
    address hookOwner;

    uint256 constant VAULT_CAP = 1000 ether;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();

        // Setup test accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        hookOwner = makeAddr("hookOwner");

        // Deploy the hook as an ERC-1167 clone of a locked implementation.
        hook = _deployHook(hookOwner, address(concreteStandardVault));

        // Configure the vault's deposit cap
        vm.prank(hookOwner);
        hook.setDepositCap(VAULT_CAP);

        // Mint assets to test users
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);
        asset.mint(charlie, 10000 ether);

        // Setup hooks on vault
        uint96 flags = uint96(1 << HooksLibV2.PRE_DEPOSIT) | uint96(1 << HooksLibV2.PRE_MINT);
        Hooks memory hooks = Hooks({target: address(hook), flags: flags});

        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
    }

    function set_flag(uint8 flag) public pure returns (uint96) {
        return uint96(1 << flag);
    }

    /// @dev Deploys a locked implementation, clones it (ClonesWithImmutableArgs) and initializes the clone.
    function _deployHook(address owner_, address vault_) internal returns (UserDepositCapHook h) {
        UserDepositCapHook impl = new UserDepositCapHook();
        // Immutable args mirror the factory layout: [factory (20)][vault (20)]. This test
        // contract acts as the factory authorized to initialize the clone.
        h = UserDepositCapHook(ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), vault_)));
        h.initialize(owner_);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Initializer Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_init_noDefaultCap() public {
        UserDepositCapHook newHook = _deployHook(hookOwner, address(concreteStandardVault));
        assertEq(newHook.getUserDepositCap(), 0);
        assertEq(newHook.VAULT(), address(concreteStandardVault));
    }

    function test_init_revertsInvalidOwner() public {
        UserDepositCapHook impl = new UserDepositCapHook();
        UserDepositCapHook newHook = UserDepositCapHook(
            ClonesWithImmutableArgs.clone(
                address(impl), abi.encodePacked(address(this), address(concreteStandardVault))
            )
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        newHook.initialize(address(0));
    }

    function test_init_revertsWhenCallerNotFactory() public {
        UserDepositCapHook impl = new UserDepositCapHook();
        // Embed a factory other than this test contract; a non-factory caller must not be able
        // to initialize the clone (clone-init front-running protection).
        UserDepositCapHook newHook = UserDepositCapHook(
            ClonesWithImmutableArgs.clone(
                address(impl), abi.encodePacked(makeAddr("otherFactory"), address(concreteStandardVault))
            )
        );
        vm.expectRevert(BaseHook.NotFactory.selector);
        newHook.initialize(hookOwner);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Set Vault Deposit Cap Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_setDepositCap() public {
        uint256 newCap = 5000 ether;

        vm.expectEmit(true, true, true, true);
        emit UserDepositCapHook.DepositCapSet(VAULT_CAP, newCap);

        vm.prank(hookOwner);
        hook.setDepositCap(newCap);

        assertEq(hook.getUserDepositCap(), newCap);
    }

    function test_setDepositCap_updateExisting() public {
        uint256 newCap = 2000 ether;

        vm.expectEmit(true, true, true, true);
        emit UserDepositCapHook.DepositCapSet(VAULT_CAP, newCap);

        vm.prank(hookOwner);
        hook.setDepositCap(newCap);

        assertEq(hook.getUserDepositCap(), newCap);
    }

    function test_setDepositCap_reverts() public {
        //test non-owner reverts
        vm.prank(alice);
        vm.expectRevert();
        hook.setDepositCap(2000 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Deposit Tests - Vault Cap
    // ═════════════════════════════════════════════════════════════════════════════

    function test_deposit_withinVaultCap() public {
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);

        //test deposit within cap succeeds
        concreteStandardVault.deposit(VAULT_CAP, alice);

        assertEq(concreteStandardVault.balanceOf(alice), VAULT_CAP);
        vm.stopPrank();
    }

    function test_deposit_exceedsVaultCap() public {
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP + 1);

        // Should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                UserDepositCapHook.UserDepositLimitExceeded.selector, alice, VAULT_CAP + 1, VAULT_CAP
            )
        );
        concreteStandardVault.deposit(VAULT_CAP + 1, alice);
        vm.stopPrank();
    }

    function test_deposit_multipleDepositsWithinCap() public {
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

    // ═════════════════════════════════════════════════════════════════════════════
    // Mint Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_mint_withinVaultCap() public {
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);

        // Should succeed
        concreteStandardVault.mint(VAULT_CAP, alice);

        assertEq(concreteStandardVault.balanceOf(alice), VAULT_CAP);
        vm.stopPrank();
    }

    function test_mint_exceedsVaultCap() public {
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

    // ═════════════════════════════════════════════════════════════════════════════
    // View Function Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_canUserDeposit() public {
        // Alice has no deposits yet
        bool canDeposit = hook.canUserDeposit(alice, 500 ether);

        assertTrue(canDeposit);

        // Make a deposit
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 500 ether);
        concreteStandardVault.deposit(500 ether, alice);
        vm.stopPrank();

        // Check if alice can deposit another 500
        canDeposit = hook.canUserDeposit(alice, 500 ether);

        assertTrue(canDeposit);

        // expect revert
        vm.expectRevert();
        hook.canUserDeposit(alice, 501 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Multiple Users Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_multipleUsers_sameCapForAll() public {
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

    // ═════════════════════════════════════════════════════════════════════════════
    // Withdrawal Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_withdraw_allowedRegardlessOfCap() public {
        // Alice deposits up to cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), VAULT_CAP);
        concreteStandardVault.deposit(VAULT_CAP, alice);

        // Alice withdraws some funds
        concreteStandardVault.withdraw(500 ether, alice, alice);

        assertEq(concreteStandardVault.balanceOf(alice), 500 ether);
        vm.stopPrank();
    }

    function test_depositAfterWithdraw_respectsCap() public {
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

    // ═════════════════════════════════════════════════════════════════════════════
    // Infinite Deposit Cap Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_setDepositCap_infinite() public {
        vm.prank(hookOwner);
        hook.setDepositCap(type(uint256).max);
        assertEq(hook.getUserDepositCap(), type(uint256).max);
    }

    function test_deposit_infiniteCap_allowsAnyAmount() public {
        vm.prank(hookOwner);
        hook.setDepositCap(type(uint256).max);

        uint256 largeAmount = 5000 ether;
        asset.mint(alice, largeAmount);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), largeAmount);
        concreteStandardVault.deposit(largeAmount, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), largeAmount);
    }

    function test_deposit_infiniteCap_multipleDeposits() public {
        vm.prank(hookOwner);
        hook.setDepositCap(type(uint256).max);

        uint256 amount = 3000 ether;
        asset.mint(alice, amount * 3);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), amount * 3);
        concreteStandardVault.deposit(amount, alice);
        concreteStandardVault.deposit(amount, alice);
        concreteStandardVault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), amount * 3);
    }

    function test_mint_infiniteCap_allowsAnyAmount() public {
        vm.prank(hookOwner);
        hook.setDepositCap(type(uint256).max);

        uint256 largeAmount = 5000 ether;
        asset.mint(alice, largeAmount);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), largeAmount);
        concreteStandardVault.mint(largeAmount, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), largeAmount);
    }

    function test_canUserDeposit_infiniteCap() public {
        vm.prank(hookOwner);
        hook.setDepositCap(type(uint256).max);

        bool canDeposit = hook.canUserDeposit(alice, 9999 ether);
        assertTrue(canDeposit);
    }
}
