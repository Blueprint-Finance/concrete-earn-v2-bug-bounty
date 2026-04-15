// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks, IHook} from "../../../src/interface/IHook.sol";
import {HookContainer} from "../../../src/periphery/hooks/HookContainer.sol";
import {WhitelistUserDepositHook} from "../../../src/periphery/hooks/WhitelistUserDepositHook.sol";
import {UserDepositCapHook} from "../../../src/periphery/hooks/UserDepositCapHook.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {HooksLibV1} from "../../../src/lib/Hooks.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin-contracts/access/extensions/IAccessControlEnumerable.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

/**
 * @title MockWhitelistHook
 * @notice Simple whitelist hook for testing that doesn't rely on msg.sender being the vault
 */
contract MockWhitelistHook is IHook, Ownable {
    error NotWhitelisted(address user);
    error ZeroAddress();

    event WhitelistSet(address indexed user, bool indexed isWhitelisted);

    mapping(address user => bool isWhitelisted) public whitelist;

    constructor(address _owner) Ownable(_owner) {}

    function whitelistUsers(address[] memory users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert ZeroAddress();
            whitelist[users[i]] = true;
            emit WhitelistSet(users[i], true);
        }
    }

    function unWhitelistUsers(address[] memory users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = false;
            emit WhitelistSet(users[i], false);
        }
    }

    function isWhitelisted(address user) external view returns (bool) {
        return whitelist[user];
    }

    // Check sender parameter (the depositor), not msg.sender
    function preDeposit(address sender, uint256, address, uint256) external view {
        if (!whitelist[sender]) revert NotWhitelisted(sender);
    }

    function preMint(address sender, uint256, address, uint256) external view {
        if (!whitelist[sender]) revert NotWhitelisted(sender);
    }

    function preWithdraw(address, uint256, address, address, uint256) external pure {}
    function preRedeem(address, uint256, address, address, uint256) external pure {}
    function postDeposit(address, uint256, uint256, address, uint256) external pure {}
    function postMint(address, uint256, uint256, address, uint256) external pure {}
    function postWithdraw(address, uint256, uint256, address, uint256) external pure {}
    function postRedeem(address, uint256, uint256, address, uint256) external pure {}
}

/**
 * @title MockDepositCapHook
 * @notice Simple deposit cap hook for testing that uses receiver balance directly
 * @dev This mock uses a configurable vault address instead of relying on msg.sender
 */
contract MockDepositCapHook is IHook, Ownable {
    error UserDepositLimitExceeded(address user, uint256 attemptedTotal, uint256 limit);
    error ZeroAddress();

    event DepositCapSet(uint256 oldCap, uint256 newCap);
    event VaultSet(address vault);

    uint256 public depositCap;
    address public vault;

    constructor(address _owner) Ownable(_owner) {}

    function setDepositCap(uint256 _cap) external onlyOwner {
        uint256 oldCap = depositCap;
        depositCap = _cap;
        emit DepositCapSet(oldCap, _cap);
    }

    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
        emit VaultSet(_vault);
    }

    function preDeposit(address, uint256 assets, address receiver, uint256) external view {
        _checkDepositLimit(receiver, assets);
    }

    function preMint(address, uint256 assets, address receiver, uint256) external view {
        // For simplicity, treat shares as assets in this mock
        _checkDepositLimit(receiver, assets);
    }

    function preWithdraw(address, uint256, address, address, uint256) external pure {}
    function preRedeem(address, uint256, address, address, uint256) external pure {}
    function postDeposit(address, uint256, uint256, address, uint256) external pure {}
    function postMint(address, uint256, uint256, address, uint256) external pure {}
    function postWithdraw(address, uint256, uint256, address, uint256) external pure {}
    function postRedeem(address, uint256, uint256, address, uint256) external pure {}

    function _checkDepositLimit(address _receiver, uint256 _additionalAssets) internal view {
        if (vault == address(0)) return; // No vault configured, skip check

        uint256 currentBalance;
        // Try to get balance, but don't fail if vault doesn't support it
        try IVaultBalance(vault).balanceOf(_receiver) returns (uint256 bal) {
            currentBalance = bal;
        } catch {
            currentBalance = 0;
        }

        uint256 newTotal = currentBalance + _additionalAssets;
        if (newTotal > depositCap && depositCap > 0) {
            revert UserDepositLimitExceeded(_receiver, newTotal, depositCap);
        }
    }
}

interface IVaultBalance {
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title HookContainerTest
 * @notice Tests the HookContainer contract combining multiple hooks
 * @dev This test suite verifies that the container correctly forwards calls to multiple hooks
 *      and that all validations from sub-hooks are enforced.
 * @dev Note: Uses mock hooks because the original UserDepositCapHook relies on msg.sender
 *      being the vault, which doesn't work when called through a container.
 */
contract HookContainerTest is ConcreteStandardVaultImplBaseSetup {
    HookContainer public container;
    MockWhitelistHook public whitelistHook;
    MockDepositCapHook public depositCapHook;

    address alice;
    address bob;
    address charlie;
    address dave;
    address containerAdmin;
    address whitelistHookOwner;
    address depositCapHookOwner;

    // Deposit cap for testing
    uint256 constant DEPOSIT_CAP = 500 ether;

    event HookAdded(address indexed hook);
    event HookRemoved(address indexed hook);
    event WhitelistSet(address indexed user, bool indexed isWhitelisted);

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();

        // Setup test accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave = makeAddr("dave");
        containerAdmin = makeAddr("containerAdmin");
        whitelistHookOwner = makeAddr("whitelistHookOwner");
        depositCapHookOwner = makeAddr("depositCapHookOwner");

        // Deploy the hook container
        container = new HookContainer(containerAdmin);

        // Deploy mock hooks (these don't rely on msg.sender being the vault)
        whitelistHook = new MockWhitelistHook(whitelistHookOwner);
        depositCapHook = new MockDepositCapHook(depositCapHookOwner);

        // Grant HOOK_MANAGER_ROLE to containerAdmin
        vm.prank(containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, containerAdmin);

        // Add hooks to container
        vm.startPrank(containerAdmin);
        container.addHook(address(whitelistHook));
        container.addHook(address(depositCapHook));
        vm.stopPrank();

        // Configure deposit cap hook with vault reference and cap
        vm.startPrank(depositCapHookOwner);
        depositCapHook.setVault(address(concreteStandardVault));
        depositCapHook.setDepositCap(DEPOSIT_CAP);
        vm.stopPrank();

        // Mint assets to test users
        asset.mint(alice, 10000 ether);
        asset.mint(bob, 10000 ether);
        asset.mint(charlie, 10000 ether);
        asset.mint(dave, 10000 ether);

        // Setup hooks on vault - using the container
        uint96 flags = uint96(1 << HooksLibV1.PRE_DEPOSIT) | uint96(1 << HooksLibV1.PRE_MINT);
        Hooks memory hooks = Hooks({target: address(container), flags: flags});

        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Constructor Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_constructor_initializesCorrectly() public {
        HookContainer newContainer = new HookContainer(containerAdmin);
        assertEq(newContainer.getHooksCount(), 0);
        assertTrue(newContainer.hasRole(newContainer.DEFAULT_ADMIN_ROLE(), containerAdmin));
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert();
        new HookContainer(address(0));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Enumerable Roles Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_enumerable_getRoleMemberCount_defaultAdmin() public view {
        // Container admin should have DEFAULT_ADMIN_ROLE
        uint256 count = container.getRoleMemberCount(container.DEFAULT_ADMIN_ROLE());
        assertEq(count, 1);
    }

    function test_enumerable_getRoleMember_defaultAdmin() public view {
        // The first (and only) member of DEFAULT_ADMIN_ROLE should be containerAdmin
        address member = container.getRoleMember(container.DEFAULT_ADMIN_ROLE(), 0);
        assertEq(member, containerAdmin);
    }

    function test_enumerable_getRoleMembers_defaultAdmin() public view {
        address[] memory members = container.getRoleMembers(container.DEFAULT_ADMIN_ROLE());
        assertEq(members.length, 1);
        assertEq(members[0], containerAdmin);
    }

    function test_enumerable_getRoleMemberCount_hookManager() public view {
        // Container admin was granted HOOK_MANAGER_ROLE in setUp
        uint256 count = container.getRoleMemberCount(PeripheryRolesLib.HOOK_MANAGER_ROLE);
        assertEq(count, 1);
    }

    function test_enumerable_getRoleMember_hookManager() public view {
        address member = container.getRoleMember(PeripheryRolesLib.HOOK_MANAGER_ROLE, 0);
        assertEq(member, containerAdmin);
    }

    function test_enumerable_getRoleMembers_hookManager() public view {
        address[] memory members = container.getRoleMembers(PeripheryRolesLib.HOOK_MANAGER_ROLE);
        assertEq(members.length, 1);
        assertEq(members[0], containerAdmin);
    }

    function test_enumerable_grantRole_updatesEnumeration() public {
        address newManager = makeAddr("newManager");

        // Initial count
        uint256 initialCount = container.getRoleMemberCount(PeripheryRolesLib.HOOK_MANAGER_ROLE);
        assertEq(initialCount, 1);

        // Grant role to new manager
        vm.prank(containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, newManager);

        // Count should increase
        uint256 newCount = container.getRoleMemberCount(PeripheryRolesLib.HOOK_MANAGER_ROLE);
        assertEq(newCount, 2);

        // Both members should be present
        address[] memory members = container.getRoleMembers(PeripheryRolesLib.HOOK_MANAGER_ROLE);
        assertEq(members.length, 2);
        assertTrue(members[0] == containerAdmin || members[1] == containerAdmin);
        assertTrue(members[0] == newManager || members[1] == newManager);
    }

    function test_enumerable_revokeRole_updatesEnumeration() public {
        address newManager = makeAddr("newManager");

        // Grant role first
        vm.prank(containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, newManager);
        assertEq(container.getRoleMemberCount(PeripheryRolesLib.HOOK_MANAGER_ROLE), 2);

        // Revoke role
        vm.prank(containerAdmin);
        container.revokeRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, newManager);

        // Count should decrease
        assertEq(container.getRoleMemberCount(PeripheryRolesLib.HOOK_MANAGER_ROLE), 1);

        // Only containerAdmin should remain
        address[] memory members = container.getRoleMembers(PeripheryRolesLib.HOOK_MANAGER_ROLE);
        assertEq(members.length, 1);
        assertEq(members[0], containerAdmin);
    }

    function test_enumerable_multipleRoleMembers() public {
        address manager1 = makeAddr("manager1");
        address manager2 = makeAddr("manager2");
        address manager3 = makeAddr("manager3");

        // Grant role to multiple accounts
        vm.startPrank(containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, manager1);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, manager2);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, manager3);
        vm.stopPrank();

        // Should have 4 members total (containerAdmin + 3 new managers)
        uint256 count = container.getRoleMemberCount(PeripheryRolesLib.HOOK_MANAGER_ROLE);
        assertEq(count, 4);

        // All should have the role
        assertTrue(container.hasRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, containerAdmin));
        assertTrue(container.hasRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, manager1));
        assertTrue(container.hasRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, manager2));
        assertTrue(container.hasRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, manager3));
    }

    function test_enumerable_supportsInterface() public view {
        // Should support IAccessControlEnumerable
        assertTrue(container.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        // Should also support IAccessControl
        assertTrue(container.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_peripheryRolesLib_hookManagerRoleConstant() public pure {
        // Verify the role constant is correctly defined
        bytes32 expectedRole = keccak256("HOOK_MANAGER_ROLE");
        assertEq(PeripheryRolesLib.HOOK_MANAGER_ROLE, expectedRole);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Hook Management Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_addHook_success() public {
        HookContainer newContainer = new HookContainer(containerAdmin);

        vm.prank(containerAdmin);
        newContainer.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, containerAdmin);

        address newHook = makeAddr("newHook");

        vm.expectEmit(true, true, true, true);
        emit HookAdded(newHook);

        vm.prank(containerAdmin);
        newContainer.addHook(newHook);

        assertEq(newContainer.getHooksCount(), 1);
        assertTrue(newContainer.isHookRegistered(newHook));
        assertEq(newContainer.getHookAt(0), newHook);
    }

    function test_addHook_revertsZeroAddress() public {
        vm.prank(containerAdmin);
        vm.expectRevert(abi.encodeWithSelector(HookContainer.ZeroAddress.selector));
        container.addHook(address(0));
    }

    function test_addHook_revertsSelfRegistration() public {
        vm.prank(containerAdmin);
        vm.expectRevert(abi.encodeWithSelector(HookContainer.SelfRegistrationNotAllowed.selector));
        container.addHook(address(container));
    }

    function test_addHook_revertsAlreadyRegistered() public {
        vm.prank(containerAdmin);
        vm.expectRevert(abi.encodeWithSelector(HookContainer.HookAlreadyRegistered.selector, address(whitelistHook)));
        container.addHook(address(whitelistHook));
    }

    function test_addHook_revertsMaxHooksExceeded() public {
        HookContainer newContainer = new HookContainer(containerAdmin);

        vm.prank(containerAdmin);
        newContainer.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, containerAdmin);

        uint256 maxHooks = newContainer.MAX_HOOKS();

        // Add MAX_HOOKS hooks
        vm.startPrank(containerAdmin);
        for (uint256 i = 0; i < maxHooks; i++) {
            address hookAddr = address(uint160(i + 100));
            newContainer.addHook(hookAddr);
        }
        vm.stopPrank();

        // Try to add one more
        address extraHook = makeAddr("extraHook");
        vm.prank(containerAdmin);
        vm.expectRevert(abi.encodeWithSelector(HookContainer.MaxHooksExceeded.selector));
        newContainer.addHook(extraHook);
    }

    function test_addHook_revertsUnauthorized() public {
        address unauthorized = makeAddr("unauthorized");
        address newHook = makeAddr("newHook");

        vm.prank(unauthorized);
        vm.expectRevert();
        container.addHook(newHook);
    }

    function test_removeHook_success() public {
        assertEq(container.getHooksCount(), 2);
        assertTrue(container.isHookRegistered(address(whitelistHook)));

        vm.expectEmit(true, true, true, true);
        emit HookRemoved(address(whitelistHook));

        vm.prank(containerAdmin);
        container.removeHook(address(whitelistHook));

        assertEq(container.getHooksCount(), 1);
        assertFalse(container.isHookRegistered(address(whitelistHook)));
    }

    function test_removeHook_revertsNotRegistered() public {
        address unregisteredHook = makeAddr("unregisteredHook");

        vm.prank(containerAdmin);
        vm.expectRevert(abi.encodeWithSelector(HookContainer.HookNotRegistered.selector, unregisteredHook));
        container.removeHook(unregisteredHook);
    }

    function test_removeHook_revertsUnauthorized() public {
        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert();
        container.removeHook(address(whitelistHook));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // View Function Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_getAllHooks() public view {
        address[] memory hooks = container.getAllHooks();
        assertEq(hooks.length, 2);
        assertEq(hooks[0], address(whitelistHook));
        assertEq(hooks[1], address(depositCapHook));
    }

    function test_getHooksCount() public view {
        assertEq(container.getHooksCount(), 2);
    }

    function test_getHookAt() public view {
        assertEq(container.getHookAt(0), address(whitelistHook));
        assertEq(container.getHookAt(1), address(depositCapHook));
    }

    function test_isHookRegistered() public view {
        assertTrue(container.isHookRegistered(address(whitelistHook)));
        assertTrue(container.isHookRegistered(address(depositCapHook)));
        assertFalse(container.isHookRegistered(address(0x1234)));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Combined Hook Validation Tests - Deposit
    // ═════════════════════════════════════════════════════════════════════════════

    function test_deposit_revertsWhenNotWhitelisted() public {
        // Alice is not whitelisted
        assertFalse(whitelistHook.isWhitelisted(alice));

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);

        // Should revert with NotWhitelisted from MockWhitelistHook
        vm.expectRevert(abi.encodeWithSelector(MockWhitelistHook.NotWhitelisted.selector, alice));
        concreteStandardVault.deposit(100 ether, alice);
        vm.stopPrank();
    }

    function test_deposit_succeedsWhenWhitelistedAndUnderCap() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Deposit amount under cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 400 ether);
        concreteStandardVault.deposit(400 ether, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), 400 ether);
    }

    function test_deposit_revertsWhenExceedingCap() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Try to deposit more than the cap (500 ether)
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 600 ether);

        // Should revert with cap exceeded from MockDepositCapHook
        vm.expectRevert(
            abi.encodeWithSelector(MockDepositCapHook.UserDepositLimitExceeded.selector, alice, 600 ether, DEPOSIT_CAP)
        );
        concreteStandardVault.deposit(600 ether, alice);
        vm.stopPrank();
    }

    function test_deposit_atExactCap() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Deposit exactly at the cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), DEPOSIT_CAP);
        concreteStandardVault.deposit(DEPOSIT_CAP, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), DEPOSIT_CAP);
    }

    function test_deposit_multipleDepositsRespectCap() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), DEPOSIT_CAP + 1 ether);

        // First deposit
        concreteStandardVault.deposit(300 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 300 ether);

        // Second deposit within cap
        concreteStandardVault.deposit(200 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), DEPOSIT_CAP);

        // Third deposit should fail (trying to deposit 1 more ether)
        vm.expectRevert(
            abi.encodeWithSelector(MockDepositCapHook.UserDepositLimitExceeded.selector, alice, 501 ether, DEPOSIT_CAP)
        );
        concreteStandardVault.deposit(1 ether, alice);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Combined Hook Validation Tests - Mint
    // ═════════════════════════════════════════════════════════════════════════════

    function test_mint_revertsWhenNotWhitelisted() public {
        // Bob is not whitelisted
        assertFalse(whitelistHook.isWhitelisted(bob));

        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 100 ether);

        // Should revert with NotWhitelisted
        vm.expectRevert(abi.encodeWithSelector(MockWhitelistHook.NotWhitelisted.selector, bob));
        concreteStandardVault.mint(100 ether, bob);
        vm.stopPrank();
    }

    function test_mint_succeedsWhenWhitelistedAndUnderCap() public {
        // Whitelist bob
        address[] memory users = new address[](1);
        users[0] = bob;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 400 ether);
        concreteStandardVault.mint(400 ether, bob);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(bob), 400 ether);
    }

    function test_mint_revertsWhenExceedingCap() public {
        // Whitelist bob
        address[] memory users = new address[](1);
        users[0] = bob;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 600 ether);

        // Should revert with cap exceeded
        vm.expectRevert(
            abi.encodeWithSelector(MockDepositCapHook.UserDepositLimitExceeded.selector, bob, 600 ether, DEPOSIT_CAP)
        );
        concreteStandardVault.mint(600 ether, bob);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Multiple Users Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_multipleUsers_independentCaps() public {
        // Whitelist alice and bob
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Alice deposits up to cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), DEPOSIT_CAP);
        concreteStandardVault.deposit(DEPOSIT_CAP, alice);
        vm.stopPrank();

        // Bob deposits up to cap (independent of alice)
        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), DEPOSIT_CAP);
        concreteStandardVault.deposit(DEPOSIT_CAP, bob);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), DEPOSIT_CAP);
        assertEq(concreteStandardVault.balanceOf(bob), DEPOSIT_CAP);
    }

    function test_multipleUsers_mixedWhitelistStatus() public {
        // Whitelist only alice (not bob, charlie, dave)
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Alice can deposit
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 300 ether);
        concreteStandardVault.deposit(300 ether, alice);
        vm.stopPrank();
        assertEq(concreteStandardVault.balanceOf(alice), 300 ether);

        // Bob cannot deposit (not whitelisted)
        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(MockWhitelistHook.NotWhitelisted.selector, bob));
        concreteStandardVault.deposit(100 ether, bob);
        vm.stopPrank();

        // Charlie cannot deposit (not whitelisted)
        vm.startPrank(charlie);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(MockWhitelistHook.NotWhitelisted.selector, charlie));
        concreteStandardVault.deposit(100 ether, charlie);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Hook Ordering Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_hookOrder_whitelistCheckedFirst() public {
        // Alice is not whitelisted but would pass the deposit cap check
        // The whitelist hook should fail first
        assertFalse(whitelistHook.isWhitelisted(alice));

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);

        // Should revert with whitelist error, not cap error
        vm.expectRevert(abi.encodeWithSelector(MockWhitelistHook.NotWhitelisted.selector, alice));
        concreteStandardVault.deposit(100 ether, alice);
        vm.stopPrank();
    }

    function test_hookOrder_capCheckedAfterWhitelist() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Deposit an amount that passes whitelist but exceeds cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 600 ether);

        // Should revert with cap error (from the second hook)
        vm.expectRevert(
            abi.encodeWithSelector(MockDepositCapHook.UserDepositLimitExceeded.selector, alice, 600 ether, DEPOSIT_CAP)
        );
        concreteStandardVault.deposit(600 ether, alice);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Hook Removal and Re-addition Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_removeHook_changesValidation() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Initially, can't deposit more than cap (500 ether)
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1000 ether);

        vm.expectRevert();
        concreteStandardVault.deposit(600 ether, alice);
        vm.stopPrank();

        // Remove the depositCapHook
        vm.prank(containerAdmin);
        container.removeHook(address(depositCapHook));

        // Now alice can deposit any amount (only whitelist check remains)
        vm.prank(alice);
        concreteStandardVault.deposit(600 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 600 ether);
    }

    function test_removeWhitelistHook_allowsNonWhitelistedDeposits() public {
        // Bob is not whitelisted
        assertFalse(whitelistHook.isWhitelisted(bob));

        // Bob can't deposit initially
        vm.startPrank(bob);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.expectRevert();
        concreteStandardVault.deposit(100 ether, bob);
        vm.stopPrank();

        // Remove the whitelist hook
        vm.prank(containerAdmin);
        container.removeHook(address(whitelistHook));

        // Now bob can deposit (only cap check from depositCapHook)
        vm.prank(bob);
        concreteStandardVault.deposit(100 ether, bob);
        assertEq(concreteStandardVault.balanceOf(bob), 100 ether);
    }

    function test_readdHook_restoresValidation() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Remove cap hook
        vm.prank(containerAdmin);
        container.removeHook(address(depositCapHook));

        // Alice can deposit any amount now
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1000 ether);
        concreteStandardVault.deposit(600 ether, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), 600 ether);

        // Re-add the cap hook
        vm.prank(containerAdmin);
        container.addHook(address(depositCapHook));

        // Alice can't deposit more as she's already over the cap
        vm.startPrank(alice);
        vm.expectRevert();
        concreteStandardVault.deposit(1, alice);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Withdrawal Tests (no hooks blocking)
    // ═════════════════════════════════════════════════════════════════════════════

    function test_withdraw_worksRegardlessOfWhitelist() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), DEPOSIT_CAP);
        concreteStandardVault.deposit(DEPOSIT_CAP, alice);
        vm.stopPrank();

        // Remove alice from whitelist
        vm.prank(whitelistHookOwner);
        whitelistHook.unWhitelistUsers(users);

        // Alice can still withdraw (no pre-withdraw hooks active)
        vm.prank(alice);
        concreteStandardVault.withdraw(200 ether, alice, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 300 ether);
    }

    function test_depositAfterWithdraw_respectsCaps() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // Alice deposits up to cap
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), DEPOSIT_CAP);
        concreteStandardVault.deposit(DEPOSIT_CAP, alice);

        // Alice withdraws some
        concreteStandardVault.withdraw(200 ether, alice, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 300 ether);

        // Alice can deposit back up to cap
        asset.approve(address(concreteStandardVault), 200 ether);
        concreteStandardVault.deposit(200 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), DEPOSIT_CAP);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Integration Tests - Complex Scenarios
    // ═════════════════════════════════════════════════════════════════════════════

    function test_integration_fullLifecycleWithContainer() public {
        // 1. Batch whitelist users
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // 2. All whitelisted users deposit within cap
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 400 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(400 ether, alice);

        vm.prank(bob);
        asset.approve(address(concreteStandardVault), 300 ether);
        vm.prank(bob);
        concreteStandardVault.deposit(300 ether, bob);

        vm.prank(charlie);
        asset.approve(address(concreteStandardVault), 200 ether);
        vm.prank(charlie);
        concreteStandardVault.deposit(200 ether, charlie);

        // 3. Dave (not whitelisted) tries to deposit
        vm.prank(dave);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(MockWhitelistHook.NotWhitelisted.selector, dave));
        concreteStandardVault.deposit(100 ether, dave);

        // 4. Remove charlie from whitelist
        address[] memory removeList = new address[](1);
        removeList[0] = charlie;
        vm.prank(whitelistHookOwner);
        whitelistHook.unWhitelistUsers(removeList);

        // 5. Charlie cannot deposit more
        vm.prank(charlie);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(MockWhitelistHook.NotWhitelisted.selector, charlie));
        concreteStandardVault.deposit(100 ether, charlie);

        // 6. But charlie can still withdraw
        vm.prank(charlie);
        concreteStandardVault.withdraw(100 ether, charlie, charlie);
        assertEq(concreteStandardVault.balanceOf(charlie), 100 ether);

        // 7. Alice and bob can still deposit (within cap)
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), 100 ether);
        vm.prank(alice);
        concreteStandardVault.deposit(100 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), DEPOSIT_CAP);
    }

    function test_integration_dynamicHookConfiguration() public {
        // Whitelist alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(whitelistHookOwner);
        whitelistHook.whitelistUsers(users);

        // 1. Initial state: both hooks active, cap = 500 ether
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 2000 ether);

        concreteStandardVault.deposit(400 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 400 ether);

        // Can't deposit more than cap allows
        vm.expectRevert();
        concreteStandardVault.deposit(200 ether, alice);
        vm.stopPrank();

        // 2. Remove cap hook - now only whitelist check applies
        vm.prank(containerAdmin);
        container.removeHook(address(depositCapHook));

        // Alice can now deposit any amount
        vm.prank(alice);
        concreteStandardVault.deposit(500 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 900 ether);

        // Alice can deposit more (no cap)
        vm.prank(alice);
        concreteStandardVault.deposit(500 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 1400 ether);

        // 3. Re-add cap hook with new limit
        vm.prank(depositCapHookOwner);
        depositCapHook.setDepositCap(1500 ether);

        vm.prank(containerAdmin);
        container.addHook(address(depositCapHook));

        // Alice can deposit 100 more (up to 1500)
        vm.prank(alice);
        concreteStandardVault.deposit(100 ether, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 1500 ether);

        // Can't deposit beyond new cap
        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.deposit(1, alice);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Empty Container Tests
    // ═════════════════════════════════════════════════════════════════════════════

    function test_emptyContainer_allowsAllOperations() public {
        // Create a new container with no hooks
        HookContainer emptyContainer = new HookContainer(containerAdmin);

        // Set empty container as vault hook
        uint96 flags = uint96(1 << HooksLibV1.PRE_DEPOSIT) | uint96(1 << HooksLibV1.PRE_MINT);
        Hooks memory hooks = Hooks({target: address(emptyContainer), flags: flags});

        vm.prank(hookManager);
        concreteStandardVault.setHooks(hooks);

        // Anyone can deposit (no validations)
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), 1000 ether);
        concreteStandardVault.deposit(1000 ether, alice);
        vm.stopPrank();

        assertEq(concreteStandardVault.balanceOf(alice), 1000 ether);
    }
}
