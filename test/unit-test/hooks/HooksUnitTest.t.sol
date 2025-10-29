// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {StandardHookV1Mock} from "../../mock/StandardHookV1.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {HooksLibV1} from "../../../src/lib/Hooks.sol";

// library HooksLibV1 {

//     uint8 constant PRE_DEPOSIT = 1;
//     uint8 constant POST_DEPOSIT = 2;
//     uint8 constant PRE_MINT = 3;
//     uint8 constant POST_MINT = 4;
//     uint8 constant PRE_WITHDRAW = 5;
//     uint8 constant POST_WITHDRAW = 6;
//     uint8 constant PRE_REDEEM = 7;
//     uint8 constant POST_REDEEM = 8;

//     uint8 constant PRE_ADD_STRATEGY = 9;
//     uint8 constant PRE_REMOVE_STRATEGY = 10;

//     /// @dev Checks if a specific flag is set in the Hooks struct
//     /// @param h The Hooks storage reference
//     /// @param flagIndex The flag index to check (0-95)
//     /// @return True if the flag is set, false otherwise
//     function flagIsSet(Hooks storage h, uint8 flagIndex) internal view returns (bool) {
//         if(flagIndex >= 96) return false;
//         return (uint96(h.flags) & (1 << flagIndex)) != 0;
//     }
// contract StandardHookV1Mock is IHook {

//     error NotImplemented();
//     error DepositLimitExceeded(uint256 assets, uint256 depositLimit);

//     uint256 public depositLimit;

//     constructor(uint256 _depositLimit) {
//         depositLimit = _depositLimit;
//     }

//     // USER ACTION HOOKS

//     function preDeposit(address sender, uint256 assets, address receiver, uint256 totalAssets) external {
//         if(assets > depositLimit) revert DepositLimitExceeded(assets, depositLimit);
//     }

//     function preMint(address sender, uint256 shares, address receiver, uint256 totalAssets) external {
//         // call the sender
//         revert NotImplemented();
//     }

//     function preWithdraw(address sender, uint256 assets, address receiver, address owner, uint256 totalAssets) external {
//         // check sender is owner
//         if(sender != owner) revert NotOwner();
//     }

//     function preRedeem(address sender, uint256 shares, address receiver, address owner, uint256 totalAssets) external {
//         // check sender is owner
//         if(sender != owner) revert NotOwner();
//     }

//     function postDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external {
//         // not implemented
//         revert NotImplemented();
//     }

//     function postMint(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external {
//         // check deposit limit
//         if(assets > depositLimit) revert DepositLimitExceeded(assets, depositLimit);
//     }

//     function postWithdraw(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external {
//         // not implemented
//         revert NotImplemented();
//     }

//     function postRedeem(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external {
//         // not implemented
//         revert NotImplemented();
//     }

// }

contract HooksUnitTest is ConcreteStandardVaultImplBaseSetup {
    address alice;
    address bob;
    uint256 depositLimit;
    StandardHookV1Mock mockHook;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();
        depositLimit = 1 ether;
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        mockHook = new StandardHookV1Mock(depositLimit);
        // mint some funds to alice
        asset.mint(alice, 10 ether);
    }

    function set_flag(uint8 flag) public pure returns (uint96) {
        return uint96(1 << flag);
    }

    // test pre-deposit hook
    function test_preDeposit_withHooks() public {
        uint96 flags = set_flag(HooksLibV1.PRE_DEPOSIT);
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
    }

    function test_preDeposit_withHooks_fail() public {
        uint96 flags = set_flag(HooksLibV1.PRE_DEPOSIT);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 10 ether);
        // deposit some assets to alice
        // expect revert DepositLimitExceeded
        vm.expectRevert(
            abi.encodeWithSelector(StandardHookV1Mock.DepositLimitExceeded.selector, 10 ether, depositLimit)
        );
        concreteStandardVault.deposit(10 ether, alice);
        vm.stopPrank();
    }

    function test_postMint_withHooks() public {
        uint96 flags = set_flag(HooksLibV1.POST_MINT);
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
        uint96 flags = set_flag(HooksLibV1.POST_MINT);
        Hooks memory hooks = Hooks({target: address(mockHook), flags: flags});
        // imposter the vault manager
        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
        vm.startPrank(alice);
        // approve the vault to spend the assets
        asset.approve(address(concreteStandardVault), 10 ether);
        // deposit some assets to alice
        // expect revert DepositLimitExceeded
        vm.expectRevert(
            abi.encodeWithSelector(StandardHookV1Mock.DepositLimitExceeded.selector, 10 ether, depositLimit)
        );
        concreteStandardVault.mint(10 ether, alice);
        vm.stopPrank();
    }

    function test_preWithdraw_withHooks() public {
        uint96 flags = set_flag(HooksLibV1.PRE_WITHDRAW);
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
        uint96 flags = set_flag(HooksLibV1.PRE_WITHDRAW);
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
        vm.expectRevert(abi.encodeWithSelector(StandardHookV1Mock.NotOwner.selector));
        concreteStandardVault.withdraw(1 ether, alice, alice);
        vm.stopPrank();
    }

    function test_preRedeem_withHooks() public {
        uint96 flags = set_flag(HooksLibV1.PRE_REDEEM);
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
        uint96 flags = set_flag(HooksLibV1.PRE_REDEEM);
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
        vm.expectRevert(abi.encodeWithSelector(StandardHookV1Mock.NotOwner.selector));
        concreteStandardVault.redeem(1 ether, alice, alice);
        vm.stopPrank();
    }
}
