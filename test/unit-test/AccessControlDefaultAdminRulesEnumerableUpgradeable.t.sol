// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    AccessControlDefaultAdminRulesEnumerableUpgradeable
} from "../../src/lib/AccessControlDefaultAdminRulesEnumerableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin-contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin-contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Concrete implementation for testing
contract TestAccessControlUpgradeable is AccessControlDefaultAdminRulesEnumerableUpgradeable {
    bytes32 public constant TEST_ROLE = keccak256("TEST_ROLE");
    bytes32 public constant ANOTHER_ROLE = keccak256("ANOTHER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint48 initialDelay, address initialAdmin) external initializer {
        __AccessControlDefaultAdminRulesEnumerable_init(initialDelay, initialAdmin);
        _setRoleAdmin(TEST_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ANOTHER_ROLE, DEFAULT_ADMIN_ROLE);
    }
}

contract AccessControlDefaultAdminRulesEnumerableUpgradeableTest is Test {
    TestAccessControlUpgradeable public accessControl;
    TestAccessControlUpgradeable public implementation;

    address public admin;
    address public user1;
    address public user2;
    address public user3;

    uint48 public constant INITIAL_DELAY = 1 days;
    bytes32 public TEST_ROLE;
    bytes32 public ANOTHER_ROLE;
    bytes32 public DEFAULT_ADMIN_ROLE;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event DefaultAdminTransferScheduled(address indexed newAdmin, uint48 acceptSchedule);
    event DefaultAdminTransferCanceled();
    event DefaultAdminDelayChangeScheduled(uint48 newDelay, uint48 effectSchedule);

    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy implementation
        implementation = new TestAccessControlUpgradeable();

        // Deploy proxy and initialize
        bytes memory initData =
            abi.encodeWithSelector(TestAccessControlUpgradeable.initialize.selector, INITIAL_DELAY, admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        accessControl = TestAccessControlUpgradeable(address(proxy));

        // Cache role constants to avoid consuming pranks
        TEST_ROLE = accessControl.TEST_ROLE();
        ANOTHER_ROLE = accessControl.ANOTHER_ROLE();
        DEFAULT_ADMIN_ROLE = accessControl.DEFAULT_ADMIN_ROLE();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Initialization Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_initialize_setsDefaultAdmin() public view {
        assertEq(accessControl.defaultAdmin(), admin);
    }

    function test_initialize_setsDefaultAdminDelay() public view {
        assertEq(accessControl.defaultAdminDelay(), INITIAL_DELAY);
    }

    function test_initialize_grantsDefaultAdminRole() public view {
        assertTrue(accessControl.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_initialize_adminInEnumeration() public view {
        assertEq(accessControl.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(accessControl.getRoleMember(DEFAULT_ADMIN_ROLE, 0), admin);
    }

    function test_initialize_defaultAdminEnumerableViaGetRoleMembers() public view {
        address[] memory members = accessControl.getRoleMembers(DEFAULT_ADMIN_ROLE);
        assertEq(members.length, 1);
        assertEq(members[0], admin);
    }

    function test_initialize_revertsOnZeroAdmin() public {
        TestAccessControlUpgradeable newImpl = new TestAccessControlUpgradeable();
        bytes memory initData =
            abi.encodeWithSelector(TestAccessControlUpgradeable.initialize.selector, INITIAL_DELAY, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_zeroDelayAllowed() public {
        TestAccessControlUpgradeable newImpl = new TestAccessControlUpgradeable();
        bytes memory initData =
            abi.encodeWithSelector(TestAccessControlUpgradeable.initialize.selector, uint48(0), admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(newImpl), initData);
        TestAccessControlUpgradeable zeroDelay = TestAccessControlUpgradeable(address(proxy));

        assertEq(zeroDelay.defaultAdminDelay(), 0);
        assertEq(zeroDelay.defaultAdmin(), admin);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        accessControl.initialize(INITIAL_DELAY, admin);
    }

    function test_initialize_implementationCannotBeInitialized() public {
        vm.expectRevert();
        implementation.initialize(INITIAL_DELAY, admin);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Default Admin Rules Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_defaultAdminRole_cannotBeGrantedDirectly() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector)
        );
        vm.prank(admin);
        accessControl.grantRole(DEFAULT_ADMIN_ROLE, user1);
    }

    function test_defaultAdminRole_cannotBeRevokedDirectly() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector)
        );
        vm.prank(admin);
        accessControl.revokeRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function test_defaultAdmin_twoStepTransfer() public {
        // Step 1: Begin transfer
        vm.prank(admin);
        accessControl.beginDefaultAdminTransfer(user1);

        (address pendingAdmin, uint48 schedule) = accessControl.pendingDefaultAdmin();
        assertEq(pendingAdmin, user1);
        assertEq(schedule, uint48(block.timestamp) + INITIAL_DELAY);

        // Warp past delay
        vm.warp(block.timestamp + INITIAL_DELAY + 1);

        // Step 2: Accept transfer
        vm.prank(user1);
        accessControl.acceptDefaultAdminTransfer();

        assertEq(accessControl.defaultAdmin(), user1);
        assertTrue(accessControl.hasRole(DEFAULT_ADMIN_ROLE, user1));
        assertFalse(accessControl.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_defaultAdmin_transferUpdatesEnumeration() public {
        // Begin and complete transfer
        vm.prank(admin);
        accessControl.beginDefaultAdminTransfer(user1);

        vm.warp(block.timestamp + INITIAL_DELAY + 1);

        vm.prank(user1);
        accessControl.acceptDefaultAdminTransfer();

        // Check enumeration updated
        assertEq(accessControl.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(accessControl.getRoleMember(DEFAULT_ADMIN_ROLE, 0), user1);
    }

    function test_defaultAdmin_cancelTransfer() public {
        vm.prank(admin);
        accessControl.beginDefaultAdminTransfer(user1);

        vm.expectEmit(true, true, true, true);
        emit DefaultAdminTransferCanceled();
        vm.prank(admin);
        accessControl.cancelDefaultAdminTransfer();

        (address pendingAdmin,) = accessControl.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertEq(accessControl.defaultAdmin(), admin);
    }

    function test_defaultAdmin_acceptBeforeDelayReverts() public {
        vm.prank(admin);
        accessControl.beginDefaultAdminTransfer(user1);

        // Try to accept before delay passes
        vm.expectRevert();
        vm.prank(user1);
        accessControl.acceptDefaultAdminTransfer();
    }

    function test_defaultAdmin_onlyPendingCanAccept() public {
        vm.prank(admin);
        accessControl.beginDefaultAdminTransfer(user1);

        vm.warp(block.timestamp + INITIAL_DELAY + 1);

        // Wrong account tries to accept
        vm.expectRevert();
        vm.prank(user2);
        accessControl.acceptDefaultAdminTransfer();
    }

    function test_defaultAdmin_changeDelay() public {
        uint48 newDelay = 2 days;

        vm.prank(admin);
        accessControl.changeDefaultAdminDelay(newDelay);

        // Delay change is also scheduled
        (uint48 pendingDelay, uint48 schedule) = accessControl.pendingDefaultAdminDelay();
        assertEq(pendingDelay, newDelay);
        assertTrue(schedule > block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Role Grant Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_grantRole_success() public {
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(TEST_ROLE, user1, admin);
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        assertTrue(accessControl.hasRole(TEST_ROLE, user1));
    }

    function test_grantRole_updatesEnumeration() public {
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 1);
        assertEq(accessControl.getRoleMember(TEST_ROLE, 0), user1);
    }

    function test_grantRole_multipleMembers() public {
        vm.startPrank(admin);
        accessControl.grantRole(TEST_ROLE, user1);
        accessControl.grantRole(TEST_ROLE, user2);
        accessControl.grantRole(TEST_ROLE, user3);
        vm.stopPrank();

        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 3);

        address[] memory members = accessControl.getRoleMembers(TEST_ROLE);
        assertEq(members.length, 3);
        assertEq(members[0], user1);
        assertEq(members[1], user2);
        assertEq(members[2], user3);
    }

    function test_grantRole_duplicateNoOp() public {
        vm.startPrank(admin);
        accessControl.grantRole(TEST_ROLE, user1);
        accessControl.grantRole(TEST_ROLE, user1); // Duplicate
        vm.stopPrank();

        // Should still only be 1 member
        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 1);
    }

    function test_grantRole_revertsUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(user1);
        accessControl.grantRole(TEST_ROLE, user2);
    }

    function test_grantRole_multipleRolesToSameUser() public {
        vm.startPrank(admin);
        accessControl.grantRole(TEST_ROLE, user1);
        accessControl.grantRole(ANOTHER_ROLE, user1);
        vm.stopPrank();

        assertTrue(accessControl.hasRole(TEST_ROLE, user1));
        assertTrue(accessControl.hasRole(ANOTHER_ROLE, user1));
        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 1);
        assertEq(accessControl.getRoleMemberCount(ANOTHER_ROLE), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Role Revoke Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_revokeRole_success() public {
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(TEST_ROLE, user1, admin);
        vm.prank(admin);
        accessControl.revokeRole(TEST_ROLE, user1);

        assertFalse(accessControl.hasRole(TEST_ROLE, user1));
    }

    function test_revokeRole_updatesEnumeration() public {
        vm.startPrank(admin);
        accessControl.grantRole(TEST_ROLE, user1);
        accessControl.grantRole(TEST_ROLE, user2);
        vm.stopPrank();

        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 2);

        vm.prank(admin);
        accessControl.revokeRole(TEST_ROLE, user1);

        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 1);
        assertEq(accessControl.getRoleMember(TEST_ROLE, 0), user2);
    }

    function test_revokeRole_revertsUnauthorized() public {
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user2, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(user2);
        accessControl.revokeRole(TEST_ROLE, user1);
    }

    function test_revokeRole_nonMemberNoOp() public {
        // Revoking role from non-member should not revert
        vm.prank(admin);
        accessControl.revokeRole(TEST_ROLE, user1);

        assertFalse(accessControl.hasRole(TEST_ROLE, user1));
        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Role Renounce Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_renounceRole_success() public {
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        vm.prank(user1);
        accessControl.renounceRole(TEST_ROLE, user1);

        assertFalse(accessControl.hasRole(TEST_ROLE, user1));
    }

    function test_renounceRole_updatesEnumeration() public {
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 1);

        vm.prank(user1);
        accessControl.renounceRole(TEST_ROLE, user1);

        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 0);
    }

    function test_renounceRole_cannotRenounceForOther() public {
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector));
        vm.prank(user2);
        accessControl.renounceRole(TEST_ROLE, user1);
    }

    function test_renounceDefaultAdmin_requiresTwoStepProcess() public {
        // Default admin renounce requires 2-step process via beginDefaultAdminTransfer(address(0))
        vm.prank(admin);
        accessControl.beginDefaultAdminTransfer(address(0));

        vm.warp(block.timestamp + INITIAL_DELAY + 1);

        // Now admin can renounce
        vm.prank(admin);
        accessControl.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertEq(accessControl.defaultAdmin(), address(0));
        assertFalse(accessControl.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(accessControl.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Enumeration Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_getRoleMember_revertsOutOfBounds() public {
        vm.expectRevert();
        accessControl.getRoleMember(TEST_ROLE, 0);
    }

    function test_getRoleMembers_emptyRole() public view {
        address[] memory members = accessControl.getRoleMembers(TEST_ROLE);
        assertEq(members.length, 0);
    }

    function test_getRoleMemberCount_emptyRole() public view {
        assertEq(accessControl.getRoleMemberCount(TEST_ROLE), 0);
    }

    function test_enumeration_orderAfterRevoke() public {
        vm.startPrank(admin);
        accessControl.grantRole(TEST_ROLE, user1);
        accessControl.grantRole(TEST_ROLE, user2);
        accessControl.grantRole(TEST_ROLE, user3);
        vm.stopPrank();

        // Revoke middle user
        vm.prank(admin);
        accessControl.revokeRole(TEST_ROLE, user2);

        address[] memory members = accessControl.getRoleMembers(TEST_ROLE);
        assertEq(members.length, 2);
        // Note: EnumerableSet swaps with last element on remove, so user3 takes user2's spot
        assertEq(members[0], user1);
        assertEq(members[1], user3);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Interface Support Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_supportsInterface_IAccessControl() public view {
        assertTrue(accessControl.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_supportsInterface_IAccessControlEnumerable() public view {
        assertTrue(accessControl.supportsInterface(type(IAccessControlEnumerable).interfaceId));
    }

    function test_supportsInterface_IAccessControlDefaultAdminRules() public view {
        assertTrue(accessControl.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId));
    }

    function test_supportsInterface_invalidInterface() public view {
        assertFalse(accessControl.supportsInterface(0xffffffff));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // Role Admin Tests
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_getRoleAdmin() public view {
        assertEq(accessControl.getRoleAdmin(TEST_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(accessControl.getRoleAdmin(ANOTHER_ROLE), DEFAULT_ADMIN_ROLE);
    }

    function test_roleWithCustomAdmin() public {
        // Grant TEST_ROLE to user1
        vm.prank(admin);
        accessControl.grantRole(TEST_ROLE, user1);

        // user1 cannot grant ANOTHER_ROLE (admin is DEFAULT_ADMIN_ROLE, not TEST_ROLE)
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(user1);
        accessControl.grantRole(ANOTHER_ROLE, user2);
    }
}
