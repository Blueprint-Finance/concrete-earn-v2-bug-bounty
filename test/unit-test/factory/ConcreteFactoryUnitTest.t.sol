// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    IConcreteFactory,
    ConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy
} from "../../common/ConcreteFactoryBaseSetup.t.sol";

import {IUpgradeableVault} from "../../../src/interface/IUpgradeableVault.sol";
import {IDefaultEnforcedVaultConfiguration} from "../../../src/interface/IDefaultEnforcedVaultConfiguration.sol";

import {ConcreteFactory} from "../../../src/factory/ConcreteFactory.sol";
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IVaultProxy} from "../../../src/interface/IVaultProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ContractIdEncoding} from "../../../src/lib/ContractIdEncoding.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

import {console2 as console} from "forge-std/console2.sol";

contract ConcreteFactory2 is ConcreteFactory {
    uint8 public version;

    function initializeV2(uint8 version_) external reinitializer(version_) {
        version = version_;
    }
}

contract ConcreteFactoryUnitTest is ConcreteFactoryBaseSetup {
    function setUp() public override {
        ConcreteFactoryBaseSetup.setUp();
    }

    function testUpgradeFactory() public {
        address factoryImpl = address(new ConcreteFactory2());
        vm.startPrank(factoryOwner);
        factory.upgradeToAndCall(factoryImpl, abi.encodeCall(ConcreteFactory2.initializeV2, (2)));
        vm.stopPrank();
        assertEq(ConcreteFactory2(address(factory)).version(), 2);
    }

    function testUpgradeFactoryByNonOwner() public {
        address factoryImpl = address(new ConcreteFactory2());
        // OwnableUnauthorizedAccount(address account)
        address nonOwner = makeAddr("nonOwner");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        factory.upgradeToAndCall(factoryImpl, abi.encodeCall(ConcreteFactory2.initializeV2, (2)));
    }

    function testApproveImplementation() public {
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        address fakeImpl = address(new Impl1(makeAddr("fakeFactory")));

        // get ContractId from impl1 and 2
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        assertEq(factory.getImplementationByVaultImpl(vaultImpl1), impl1);
        assertEq(factory.getImplementationByVaultImpl(vaultImpl2), impl2);

        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.InvalidImplementation.selector);
        factory.approveImplementation(fakeImpl);

        // should revert approving an implementation with ID() == 0
        address implZeroId = address(new ImplZeroId(address(factory)));
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ZeroVaultImplId.selector);
        factory.approveImplementation(implZeroId);

        // should revert approving an already approved implementation
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.AlreadyApproved.selector);
        factory.approveImplementation(impl1);
    }

    function testDeployProxyUsingImpl1() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        vm.stopPrank();

        address predicted =
            factory.predictVaultAddress(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        vm.expectEmit(true, true, true, true);
        emit IConcreteFactory.Deployed(predicted, vaultImpl1, vaultOwner);

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        assertEq(Impl1(proxy).implName(), "Vault with Impl1");
        assertEq(Impl1(proxy).implSymbol(), "Impl1Vault");
        assertEq(Impl1(proxy).implVersion(), vaultImpl1);
        assertEq(Impl1(proxy).owner(), vaultOwner);

        // should revert using version == 0
        vm.expectRevert(IConcreteFactory.InvalidVersion.selector);
        factory.create(0, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        // should revert using invalid vault ID (not approved)
        uint64 invalidVaultImpl = uint64(IContractId(address(new Impl2(address(factory)))).ID());
        vm.expectRevert(IConcreteFactory.InvalidVersion.selector);
        factory.create(invalidVaultImpl, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));
    }

    function testDeployVaultWithSalt() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        vm.stopPrank();

        bytes32 salt = bytes32(uint256(1));
        address predicted =
            factory.predictVaultAddress(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"), salt);

        vm.expectEmit(true, true, true, true);
        emit IConcreteFactory.Deployed(predicted, vaultImpl1, vaultOwner);

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"), salt);

        assertEq(Impl1(proxy).implName(), "Vault with Impl1");
        assertEq(Impl1(proxy).implSymbol(), "Impl1Vault");
        assertEq(Impl1(proxy).implVersion(), vaultImpl1);
        assertEq(Impl1(proxy).owner(), vaultOwner);
    }

    function testDeployVaultWithSaultDifferentSenderCreatesDifferentAddress() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        bytes32 salt = bytes32(uint256(1));
        bytes32 salt2 = bytes32(uint256(2));

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        vm.stopPrank();

        address predicted1 =
            factory.predictVaultAddress(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"), salt);
        address predicted2 =
            factory.predictVaultAddress(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"), salt2);

        assertNotEq(predicted1, predicted2);
    }

    function testDeployUsingBlockedImpl() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.blockImplementation(vaultImpl1);
        vm.stopPrank();

        vm.expectRevert(IConcreteFactory.ImplementationBlocked.selector);
        factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));
    }

    function testDeployUsingBlockedImplByAddress() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.blockImplementationByAddress(impl1);
        vm.stopPrank();

        vm.expectRevert(IConcreteFactory.ImplementationBlocked.selector);
        factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));
    }

    function testBlockImplementationByAddressNotFound() public {
        address impl1 = address(new Impl1(address(factory)));
        // Don't approve the implementation, so it's not in the Factory

        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ImplementationNotFound.selector);
        factory.blockImplementationByAddress(impl1);
    }

    function testMigrateByNonVaultOwner() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        // should revert migration if called by non-owner
        vm.expectRevert(IConcreteFactory.NotOwner.selector);
        vm.prank(makeAddr("nonOwner"));
        factory.upgrade(proxy, vaultImpl2, abi.encode("Vault with Impl2", "Impl2Vault"));
    }

    function testMigrateToOldVersion() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        // should revert migration if new version is not greater than current version
        vm.expectRevert(IConcreteFactory.OldVersion.selector);
        vm.prank(vaultOwner);
        factory.upgrade(proxy, vaultImpl1, abi.encode("Vault with Impl2", "Impl2Vault"));
    }

    function testMigrateNotMigratableVersionParis() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        vm.expectRevert(IConcreteFactory.CanNotMigrate.selector);
        vm.prank(vaultOwner);
        factory.upgrade(proxy, vaultImpl2, abi.encode("Vault with Impl2", "Impl2Vault"));
    }

    function testMigrateImpl1ToImpl2() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        assertEq(Impl1(proxy).implName(), "Vault with Impl1");
        assertEq(Impl1(proxy).implSymbol(), "Impl1Vault");
        assertEq(Impl1(proxy).implVersion(), vaultImpl1);

        // approve migration from impl1 to impl2
        vm.startPrank(factoryOwner);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        assertEq(factory.isMigratable(vaultImpl1, vaultImpl2), true);
        assertEq(factory.isMigratable(vaultImpl2, vaultImpl1), false);

        // migrate to impl2
        vm.prank(vaultOwner);
        factory.upgrade(proxy, vaultImpl2, abi.encode("Vault with Impl2", "Impl2Vault"));

        assertEq(Impl2(proxy).implName(), "Vault with Impl2");
        assertEq(Impl2(proxy).implSymbol(), "Impl2Vault");
        assertEq(Impl2(proxy).implVersion(), vaultImpl2);

        // should revert setting migration path to the same vaultImpl
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.OldVersion.selector);
        factory.setMigratable(vaultImpl1, vaultImpl1);

        // should revert when migrating to non existing version
        address impl3 = address(new ExternalImpl(address(factory)));
        uint64 vaultImpl3 = uint64(IContractId(impl3).ID());
        vm.expectRevert(IConcreteFactory.CanNotMigrate.selector);
        vm.prank(vaultOwner);
        factory.upgrade(proxy, vaultImpl3, abi.encode("Vault with Impl3", "Impl3Vault"));
    }

    function testSetMigratableByAddress() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        assertEq(Impl1(proxy).implName(), "Vault with Impl1");
        assertEq(Impl1(proxy).implSymbol(), "Impl1Vault");
        assertEq(Impl1(proxy).implVersion(), vaultImpl1);

        // approve migration from impl1 to impl2 using addresses
        vm.startPrank(factoryOwner);
        factory.setMigratableByAddress(impl1, impl2);
        vm.stopPrank();

        assertEq(factory.isMigratable(vaultImpl1, vaultImpl2), true);
        assertEq(factory.isMigratable(vaultImpl2, vaultImpl1), false);

        // migrate to impl2
        vm.prank(vaultOwner);
        factory.upgrade(proxy, vaultImpl2, abi.encode("Vault with Impl2", "Impl2Vault"));

        assertEq(Impl2(proxy).implName(), "Vault with Impl2");
        assertEq(Impl2(proxy).implSymbol(), "Impl2Vault");
        assertEq(Impl2(proxy).implVersion(), vaultImpl2);
    }

    function testSetMigratableByAddressNotFound() public {
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        // Don't approve impl2, so it's not in the Factory
        vm.stopPrank();

        // Try to set migratable with impl2 that is not approved
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ImplementationNotFound.selector);
        factory.setMigratableByAddress(impl1, impl2);

        // Try to set migratable with impl1 that is approved but impl2 not approved
        // This should also fail because impl2 is not found
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ImplementationNotFound.selector);
        factory.setMigratableByAddress(impl2, impl1);
    }

    function testMigrateToBlockedImpl() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        // approve migration from impl1 to impl2
        vm.startPrank(factoryOwner);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        factory.blockImplementation(vaultImpl2);
        vm.stopPrank();

        assertEq(factory.isMigratable(vaultImpl1, vaultImpl2), true);
        assertEq(factory.isBlocked(vaultImpl2), true);

        vm.expectRevert(IConcreteFactory.ImplementationBlocked.selector);
        vm.prank(vaultOwner);
        factory.upgrade(proxy, vaultImpl2, abi.encode("Vault with Impl2", "Impl2Vault"));

        // should revert blocking an already blocked implementation
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.AlreadyBlocked.selector);
        factory.blockImplementation(vaultImpl2);
    }

    function testExplicitUpgradeToAndCall() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        vm.stopPrank();

        address proxy = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));

        assertEq(Impl1(proxy).implName(), "Vault with Impl1");

        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(VaultProxy.CallerNotProxyAdmin.selector));
        VaultProxy(payable(proxy)).upgradeToAndCall(impl2, abi.encode("Vault with Impl2", "Impl2Vault"));
    }

    function testBatchMigrateSuccess() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        // Create multiple vaults
        address[] memory vaults = new address[](3);
        vaults[0] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault1", "V1"));
        vaults[1] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault2", "V2"));
        vaults[2] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault3", "V3"));

        // Verify initial state
        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(Impl1(vaults[i]).implVersion(), vaultImpl1);
        }

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("BatchMigrated", string.concat("BM", Strings.toString(i)));
        }

        // Perform batch migration
        vm.prank(vaultOwner);
        factory.batchUpgrade(vaults, vaultImpl2, data);

        // Verify all vaults migrated successfully
        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(Impl2(vaults[i]).implVersion(), vaultImpl2);
            assertEq(Impl2(vaults[i]).implName(), "BatchMigrated");
            assertEq(Impl2(vaults[i]).implSymbol(), string.concat("BM", Strings.toString(i)));
        }
    }

    function testBatchMigrateSingleVault() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        address[] memory vaults = new address[](1);
        vaults[0] = factory.create(vaultImpl1, vaultOwner, abi.encode("SingleVault", "SV"));

        assertEq(Impl1(vaults[0]).implVersion(), vaultImpl1);

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("Migrated", string.concat("M", Strings.toString(i)));
        }

        // Perform batch migration
        vm.prank(vaultOwner);
        factory.batchUpgrade(vaults, vaultImpl2, data);

        assertEq(Impl2(vaults[0]).implVersion(), vaultImpl2);
        assertEq(Impl2(vaults[0]).implName(), "Migrated");
        assertEq(Impl2(vaults[0]).implSymbol(), "M0");
    }

    function testBatchMigrateFailsWithDifferentOwners() public {
        address vaultOwner1 = makeAddr("vaultOwner1");
        address vaultOwner2 = makeAddr("vaultOwner2");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        address[] memory vaults = new address[](2);
        vaults[0] = factory.create(vaultImpl1, vaultOwner1, abi.encode("Vault1", "V1"));
        vaults[1] = factory.create(vaultImpl1, vaultOwner2, abi.encode("Vault2", "V2"));

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("BatchMigrated", string.concat("BM", Strings.toString(i)));
        }

        // Should fail when trying to migrate vaults with different owners
        vm.expectRevert(IConcreteFactory.NotOwner.selector);
        vm.prank(vaultOwner1);
        factory.batchUpgrade(vaults, vaultImpl2, data);

        // Verify no vaults were migrated
        assertEq(IContractId(vaults[0]).ID(), vaultImpl1);
        assertEq(IContractId(vaults[1]).ID(), vaultImpl1);
    }

    function testBatchMigrateWithMixedVersions() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        address[] memory vaults = new address[](2);
        vaults[0] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault1", "V1"));
        vaults[1] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault2", "V2"));

        // Migrate first vault individually
        vm.prank(vaultOwner);
        factory.upgrade(vaults[0], vaultImpl2, abi.encode("FirstMigrated", "FM"));

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("BatchMigrated", string.concat("BM", Strings.toString(i)));
        }

        // Now try batch migrate both (should fail on first vault - already v2)
        vm.expectRevert(IConcreteFactory.OldVersion.selector);
        vm.prank(vaultOwner);
        factory.batchUpgrade(vaults, vaultImpl2, data);

        // Verify states
        assertEq(Impl2(vaults[0]).implVersion(), vaultImpl2);
        assertEq(Impl2(vaults[0]).implName(), "FirstMigrated");
        assertEq(Impl1(vaults[1]).implVersion(), vaultImpl1);
    }

    function testBatchMigrateWithBlockedImplementation() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        factory.blockImplementation(vaultImpl2); // Block version 2
        vm.stopPrank();

        address[] memory vaults = new address[](2);
        vaults[0] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault1", "V1"));
        vaults[1] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault2", "V2"));

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("BatchMigrated", string.concat("BM", Strings.toString(i)));
        }

        // Should fail due to blocked implementation
        vm.expectRevert(IConcreteFactory.ImplementationBlocked.selector);
        vm.prank(vaultOwner);
        factory.batchUpgrade(vaults, vaultImpl2, data);

        // Verify no vaults were migrated
        assertEq(Impl1(vaults[0]).implVersion(), vaultImpl1);
        assertEq(Impl1(vaults[1]).implVersion(), vaultImpl1);
    }

    function testBatchMigrateWithNonMigratableVersions() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        // Don't set migratable path
        vm.stopPrank();

        address[] memory vaults = new address[](2);
        vaults[0] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault1", "V1"));
        vaults[1] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault2", "V2"));

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("BatchMigrated", string.concat("BM", Strings.toString(i)));
        }

        // Should fail due to non-migratable versions
        vm.expectRevert(IConcreteFactory.CanNotMigrate.selector);
        vm.prank(vaultOwner);
        factory.batchUpgrade(vaults, vaultImpl2, data);

        // Verify no vaults were migrated
        assertEq(Impl1(vaults[0]).implVersion(), vaultImpl1);
        assertEq(Impl1(vaults[1]).implVersion(), vaultImpl1);
    }

    function testBatchMigrateWithInvalidVersion() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        vm.stopPrank();

        address[] memory vaults = new address[](1);
        vaults[0] = factory.create(vaultImpl1, vaultOwner, abi.encode("Vault1", "V1"));

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("BatchMigrated", string.concat("BM", Strings.toString(i)));
        }

        // Should fail due to invalid version (vault ID not approved)
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());
        vm.expectRevert(IConcreteFactory.InvalidVersion.selector);
        vm.prank(vaultOwner);
        factory.batchUpgrade(vaults, vaultImpl2, data);

        // Verify vault wasn't migrated
        assertEq(Impl1(vaults[0]).implVersion(), vaultImpl1);
    }

    function testRegisterVault() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new ExternalImpl(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        vm.stopPrank();

        // Create a vault through the factory
        address factoryVault = factory.create(vaultImpl1, vaultOwner, abi.encode("FactoryVault", "FV"));
        assertEq(factory.isRegisteredVault(factoryVault), true);

        // Create an external vault using the ExternalImpl, this mock proxy is pre-set to be owned by the factory
        // this external vault reports to be v1
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration memory defaultEnforcedVaultConfig =
            IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration({
                defaultManagementFeeRecipient: address(0), defaultPerformanceFeeRecipient: address(0)
            });
        address externalVault = address(
            new MockVaultProxy(
                address(factory),
                impl1,
                abi.encodeCall(
                    IUpgradeableVault.initialize,
                    (vaultImpl1, vaultOwner, defaultEnforcedVaultConfig, abi.encode("ExternalVault", "EV"))
                )
            )
        );

        // Verify the external vault is not registered initially
        assertEq(factory.isRegisteredVault(externalVault), false);

        // Register the external vault
        vm.prank(factoryOwner);
        factory.registerVault(externalVault);
        assertEq(factory.isRegisteredVault(externalVault), true);

        // Verify the vault can now be upgraded through the factory
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());
        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        vm.prank(vaultOwner);
        factory.upgrade(externalVault, vaultImpl2, abi.encode("ExternalVaultUpgraded", "EVU"));

        assertEq(Impl2(externalVault).implVersion(), vaultImpl2);
        assertEq(Impl2(externalVault).implName(), "ExternalVaultUpgraded");
    }

    function testRegisterVaultAlreadyRegistered() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        vm.stopPrank();

        // Create a vault through the factory
        address factoryVault = factory.create(vaultImpl1, vaultOwner, abi.encode("FactoryVault", "FV"));
        assertEq(factory.isRegisteredVault(factoryVault), true);

        // Try to register the same vault again
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.VaultAlreadyRegistered.selector);
        factory.registerVault(factoryVault);
    }

    function testRegisterVaultInvalidFactory() public {
        address vaultOwner = makeAddr("vaultOwner");

        // Create a temporary factory with a different address
        address differentFactoryImpl = address(new ConcreteFactory());
        address differentFactory = address(
            new ERC1967Proxy(
                differentFactoryImpl, abi.encodeCall(ConcreteFactory.initialize, (factoryOwner, address(0)))
            )
        );

        address impl1 = address(new Impl1(differentFactory));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        ConcreteFactory(differentFactory).approveImplementation(impl1);
        vm.stopPrank();

        // Create a vault with the different factory
        address externalVault =
            ConcreteFactory(differentFactory).create(vaultImpl1, vaultOwner, abi.encode("ExternalVault", "EV"));

        // Try to register a vault that doesn't belong to this factory
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.InvalidImplementation.selector);
        factory.registerVault(externalVault);
    }

    function testRegisterVaultNonOwner() public {
        address vaultOwner = makeAddr("vaultOwner");

        // Create a temporary factory
        address tempFactoryImpl = address(new ConcreteFactory());
        address tempFactory = address(
            new ERC1967Proxy(tempFactoryImpl, abi.encodeCall(ConcreteFactory.initialize, (factoryOwner, address(0))))
        );

        address impl1 = address(new Impl1(tempFactory));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        ConcreteFactory(tempFactory).approveImplementation(impl1);
        vm.stopPrank();

        // Create a vault with the temporary factory
        address externalVault =
            ConcreteFactory(tempFactory).create(vaultImpl1, vaultOwner, abi.encode("ExternalVault", "EV"));

        // Try to register as non-owner
        vm.prank(vaultOwner);
        vm.expectRevert();
        factory.registerVault(externalVault);
    }

    function testRegisterVaultZeroAddress() public {
        // Try to register zero address
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ZeroAddress.selector);
        factory.registerVault(address(0));
    }

    function testUpgradeNotAVault() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        // Create a vault through the factory
        factory.create(vaultImpl1, vaultOwner, abi.encode("FactoryVault", "FV"));

        // Create a random address that is not a vault
        address randomAddress = makeAddr("randomAddress");

        // Try to upgrade a non-vault address
        vm.prank(vaultOwner);
        vm.expectRevert(IConcreteFactory.NotRegisteredVault.selector);
        factory.upgrade(randomAddress, vaultImpl2, abi.encode("Upgrade", "U"));
    }

    function testBatchUpgradeInvalidDataLength() public {
        // create array of fake vaults
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault");
        bytes[] memory data = new bytes[](0);
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.expectRevert(IConcreteFactory.InvalidDataLength.selector);
        factory.batchUpgrade(vaults, vaultImpl2, data);
    }

    function testBatchUpgradeNotAVault() public {
        address vaultOwner = makeAddr("vaultOwner");
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        // Create a vault through the factory
        address factoryVault = factory.create(vaultImpl1, vaultOwner, abi.encode("FactoryVault", "FV"));

        // Create an array with a mix of valid vaults and invalid addresses
        address[] memory vaults = new address[](3);
        vaults[0] = factoryVault; // Valid vault
        vaults[1] = makeAddr("randomAddress1"); // Invalid address
        vaults[2] = makeAddr("randomAddress2"); // Invalid address

        bytes[] memory data = new bytes[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            data[i] = abi.encode("BatchUpgrade", string.concat("BU", Strings.toString(i)));
        }

        // Try to batch upgrade with invalid addresses
        vm.prank(vaultOwner);
        vm.expectRevert(IConcreteFactory.NotRegisteredVault.selector);
        factory.batchUpgrade(vaults, vaultImpl2, data);
    }

    // ============================================================================
    // DEFAULT FEE RECIPIENTS TESTS
    // ============================================================================

    function testSetDefaultEnforcedVaultConfiguration() public {
        address newMgmtRecipient = makeAddr("newMgmtRecipient");
        address newPerfRecipient = makeAddr("newPerfRecipient");

        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(newMgmtRecipient, newPerfRecipient);

        (address mgmtRecipient, address perfRecipient) = factory.getDefaultEnforcedVaultConfiguration();
        assertEq(mgmtRecipient, newMgmtRecipient, "Management fee recipient should be updated");
        assertEq(perfRecipient, newPerfRecipient, "Performance fee recipient should be updated");
    }

    function testSetDefaultEnforcedVaultConfigurationEmitsEvent() public {
        address newMgmtRecipient = makeAddr("newMgmtRecipient");
        address newPerfRecipient = makeAddr("newPerfRecipient");

        vm.expectEmit(true, true, false, false);
        emit IConcreteFactory.DefaultEnforcedVaultConfigurationUpdated(newMgmtRecipient, newPerfRecipient);

        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(newMgmtRecipient, newPerfRecipient);
    }

    function testSetDefaultEnforcedVaultConfigurationRevertsOnZeroAddress() public {
        address validRecipient = makeAddr("validRecipient");

        // Zero management fee recipient
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ZeroAddress.selector);
        factory.setDefaultEnforcedVaultConfiguration(address(0), validRecipient);

        // Zero performance fee recipient
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ZeroAddress.selector);
        factory.setDefaultEnforcedVaultConfiguration(validRecipient, address(0));
    }

    // ============================================================================
    // TWO-STEP OWNERSHIP TESTS
    // ============================================================================

    function test_transferOwnership_setsPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        assertEq(factory.owner(), factoryOwner);
        assertEq(Ownable2StepUpgradeable(address(factory)).pendingOwner(), address(0));

        vm.expectEmit(true, true, false, false);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(factoryOwner, newOwner);

        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        // owner unchanged until accepted
        assertEq(factory.owner(), factoryOwner);
        assertEq(Ownable2StepUpgradeable(address(factory)).pendingOwner(), newOwner);
    }

    function test_acceptOwnership_completesTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, false);
        emit OwnableUpgradeable.OwnershipTransferred(factoryOwner, newOwner);

        vm.prank(newOwner);
        Ownable2StepUpgradeable(address(factory)).acceptOwnership();

        assertEq(factory.owner(), newOwner);
        assertEq(Ownable2StepUpgradeable(address(factory)).pendingOwner(), address(0));
    }

    function test_transferOwnership_revertsForNonOwner() public {
        address newOwner = makeAddr("newOwner");
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.transferOwnership(newOwner);
    }

    function test_acceptOwnership_revertsForNonPendingOwner() public {
        address newOwner = makeAddr("newOwner");
        address nonOwner = makeAddr("nonOwner");

        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        Ownable2StepUpgradeable(address(factory)).acceptOwnership();
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.RenounceOwnershipDisabled.selector);
        factory.renounceOwnership();
    }

    // ============================================================================
    // FACTORY MANAGER ROLE TESTS
    // ============================================================================

    function test_setFactoryManager_byOwner() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, false);
        emit IConcreteFactory.FactoryManagerSet(factoryOwner, newManager);

        vm.prank(factoryOwner);
        factory.setFactoryManager(newManager);

        assertEq(factory.getFactoryManager(), newManager);
    }

    function test_setFactoryManager_revertsForNonOwner() public {
        address newManager = makeAddr("newManager");
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.setFactoryManager(newManager);
    }

    function test_setFactoryManager_revertsOnZeroAddress() public {
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.ZeroAddress.selector);
        factory.setFactoryManager(address(0));
    }

    function test_managerFunction_succeedsForManager() public {
        address manager = makeAddr("manager");
        vm.prank(factoryOwner);
        factory.setFactoryManager(manager);

        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.prank(manager);
        factory.approveImplementation(impl1);

        assertEq(factory.getImplementationByVaultImpl(vaultImpl1), impl1);
    }

    function test_managerFunction_revertsForOwnerWhenSeparate() public {
        // Assign a manager distinct from the owner to enforce strict separation.
        address manager = makeAddr("manager");
        vm.prank(factoryOwner);
        factory.setFactoryManager(manager);

        address impl1 = address(new Impl1(address(factory)));

        // Owner can no longer call manager-gated functions.
        vm.prank(factoryOwner);
        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.approveImplementation(impl1);
    }

    function test_managerFunctions_revertForNonManager() public {
        address manager = makeAddr("manager");
        vm.prank(factoryOwner);
        factory.setFactoryManager(manager);

        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        address externalVault = makeAddr("externalVault");
        address stranger = makeAddr("stranger");

        vm.startPrank(stranger);
        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.approveImplementation(impl1);

        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.setMigratable(vaultImpl1, vaultImpl1);

        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.setMigratableByAddress(impl1, impl1);

        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.blockImplementation(vaultImpl1);

        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.blockImplementationByAddress(impl1);

        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.registerVault(externalVault);
        vm.stopPrank();
    }

    /* ----------------------------------------------------------------------- */
    /*                       UNBLOCK / UNSET-MIGRATABLE                         */
    /* ----------------------------------------------------------------------- */

    function testUnblockImplementation() public {
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.blockImplementation(vaultImpl1);
        assertEq(factory.isBlocked(vaultImpl1), true);

        vm.expectEmit(true, false, false, false);
        emit IConcreteFactory.Unblocked(vaultImpl1);
        factory.unblockImplementation(vaultImpl1);
        vm.stopPrank();

        assertEq(factory.isBlocked(vaultImpl1), false);

        // a previously-blocked impl can deploy again after unblocking
        address vaultOwner = makeAddr("vaultOwner");
        factory.create(vaultImpl1, vaultOwner, abi.encode("Vault with Impl1", "Impl1Vault"));
    }

    function testUnblockImplementation_NotBlocked() public {
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);

        vm.expectRevert(IConcreteFactory.NotBlocked.selector);
        factory.unblockImplementation(vaultImpl1);
        vm.stopPrank();
    }

    function testUnblockImplementation_revertsForNonOwner() public {
        address impl1 = address(new Impl1(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.blockImplementation(vaultImpl1);
        vm.stopPrank();

        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert();
        factory.unblockImplementation(vaultImpl1);
    }

    function testUnsetMigratable() public {
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        assertEq(factory.isMigratable(vaultImpl1, vaultImpl2), true);

        vm.expectEmit(true, true, false, false);
        emit IConcreteFactory.MigratableUnset(vaultImpl1, vaultImpl2);
        factory.unsetMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        assertEq(factory.isMigratable(vaultImpl1, vaultImpl2), false);
    }

    function testUnsetMigratable_NotMigratable() public {
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);

        vm.expectRevert(IConcreteFactory.NotMigratable.selector);
        factory.unsetMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();
    }

    function testUnsetMigratable_revertsForNonManager() public {
        address impl1 = address(new Impl1(address(factory)));
        address impl2 = address(new Impl2(address(factory)));
        uint64 vaultImpl1 = uint64(IContractId(impl1).ID());
        uint64 vaultImpl2 = uint64(IContractId(impl2).ID());

        vm.startPrank(factoryOwner);
        factory.approveImplementation(impl1);
        factory.approveImplementation(impl2);
        factory.setMigratable(vaultImpl1, vaultImpl2);
        vm.stopPrank();

        vm.prank(makeAddr("nonManager"));
        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.unsetMigratable(vaultImpl1, vaultImpl2);
    }
}

contract Impl1 is ConcreteStandardVaultImpl {
    string public implName;
    string public implSymbol;
    uint64 public implVersion;

    constructor(address factory) ConcreteStandardVaultImpl(factory) {}

    function _initialize(
        uint64 initialVersion,
        address,
        /*owner*/
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata,
        /*defaultEnforcedVaultConfig*/
        bytes memory data
    ) internal virtual override {
        (string memory name, string memory symbol) = abi.decode(data, (string, string));

        implName = name;
        implSymbol = symbol;
        implVersion = initialVersion;
    }

    function _upgrade(
        uint64,
        /* newVaultImpl */
        bytes calldata /* data */
    )
        internal
        virtual
        override
    {
        revert();
    }

    function ID() public pure virtual override(ConcreteStandardVaultImpl) returns (uint64) {
        return ContractIdEncoding.encode(
            0,
            /* contractType=vault */
            1,
            /* flavour=standard-vault */
            9,
            /* majorVersion=9 (test) */
            98,
            /* minorVersion=98 (test) */
            98 /* patchVersion=98 (test) */
        );
    }
}

contract Impl2 is Impl1 {
    constructor(address factory) Impl1(factory) {}

    function _initialize(
        uint64 initialVersion,
        address,
        /*owner*/
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata,
        /*defaultEnforcedVaultConfig*/
        bytes memory data
    ) internal virtual override {
        (string memory name, string memory symbol) = abi.decode(data, (string, string));

        implName = name;
        implSymbol = symbol;
        implVersion = initialVersion;
    }

    function _upgrade(uint64 newVersion, bytes calldata data) internal virtual override {
        (string memory name, string memory symbol) = abi.decode(data, (string, string));

        implName = name;
        implSymbol = symbol;
        implVersion = newVersion;
    }

    function ID() public pure virtual override(Impl1) returns (uint64) {
        return ContractIdEncoding.encode(
            0,
            /* contractType=vault */
            1,
            /* flavour=standard-vault */
            9,
            /* majorVersion=9 (test) */
            99,
            /* minorVersion=99 (test) */
            99 /* patchVersion=99 (test) */
        );
    }
}

contract ImplZeroId is Impl1 {
    constructor(address factory) Impl1(factory) {}

    function ID() public pure override returns (uint64) {
        return 0;
    }
}

contract ExternalImpl is OwnableUpgradeable, IContractId {
    string public implName;
    string public implSymbol;
    uint64 public implVersion;

    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function initialize(
        uint64,
        /**
         * initialVersion
         */
        address owner_,
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata,
        /**
         * defaultEnforcedVaultConfig
         */
        bytes calldata
    )
        /**
         * data
         */
        external
        initializer
    {
        __Ownable_init(owner_);
    }

    function upgrade(uint64 newVaultImpl, bytes calldata data) external {}

    function ID() public pure virtual override(IContractId) returns (uint64) {
        return ContractIdEncoding.encode(
            0,
            /* contractType=vault */
            1,
            /* flavour=external-vault */
            9,
            /* majorVersion=9 (test) */
            98,
            /* minorVersion=98 (test) */
            98 /* patchVersion=99 (test) */
        );
    }
}

contract MockVaultProxy is ERC1967Proxy, IVaultProxy {
    // An immutable address for the admin to avoid unnecessary SLOADs before each call.
    address private immutable _admin;

    /**
     * @dev The proxy caller is the current admin, and can't fallback to the proxy target.
     */
    error ProxyDeniedAdminAccess();

    /**
     * @dev Initializes an upgradeable proxy managed by `msg.sender`,
     * backed by the implementation at `logic`, and optionally initialized with `data` as explained in
     * {ERC1967Proxy-constructor}.
     */
    constructor(address admin, address logic, bytes memory data) ERC1967Proxy(logic, data) {
        _admin = admin;
        // Set the storage value and emit an event for ERC-1967 compatibility
        ERC1967Utils.changeAdmin(_proxyAdmin());
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data) external {
        if (msg.sender != _proxyAdmin()) {
            revert ProxyDeniedAdminAccess();
        }

        ERC1967Utils.upgradeToAndCall(newImplementation, data);
    }

    /**
     * @dev Returns the admin of this proxy.
     */
    function _proxyAdmin() internal view returns (address) {
        return _admin;
    }
}
