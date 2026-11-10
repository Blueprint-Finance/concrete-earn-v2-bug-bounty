// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {IDefaultEnforcedVaultConfiguration} from "../../../src/interface/IDefaultEnforcedVaultConfiguration.sol";
import {IUpgradeableVault} from "../../../src/interface/IUpgradeableVault.sol";
import {VaultProxy} from "../../../src/factory/VaultProxy.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

contract InitializationUnitTest is Test {
    ConcreteStandardVaultImpl public concreteStandardVaultImpl;
    address public owner = makeAddr("owner");
    address public factoryOwner = makeAddr("factoryOwner");
    address public allocateModule = makeAddr("allocateModule");
    address public asset = makeAddr("asset");
    address public initialVaultManager = makeAddr("initialVaultManager");
    address public managementFeeRecipient = makeAddr("managementFeeRecipient");
    address public performanceFeeRecipient = makeAddr("performanceFeeRecipient");
    string public name = "name";
    string public symbol = "symbol";
    IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration public defaultEnforcedVaultConfig;

    function setUp() public {
        concreteStandardVaultImpl = new ConcreteStandardVaultImpl(address(this));
        defaultEnforcedVaultConfig = IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration({
            defaultManagementFeeRecipient: managementFeeRecipient,
            defaultPerformanceFeeRecipient: performanceFeeRecipient
        });
    }

    function testInitialize() public {
        bytes memory data = abi.encode(allocateModule, asset, initialVaultManager, name, symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        VaultProxy vaultProxy = new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );

        IConcreteStandardVaultImpl newConcreteStandardVaultImpl = IConcreteStandardVaultImpl(address(vaultProxy));
        address allocateModuleAddr = newConcreteStandardVaultImpl.allocateModule();
        assertEq(allocateModuleAddr, allocateModule, "allocateModuleAddr");

        address assetAddr = newConcreteStandardVaultImpl.asset();
        assertEq(assetAddr, asset, "assetAddr");

        (uint256 maxDepositAmount, uint256 minDepositAmount) = newConcreteStandardVaultImpl.getDepositLimits();
        assertEq(maxDepositAmount, type(uint256).max);
        assertEq(minDepositAmount, 0);
    }

    function testInitializeRevertsIfInvalidAllocateModule() public {
        bytes memory data = abi.encode(address(0), asset, initialVaultManager, name, symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidAllocateModule.selector));
        new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );
    }

    function testInitializeRevertsIfInvalidAsset() public {
        bytes memory data = abi.encode(allocateModule, address(0), initialVaultManager, name, symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidAsset.selector));
        new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );
    }

    function testInitializeRevertsIfInvalidInitialVaultManager() public {
        bytes memory data = abi.encode(allocateModule, asset, address(0), name, symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidInitialVaultManager.selector));
        new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );
    }

    function testInitializeRevertsIfInvalidName() public {
        bytes memory data = abi.encode(allocateModule, asset, initialVaultManager, "", symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidName.selector));
        new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );
    }

    function testInitializeRevertsIfInvalidSymbol() public {
        bytes memory data = abi.encode(allocateModule, asset, initialVaultManager, name, "");
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidSymbol.selector));
        new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );
    }

    // ============================================================================
    // DEFAULT FEE RECIPIENTS TESTS
    // ============================================================================

    function testInitializeSetsDefaultFeeRecipients() public {
        bytes memory data = abi.encode(allocateModule, asset, initialVaultManager, name, symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        VaultProxy vaultProxy = new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );

        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(address(vaultProxy));

        // Verify management fee recipient is set from defaultEnforcedVaultConfig
        (, address mgmtRecipient,,,) = vault.getFeeConfig();
        assertEq(mgmtRecipient, managementFeeRecipient, "Management fee recipient should be set from default config");

        // Verify performance fee recipient is set from defaultEnforcedVaultConfig
        (,,,, address perfRecipient) = vault.getFeeConfig();
        assertEq(perfRecipient, performanceFeeRecipient, "Performance fee recipient should be set from default config");
    }

    function testInitializeWithDifferentFeeRecipients() public {
        address customMgmtRecipient = makeAddr("customMgmtRecipient");
        address customPerfRecipient = makeAddr("customPerfRecipient");

        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration memory customFeeConfig =
            IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration({
                defaultManagementFeeRecipient: customMgmtRecipient, defaultPerformanceFeeRecipient: customPerfRecipient
            });

        bytes memory data = abi.encode(allocateModule, asset, initialVaultManager, name, symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        VaultProxy vaultProxy = new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, customFeeConfig, data))
        );

        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(address(vaultProxy));

        (, address mgmtRecipient,,,) = vault.getFeeConfig();
        assertEq(mgmtRecipient, customMgmtRecipient, "Custom management fee recipient should be set");

        (,,,, address perfRecipient) = vault.getFeeConfig();
        assertEq(perfRecipient, customPerfRecipient, "Custom performance fee recipient should be set");
    }

    function testInitializeEmitsFeeRecipientEvents() public {
        bytes memory data = abi.encode(allocateModule, asset, initialVaultManager, name, symbol);
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());

        // Expect management fee recipient updated event
        vm.expectEmit(true, false, false, false);
        emit IConcreteStandardVaultImpl.ManagementFeeRecipientUpdated(managementFeeRecipient);

        // Expect performance fee recipient updated event
        vm.expectEmit(true, false, false, false);
        emit IConcreteStandardVaultImpl.PerformanceFeeRecipientUpdated(performanceFeeRecipient);

        new VaultProxy(
            address(concreteStandardVaultImpl),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );
    }
}
