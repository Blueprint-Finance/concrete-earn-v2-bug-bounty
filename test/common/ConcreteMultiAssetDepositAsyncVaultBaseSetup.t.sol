// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ConcreteFactoryBaseSetup} from "./ConcreteFactoryBaseSetup.t.sol";
import {ConcreteMultiAssetDepositAsyncVault} from "../../src/implementation/ConcreteMultiAssetDepositAsyncVault.sol";
import {IConcreteMultiAssetDepositAsyncVault} from "../../src/interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {AllocateModule} from "../../src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../src/lib/Roles.sol";
import {IContractId} from "../../src/interface/IContractId.sol";

contract ConcreteMultiAssetDepositAsyncVaultBaseSetup is ConcreteFactoryBaseSetup {
    address public vaultOwner;
    address public vaultManager;
    address public hookManager;
    address public strategyOperator;
    address public allocator;
    address public withdrawalManager;

    ERC20Mock public asset;
    ERC20Mock public otherAsset;
    AllocateModule public allocateModule;

    ConcreteMultiAssetDepositAsyncVault public multiAssetVaultImpl;
    ConcreteMultiAssetDepositAsyncVault public multiAssetVault;

    function setUp() public virtual override {
        ConcreteFactoryBaseSetup.setUp();

        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        hookManager = makeAddr("hookManager");
        strategyOperator = makeAddr("strategyOperator");
        allocator = makeAddr("allocator");
        withdrawalManager = makeAddr("withdrawalManager");

        // Register the multi-asset deposit async vault implementation on the factory.
        multiAssetVaultImpl = new ConcreteMultiAssetDepositAsyncVault(address(factory));
        vm.prank(factoryOwner);
        factory.approveImplementation(address(multiAssetVaultImpl));
        uint64 vaultImpl = uint64(IContractId(address(multiAssetVaultImpl)).ID());
        assertEq(factory.getImplementationByVaultImpl(vaultImpl), address(multiAssetVaultImpl));

        asset = new ERC20Mock();
        otherAsset = new ERC20Mock();
        allocateModule = new AllocateModule();

        multiAssetVault = ConcreteMultiAssetDepositAsyncVault(
            factory.create(
                vaultImpl,
                vaultOwner,
                abi.encode(
                    address(allocateModule), address(asset), vaultManager, "Concrete MultiAsset Vault", "CMAVault"
                )
            )
        );

        vm.label(address(factory), "factory");
        vm.label(address(allocateModule), "allocateModule");
        vm.label(address(multiAssetVault), "multiAssetVault");
        vm.label(address(asset), "asset");
        vm.label(address(otherAsset), "otherAsset");

        assertEq(multiAssetVault.asset(), address(asset));
        assertEq(multiAssetVault.name(), "Concrete MultiAsset Vault");
        assertEq(multiAssetVault.symbol(), "CMAVault");
        assertEq(multiAssetVault.allocateModule(), address(allocateModule));

        vm.startPrank(vaultManager);
        multiAssetVault.grantRole(RolesLib.STRATEGY_MANAGER, strategyOperator);
        multiAssetVault.grantRole(RolesLib.ALLOCATOR, allocator);
        multiAssetVault.grantRole(RolesLib.HOOK_MANAGER, hookManager);
        multiAssetVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, withdrawalManager);
        multiAssetVault.grantRole(RolesLib.PRIORITY_WITHDRAWAL_EXECUTOR, withdrawalManager);
        vm.stopPrank();
    }
}
