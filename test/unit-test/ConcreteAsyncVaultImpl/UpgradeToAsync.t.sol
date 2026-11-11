// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {TestBaseSetup} from "../../common/TestBaseSetup.t.sol";
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
import {ConcreteAsyncVaultImpl} from "../../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {IConcreteAsyncVaultImpl} from "../../../src/interface/IConcreteAsyncVaultImpl.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";
import {LegacyAdminRolesLib} from "../../../src/lib/LegacyAdminRolesLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {ERC20Mock} from "../../mock/ERC20Mock.sol";
import {AllocateModule} from "../../../src/module/AllocateModule.sol";

/// @notice Regression tests for HAL-10 (May 2026 audit round).
/// @dev Verifies that a Standard → Async upgrade through the factory correctly
///      initialises the async-specific state (queue active, latestEpochID, unwind
///      cost cap, role admins), and that Async → Async upgrades do NOT re-init
///      live state.
contract UpgradeToAsync is TestBaseSetup {
    address public vaultOwner;
    address public vaultManager;
    address public user1;
    address public user2;

    ERC20Mock public asset;
    AllocateModule public allocateModule;

    ConcreteAsyncVaultImpl public concreteAsyncVaultImpl;
    ConcreteStandardVaultImpl public standardVault;

    uint64 internal standardVaultImplId;
    uint64 internal asyncVaultImplId;

    /// @dev OZ EIP-7201 storage location for `AccessControlUpgradeable`.
    bytes32 private constant _AC_STORAGE_LOC = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;
    /// @dev OZ EIP-7201 storage location for `AccessControlEnumerableUpgradeable`.
    bytes32 private constant _ACE_STORAGE_LOC = 0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000;

    function setUp() public override {
        super.setUp();

        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        asset = new ERC20Mock();
        allocateModule = new AllocateModule();

        // Deploy & approve async impl.
        concreteAsyncVaultImpl = new ConcreteAsyncVaultImpl(address(factory));
        vm.prank(factoryOwner);
        factory.approveImplementation(address(concreteAsyncVaultImpl));

        standardVaultImplId = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        asyncVaultImplId = uint64(IContractId(address(concreteAsyncVaultImpl)).ID());

        // Allow upgrade path Standard → Async.
        vm.prank(factoryOwner);
        factory.setMigratable(standardVaultImplId, asyncVaultImplId);

        // Deploy a standard vault and seed it with deposits.
        standardVault = ConcreteStandardVaultImpl(
            factory.create(
                standardVaultImplId,
                vaultOwner,
                abi.encode(address(allocateModule), address(asset), vaultManager, "Standard Vault to Upgrade", "SVTU")
            )
        );

        asset.mint(user1, 10_000e18);
        asset.mint(user2, 10_000e18);

        vm.prank(user1);
        asset.approve(address(standardVault), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(standardVault), type(uint256).max);

        vm.prank(user1);
        standardVault.deposit(5_000e18, user1);
        vm.prank(user2);
        standardVault.deposit(3_000e18, user2);
    }

    /// @notice Standard → Async upgrade must initialise async-specific state.
    function test_upgradeStandardToAsync_initializesAsyncState() public {
        // Pre-upgrade sanity: the standard impl does not expose async views, so we
        // probe via low-level staticcall instead of through the async interface.
        (bool latestEpochIDCallable,) = address(standardVault).staticcall(abi.encodeWithSignature("latestEpochID()"));
        assertFalse(latestEpochIDCallable, "latestEpochID() must not exist on standard impl pre-upgrade");

        // Snapshot standard-vault state we expect to survive the upgrade.
        uint256 user1Shares = standardVault.balanceOf(user1);
        uint256 user2Shares = standardVault.balanceOf(user2);
        uint256 totalAssets = standardVault.totalAssets();
        assertTrue(standardVault.hasRole(RolesLib.ROLE_ADMIN, vaultManager), "ROLE_ADMIN holder must exist pre-upgrade");
        assertTrue(
            standardVault.hasRole(RolesLib.VAULT_MANAGER, vaultManager), "VAULT_MANAGER holder must exist pre-upgrade"
        );

        // Expect the queue-init event to fire during upgrade.
        vm.expectEmit(false, false, false, true, address(standardVault));
        emit IConcreteAsyncVaultImpl.WithdrawalQueueInitialized(1);

        vm.prank(vaultOwner);
        factory.upgrade(address(standardVault), asyncVaultImplId, "");

        ConcreteAsyncVaultImpl asyncView = ConcreteAsyncVaultImpl(address(standardVault));

        // Async-specific state is now populated.
        assertEq(asyncView.latestEpochID(), 1, "latestEpochID must be 1 post-upgrade");
        assertTrue(asyncView.isQueueActive(), "isQueueActive must be true post-upgrade");
        assertEq(asyncView.getUnwindCostCap(), 500, "unwindCostCapBP must default to 500");

        // Role admins for the new async-only roles are wired to ROLE_ADMIN.
        assertEq(
            asyncView.getRoleAdmin(RolesLib.WITHDRAWAL_MANAGER),
            RolesLib.ROLE_ADMIN,
            "WITHDRAWAL_MANAGER admin must be ROLE_ADMIN"
        );
        assertEq(
            asyncView.getRoleAdmin(RolesLib.PRIORITY_WITHDRAWAL_EXECUTOR),
            RolesLib.ROLE_ADMIN,
            "PRIORITY_WITHDRAWAL_EXECUTOR admin must be ROLE_ADMIN"
        );

        // Standard-vault state is preserved.
        assertEq(asyncView.balanceOf(user1), user1Shares, "user1 shares preserved");
        assertEq(asyncView.balanceOf(user2), user2Shares, "user2 shares preserved");
        assertEq(asyncView.totalAssets(), totalAssets, "totalAssets preserved");
        assertTrue(asyncView.hasRole(RolesLib.ROLE_ADMIN, vaultManager), "ROLE_ADMIN preserved");
        assertTrue(asyncView.hasRole(RolesLib.VAULT_MANAGER, vaultManager), "VAULT_MANAGER preserved");

        // Post-upgrade: existing ROLE_ADMIN holder can grant the new async roles.
        address withdrawalManager = makeAddr("withdrawalManager");
        vm.prank(vaultManager);
        asyncView.grantRole(RolesLib.WITHDRAWAL_MANAGER, withdrawalManager);
        assertTrue(
            asyncView.hasRole(RolesLib.WITHDRAWAL_MANAGER, withdrawalManager),
            "ROLE_ADMIN must be able to grant WITHDRAWAL_MANAGER post-upgrade"
        );
    }

    /// @notice An Async → Async upgrade (e.g. minor version bump) must NOT re-init
    ///         async state — operator-tuned values like unwindCostCapBP and the
    ///         current epoch ID have to be preserved across the upgrade.
    function test_upgradeAsyncToAsync_doesNotReinitAsyncState() public {
        // First, take the standard vault through Standard → Async to set up the
        // async storage in a "lived-in" state.
        vm.prank(vaultOwner);
        factory.upgrade(address(standardVault), asyncVaultImplId, "");

        ConcreteAsyncVaultImpl asyncVault = ConcreteAsyncVaultImpl(address(standardVault));

        // Simulate operator tuning post-upgrade.
        vm.prank(vaultManager);
        asyncVault.setUnwindCostCap(750);
        assertEq(asyncVault.getUnwindCostCap(), 750, "unwindCostCapBP set");

        // Deploy a "v2" async impl with a fresh ID and approve it; map the migration.
        AsyncImplV2 asyncImplV2 = new AsyncImplV2(address(factory));
        vm.prank(factoryOwner);
        factory.approveImplementation(address(asyncImplV2));
        uint64 v2Id = uint64(IContractId(address(asyncImplV2)).ID());
        vm.prank(factoryOwner);
        factory.setMigratable(asyncVaultImplId, v2Id);

        // Upgrade Async → AsyncV2 and verify the guard skipped re-init.
        vm.prank(vaultOwner);
        factory.upgrade(address(standardVault), v2Id, "");

        assertEq(asyncVault.latestEpochID(), 1, "latestEpochID must be preserved");
        assertTrue(asyncVault.isQueueActive(), "isQueueActive must be preserved");
        assertEq(asyncVault.getUnwindCostCap(), 750, "unwindCostCapBP must be preserved");
    }

    /// @notice Standard → Async upgrade must run legacy role migration: any holder
    ///         of a legacy `VAULT_MANAGER_ADMIN` role is granted `ROLE_ADMIN` and
    ///         all legacy admin roles are emptied. This regression protects against
    ///         a future refactor accidentally moving the migration out of the
    ///         async upgrade path.
    function test_upgradeStandardToAsync_migratesLegacyVaultManagerAdmin() public {
        address legacyAdmin = makeAddr("legacyAdmin");

        // Inject a legacy VAULT_MANAGER_ADMIN member on the standard vault.
        _grantLegacyAdmin(address(standardVault), LegacyAdminRolesLib.VAULT_MANAGER_ADMIN, legacyAdmin);

        // Sanity: injection succeeded and is enumerable.
        assertTrue(
            standardVault.hasRole(LegacyAdminRolesLib.VAULT_MANAGER_ADMIN, legacyAdmin),
            "legacyAdmin must hold VAULT_MANAGER_ADMIN pre-upgrade"
        );
        assertEq(
            standardVault.getRoleMemberCount(LegacyAdminRolesLib.VAULT_MANAGER_ADMIN),
            1,
            "VAULT_MANAGER_ADMIN must be enumerable pre-upgrade"
        );
        assertFalse(standardVault.hasRole(RolesLib.ROLE_ADMIN, legacyAdmin), "legacyAdmin must not hold ROLE_ADMIN yet");

        // Standard → Async upgrade.
        vm.prank(vaultOwner);
        factory.upgrade(address(standardVault), asyncVaultImplId, "");

        ConcreteAsyncVaultImpl asyncView = ConcreteAsyncVaultImpl(address(standardVault));

        // Migration outcomes.
        assertTrue(
            asyncView.hasRole(RolesLib.ROLE_ADMIN, legacyAdmin), "legacyAdmin must now hold ROLE_ADMIN post-upgrade"
        );

        bytes32[] memory legacyRoles = LegacyAdminRolesLib.getAllLegacyAdminRoles();
        for (uint256 i = 0; i < legacyRoles.length; i++) {
            assertEq(
                asyncView.getRoleMemberCount(legacyRoles[i]), 0, "all legacy admin roles must be empty post-migration"
            );
        }
    }

    /// @notice Async → Async upgrade must also run legacy role migration. If a
    ///         legacy VAULT_MANAGER_ADMIN ends up on an async vault (e.g. via a
    ///         malformed migration or direct storage repair), the next upgrade
    ///         must still revoke it and promote the holder to ROLE_ADMIN — and
    ///         it must do so without re-initialising the async state.
    function test_upgradeAsyncToAsync_migratesLegacyVaultManagerAdmin() public {
        // First, Standard → Async to bring the proxy into async mode.
        vm.prank(vaultOwner);
        factory.upgrade(address(standardVault), asyncVaultImplId, "");

        ConcreteAsyncVaultImpl asyncVault = ConcreteAsyncVaultImpl(address(standardVault));

        // Inject a legacy admin onto the async vault.
        address legacyAdmin = makeAddr("legacyAdminAsync");
        _grantLegacyAdmin(address(asyncVault), LegacyAdminRolesLib.VAULT_MANAGER_ADMIN, legacyAdmin);
        assertTrue(
            asyncVault.hasRole(LegacyAdminRolesLib.VAULT_MANAGER_ADMIN, legacyAdmin),
            "legacyAdmin must hold VAULT_MANAGER_ADMIN pre-A2A upgrade"
        );

        // Deploy AsyncImplV2 and authorise the Async → AsyncV2 migration path.
        AsyncImplV2 asyncImplV2 = new AsyncImplV2(address(factory));
        vm.prank(factoryOwner);
        factory.approveImplementation(address(asyncImplV2));
        uint64 v2Id = uint64(IContractId(address(asyncImplV2)).ID());
        vm.prank(factoryOwner);
        factory.setMigratable(asyncVaultImplId, v2Id);

        // Snapshot the async state — must survive the upgrade unchanged.
        uint256 latestEpochBefore = asyncVault.latestEpochID();
        bool queueActiveBefore = asyncVault.isQueueActive();
        uint16 unwindCapBefore = asyncVault.getUnwindCostCap();

        // Async → AsyncV2 upgrade.
        vm.prank(vaultOwner);
        factory.upgrade(address(asyncVault), v2Id, "");

        // Migration outcomes.
        assertTrue(
            asyncVault.hasRole(RolesLib.ROLE_ADMIN, legacyAdmin),
            "legacyAdmin must now hold ROLE_ADMIN post-A2A upgrade"
        );

        bytes32[] memory legacyRoles = LegacyAdminRolesLib.getAllLegacyAdminRoles();
        for (uint256 i = 0; i < legacyRoles.length; i++) {
            assertEq(
                asyncVault.getRoleMemberCount(legacyRoles[i]),
                0,
                "all legacy admin roles must be empty post-A2A migration"
            );
        }

        // Async state preserved (no re-init).
        assertEq(asyncVault.latestEpochID(), latestEpochBefore, "latestEpochID must be preserved");
        assertEq(asyncVault.isQueueActive(), queueActiveBefore, "isQueueActive must be preserved");
        assertEq(asyncVault.getUnwindCostCap(), unwindCapBefore, "unwindCostCapBP must be preserved");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Injects `account` as a sole member of legacy `role` on `vault` by
    ///      patching both the AccessControl `_roles[role].hasRole` flag and the
    ///      AccessControlEnumerable `_roleMembers[role]._inner` set
    ///      ({_values, _positions}). Only valid when the role currently has 0
    ///      members; otherwise the writes corrupt the EnumerableSet.
    function _grantLegacyAdmin(address vault, bytes32 role, address account) internal {
        // _roles[role].hasRole[account] = true
        bytes32 rolesEntrySlot = keccak256(abi.encode(role, _AC_STORAGE_LOC));
        bytes32 hasRoleSlot = keccak256(abi.encode(account, rolesEntrySlot));
        vm.store(vault, hasRoleSlot, bytes32(uint256(1)));

        // _roleMembers[role]._inner._values: length = 1, _values[0] = account.
        bytes32 setSlot = keccak256(abi.encode(role, _ACE_STORAGE_LOC));
        vm.store(vault, setSlot, bytes32(uint256(1)));
        bytes32 valuesDataSlot = keccak256(abi.encodePacked(setSlot));
        vm.store(vault, valuesDataSlot, bytes32(uint256(uint160(account))));

        // _roleMembers[role]._inner._positions[bytes32(account)] = 1 (1-indexed).
        bytes32 positionsBase = bytes32(uint256(setSlot) + 1);
        bytes32 positionSlot = keccak256(abi.encode(bytes32(uint256(uint160(account))), positionsBase));
        vm.store(vault, positionSlot, bytes32(uint256(1)));
    }
}

/// @dev Minimal async impl used solely to exercise the Async → Async upgrade path.
///      Bumps the patch version so the factory accepts it as a distinct implementation.
contract AsyncImplV2 is ConcreteAsyncVaultImpl {
    constructor(address factory) ConcreteAsyncVaultImpl(factory) {}

    function ID() public pure override returns (uint64) {
        // contractType=0 (vault), flavour=2 (async), version=1.2.1
        return uint64(210201);
    }
}
