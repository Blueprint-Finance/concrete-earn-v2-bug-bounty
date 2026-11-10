// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {IAccessControlEnumerable} from "@openzeppelin-contracts/access/extensions/IAccessControlEnumerable.sol";
import {ConcretePredepositVaultImpl} from "../../src/implementation/ConcretePredepositVaultImpl.sol";
import {IConcreteFactory} from "../../src/interface/IConcreteFactory.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../src/lib/Roles.sol";
import {LegacyAdminRolesLib} from "../../src/lib/LegacyAdminRolesLib.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin-contracts/proxy/transparent/ProxyAdmin.sol";
import {ConcreteFactory as ConcreteFactoryV2} from "../../src/factory/ConcreteFactory.sol";
import {IContractId} from "../../src/interface/IContractId.sol";

/**
 * @title RoleMigrationForkTest
 * @notice Fork test to verify role migration from legacy admin roles to ROLE_ADMIN
 */
contract RoleMigrationForkTest is Test {
    ProxyAdmin constant PROXY_ADMIN = ProxyAdmin(0xB255f93cD104Abc2C703aEb693580333D37ab784);
    // Mainnet addresses
    address constant FACTORY_ADDRESS = 0x0265d73a8E61F698d8EB0dfeb91Ddce55516844C; // TODO: Replace with actual factory address
    address constant ASSET_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT
    address constant VAULT_ADDRESS = 0x6503de9FE77d256d9d823f2D335Ce83EcE9E153f;
    uint64 constant CURRENT_VERSION = 3;
    uint256 constant FORK_BLOCK = 24280000;

    address testUser;
    address factoryOwner;
    address admin;
    address firstVaultManagerAdmin;
    address newFactoryImplementation;
    address factoryProxyAdminOwner;

    // New implementation for upgrade
    ConcretePredepositVaultImpl newImplementation;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, FORK_BLOCK);
        vm.selectFork(forkId);

        factoryOwner = Ownable(FACTORY_ADDRESS).owner();
        factoryProxyAdminOwner = PROXY_ADMIN.owner();

        testUser = makeAddr("testUser");
        admin = Ownable(VAULT_ADDRESS).owner();
        firstVaultManagerAdmin = _getFirstVaultManagerAdmin();

        newFactoryImplementation = address(new ConcreteFactoryV2());

        vm.label(firstVaultManagerAdmin, "firstVaultManagerAdmin");
        vm.label(VAULT_ADDRESS, "Vault Proxy");
        vm.label(FACTORY_ADDRESS, "Factory");
        vm.label(ASSET_ADDRESS, "USDT");
        vm.label(testUser, "testUser");
        vm.label(admin, "admin");
        vm.label(factoryProxyAdminOwner, "factoryProxyAdminOwner");
        vm.label(address(PROXY_ADMIN), "proxyAdminContract");
        vm.label(newFactoryImplementation, "newFactoryImplementation");
    }

    function _getFirstVaultManagerAdmin() internal view returns (address) {
        IAccessControlEnumerable vaultAccessControl = IAccessControlEnumerable(VAULT_ADDRESS);
        uint256 vaultManagerAdminCount = vaultAccessControl.getRoleMemberCount(LegacyAdminRolesLib.VAULT_MANAGER_ADMIN);
        if (vaultManagerAdminCount > 0) {
            return vaultAccessControl.getRoleMember(LegacyAdminRolesLib.VAULT_MANAGER_ADMIN, 0);
        }
        return address(0);
    }

    function testRoleMigrationOnUpgrade() public {
        IAccessControlEnumerable vaultAccessControl = IAccessControlEnumerable(VAULT_ADDRESS);

        // Step 0: Check initial state - who has legacy admin roles
        address[] memory legacyAdminsBefore = _getAllLegacyAdminMembers(vaultAccessControl);

        // Check if ROLE_ADMIN exists before upgrade
        uint256 roleAdminCountBefore = vaultAccessControl.getRoleMemberCount(RolesLib.ROLE_ADMIN);

        // Step 1: Upgrade factory
        _upgradeFactory();
        // The new implementation gates approveImplementation/setMigratable behind the
        // FACTORY_MANAGER role, which is unset (address(0)) after an upgrade. The owner
        // must assign it before manager-gated calls can be made.
        vm.prank(factoryOwner);
        IConcreteFactory(FACTORY_ADDRESS).setFactoryManager(factoryOwner);

        // Step 2: Deploy new implementation with migration
        newImplementation = new ConcretePredepositVaultImpl(FACTORY_ADDRESS);

        uint64 expectedNewContractId = IContractId(newImplementation).ID();
        // Step 3: Approve new implementation and set as migratable
        vm.startPrank(factoryOwner);
        IConcreteFactory(FACTORY_ADDRESS).approveImplementation(address(newImplementation));
        // get latest implementation contract id from factory
        IConcreteFactory(FACTORY_ADDRESS).setMigratable(CURRENT_VERSION, expectedNewContractId);
        vm.stopPrank();

        // Step 4: Upgrade the vault
        address vaultOwner = Ownable(VAULT_ADDRESS).owner();
        vm.prank(vaultOwner);

        IConcreteFactory(FACTORY_ADDRESS)
            .upgrade(
                VAULT_ADDRESS,
                expectedNewContractId,
                abi.encode(address(0), ASSET_ADDRESS, admin, "Concrete Example Vault", "ABC")
            );

        // Step 5: Verify migration worked

        // Refresh vault reference after upgrade
        vaultAccessControl = IAccessControlEnumerable(VAULT_ADDRESS);
        ConcretePredepositVaultImpl upgradedVault = ConcretePredepositVaultImpl(VAULT_ADDRESS);

        // Check that ROLE_ADMIN was granted to the first VAULT_MANAGER_ADMIN
        uint256 roleAdminCountAfter = vaultAccessControl.getRoleMemberCount(RolesLib.ROLE_ADMIN);
        if (firstVaultManagerAdmin != address(0)) {
            assertTrue(
                vaultAccessControl.hasRole(RolesLib.ROLE_ADMIN, firstVaultManagerAdmin),
                "First VAULT_MANAGER_ADMIN should have ROLE_ADMIN"
            );
            console.log("First VAULT_MANAGER_ADMIN now has ROLE_ADMIN: true");
        } else {
            // If there was no VAULT_MANAGER_ADMIN, ROLE_ADMIN count should be unchanged
            assertEq(
                roleAdminCountAfter,
                roleAdminCountBefore,
                "ROLE_ADMIN count should be unchanged if no VAULT_MANAGER_ADMIN"
            );
        }

        // Check that all legacy admin roles are revoked
        bytes32[] memory legacyRoles = LegacyAdminRolesLib.getAllLegacyAdminRoles();
        for (uint256 i = 0; i < legacyRoles.length; i++) {
            uint256 memberCount = vaultAccessControl.getRoleMemberCount(legacyRoles[i]);
            assertEq(memberCount, 0, "Legacy admin role should have no members after migration");
        }

        // Verify that the vault still works - check that admin can grant roles using ROLE_ADMIN

        vm.prank(firstVaultManagerAdmin);
        upgradedVault.grantRole(RolesLib.VAULT_MANAGER, testUser);

        assertTrue(
            vaultAccessControl.hasRole(RolesLib.VAULT_MANAGER, testUser),
            "Should be able to grant roles with ROLE_ADMIN"
        );
        console.log("Role granting with ROLE_ADMIN works: true");
    }

    /**
     * @dev Helper function to get all members of all legacy admin roles
     */
    function _getAllLegacyAdminMembers(IAccessControlEnumerable vault) internal view returns (address[] memory) {
        bytes32[] memory legacyRoles = LegacyAdminRolesLib.getAllLegacyAdminRoles();

        // Count total members
        uint256 totalMembers = 0;
        for (uint256 i = 0; i < legacyRoles.length; i++) {
            totalMembers += vault.getRoleMemberCount(legacyRoles[i]);
        }

        // Collect all members
        address[] memory members = new address[](totalMembers);
        uint256 index = 0;
        for (uint256 i = 0; i < legacyRoles.length; i++) {
            uint256 count = vault.getRoleMemberCount(legacyRoles[i]);
            for (uint256 j = 0; j < count; j++) {
                members[index] = vault.getRoleMember(legacyRoles[i], j);
                index++;
            }
        }

        return members;
    }

    function _upgradeFactory() public {
        vm.startPrank(factoryProxyAdminOwner);
        // pass zero ether
        // proxy address, i.e. factory address,
        // implementation address, i.e. new factory implementation address
        // data, i.e. empty bytes
        PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(FACTORY_ADDRESS), newFactoryImplementation, "");
        vm.stopPrank();
    }
}
