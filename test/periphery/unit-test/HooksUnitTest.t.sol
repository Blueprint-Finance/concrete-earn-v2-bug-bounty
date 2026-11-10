// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {StandardHookMock} from "../../mock/StandardHookMock.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {HooksLibV2} from "../../../src/lib/Hooks.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

contract HooksUnitTest is ConcreteStandardVaultImplBaseSetup {
    address alice;
    address bob;
    uint256 depositLimit;
    StandardHookMock mockHook;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();
        depositLimit = 1 ether;
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        mockHook = new StandardHookMock(address(concreteStandardVault), depositLimit);
        // mint some funds to alice
        asset.mint(alice, 10 ether);
    }

    function set_flag(uint8 flag) public pure returns (uint96) {
        return uint96(1 << flag);
    }

    // test pre-deposit hook
    function test_preDeposit_withHooks() public {
        uint96 flags = set_flag(HooksLibV2.PRE_DEPOSIT);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        // deposit some assets to alice
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 1 ether);
        // deposit some assets to alice
        concreteStandardVault.deposit(1 ether, alice);
        vm.stopPrank();
        // expect the hook to be called
        assertEq(mockHook.depositLimit(), depositLimit);
        assertEq(concreteStandardVault.balanceOf(alice), 1 ether);
        // get the list of deployed hoooks
        Hooks memory deployedHooks = concreteStandardVault.getHooks();
        assertEq(deployedHooks.target, address(mockHook));
    }

    function test_preDeposit_withHooks_fail() public {
        uint96 flags = set_flag(HooksLibV2.PRE_DEPOSIT);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 10 ether);
        // deposit some assets to alice
        // expect revert DepositLimitExceeded
        vm.expectRevert(abi.encodeWithSelector(StandardHookMock.DepositLimitExceeded.selector, 10 ether, depositLimit));
        concreteStandardVault.deposit(10 ether, alice);
        vm.stopPrank();
    }

    function test_postMint_withHooks() public {
        uint96 flags = set_flag(HooksLibV2.POST_MINT);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        // mint some assets to alice
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 1 ether);
        // deposit some assets to alice
        concreteStandardVault.mint(1 ether, alice);
        vm.stopPrank();
    }

    function test_postMint_withHooks_fail() public {
        uint96 flags = set_flag(HooksLibV2.POST_MINT);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 10 ether);
        // deposit some assets to alice
        // expect revert DepositLimitExceeded
        vm.expectRevert(abi.encodeWithSelector(StandardHookMock.DepositLimitExceeded.selector, 10 ether, depositLimit));
        concreteStandardVault.mint(10 ether, alice);
        vm.stopPrank();
    }

    function test_preWithdraw_withHooks() public {
        uint96 flags = set_flag(HooksLibV2.PRE_WITHDRAW);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 1 ether);
        // deposit some assets to alice
        concreteStandardVault.deposit(1 ether, alice);
        // withdraw some assets from alice
        concreteStandardVault.withdraw(1 ether, alice, alice);
        vm.stopPrank();
        // expect the hook to be called
    }

    function test_preWithdraw_withHooks_fail() public {
        uint96 flags = set_flag(HooksLibV2.PRE_WITHDRAW);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 1 ether);
        // deposit some assets to alice
        concreteStandardVault.deposit(1 ether, alice);
        // approve bob to spend the assets
        concreteStandardVault.approve(bob, 1 ether);
        // withdraw some assets from alice
        // expect revert NotOwner
        vm.stopPrank();

        vm.startPrank(bob);
        // withdraw some assets from alice
        // expect revert NotOwner
        vm.expectRevert(abi.encodeWithSelector(StandardHookMock.NotOwner.selector));
        concreteStandardVault.withdraw(1 ether, alice, alice);
        vm.stopPrank();
    }

    function test_preRedeem_withHooks() public {
        uint96 flags = set_flag(HooksLibV2.PRE_REDEEM);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 1 ether);
        // deposit some assets to alice
        concreteStandardVault.deposit(1 ether, alice);
        // redeem some assets from alice
        concreteStandardVault.redeem(1 ether, alice, alice);
        vm.stopPrank();
        // expect the hook to be called
    }

    function test_preRedeem_withHooks_fail() public {
        uint96 flags = set_flag(HooksLibV2.PRE_REDEEM);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 1 ether);
        // deposit some assets to alice
        concreteStandardVault.deposit(1 ether, alice);
        // approve bob to spend the assets
        concreteStandardVault.approve(bob, 1 ether);
        // redeem some assets from alice
        // expect revert NotOwner
        vm.stopPrank();

        vm.startPrank(bob);
        // redeem some assets from alice
        // expect revert NotOwner
        vm.expectRevert(abi.encodeWithSelector(StandardHookMock.NotOwner.selector));
        concreteStandardVault.redeem(1 ether, alice, alice);
        vm.stopPrank();
    }

    // test pre-transfer hook
    function test_preTransfer_withHooks() public {
        uint96 flags = set_flag(HooksLibV2.PRE_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1 ether);
        concreteStandardVault.deposit(1 ether, alice);
        concreteStandardVault.transfer(bob, 1 ether);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(bob), 1 ether);
    }

    function test_preTransfer_withHooks_fail() public {
        uint96 flags = set_flag(HooksLibV2.PRE_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1 ether);
        concreteStandardVault.deposit(1 ether, alice);
        concreteStandardVault.approve(bob, 1 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(StandardHookMock.NotOwner.selector));
        concreteStandardVault.transferFrom(alice, bob, 1 ether);
        vm.stopPrank();
    }

    // test post-transfer hook
    function test_postTransfer_withHooks() public {
        uint96 flags = set_flag(HooksLibV2.POST_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1 ether);
        concreteStandardVault.deposit(1 ether, alice);
        concreteStandardVault.transfer(bob, 0.5 ether);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(bob), 0.5 ether);
    }

    function test_postTransfer_withHooks_fail() public {
        uint96 flags = set_flag(HooksLibV2.POST_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 10 ether);
        concreteStandardVault.deposit(10 ether, alice);
        vm.expectRevert(abi.encodeWithSelector(StandardHookMock.TransferLimitExceeded.selector, 10 ether, depositLimit));
        concreteStandardVault.transfer(bob, 10 ether);
        vm.stopPrank();
    }

    // test transfer hooks coexist with deposit hooks
    function test_transferAndDepositHooks_coexist() public {
        uint96 flags = set_flag(HooksLibV2.PRE_DEPOSIT) | set_flag(HooksLibV2.PRE_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1 ether);
        // deposit triggers preDeposit (not preTransfer) — within limit, succeeds
        concreteStandardVault.deposit(1 ether, alice);
        // transfer triggers preTransfer (not preDeposit) — sender == from, succeeds
        concreteStandardVault.transfer(bob, 0.5 ether);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(alice), 0.5 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 0.5 ether);
    }

    // test transfer to self
    function test_preTransfer_transferToSelf() public {
        uint96 flags = set_flag(HooksLibV2.PRE_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1 ether);
        concreteStandardVault.deposit(1 ether, alice);
        // transfer to self — hook fires (from and to are non-zero)
        concreteStandardVault.transfer(alice, 0.5 ether);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(alice), 1 ether);
    }

    // test transfer of zero shares
    function test_preTransfer_zeroAmount() public {
        uint96 flags = set_flag(HooksLibV2.PRE_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1 ether);
        concreteStandardVault.deposit(1 ether, alice);
        concreteStandardVault.transfer(bob, 0);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(alice), 1 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 0);
    }

    // test transfer hooks are not called on mint (from == address(0))
    function test_preTransfer_notCalledOnMint() public {
        uint96 flags = set_flag(HooksLibV2.PRE_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        // deposit triggers _mint → _update(address(0), alice, shares)
        // if the hook fired, it would revert NotOwner (sender=alice != from=address(0))
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1 ether);
        concreteStandardVault.deposit(1 ether, alice);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(alice), 1 ether);
    }

    // test transfer hooks are not called on burn (to == address(0))
    function test_postTransfer_notCalledOnBurn() public {
        uint96 flags = set_flag(HooksLibV2.POST_TRANSFER);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 10 ether);
        concreteStandardVault.deposit(10 ether, alice);
        // withdraw triggers _burn → _update(alice, address(0), shares)
        // if the hook fired, it would revert TransferLimitExceeded (10 ether > 1 ether limit)
        concreteStandardVault.withdraw(10 ether, alice, alice);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(alice), 0);
    }

    function testPausePreventsSetHooks() public {
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        uint96 flags = set_flag(HooksLibV2.PRE_DEPOSIT);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});

        vm.prank(hookManager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.setHooks(hooks);
    }
}
