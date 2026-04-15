// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteFactoryBaseSetup} from "./ConcreteFactoryBaseSetup.t.sol";
import {ConcreteBridgedStandardVaultImpl} from "../../src/implementation/ConcreteBridgedStandardVaultImpl.sol";
import {IConcreteBridgedStandardVaultImpl} from "../../src/interface/IConcreteBridgedStandardVaultImpl.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {AllocateModule} from "../../src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../src/lib/Roles.sol";
import {IContractId} from "../../src/interface/IContractId.sol";

contract TestBaseBridgedStandardSetup is ConcreteFactoryBaseSetup {
    ConcreteBridgedStandardVaultImpl public concreteBridgedStandardVaultImpl;

    function setUp() public virtual override {
        ConcreteFactoryBaseSetup.setUp();

        concreteBridgedStandardVaultImpl = new ConcreteBridgedStandardVaultImpl(address(factory));

        vm.startPrank(factoryOwner);
        factory.approveImplementation(address(concreteBridgedStandardVaultImpl));
        vm.stopPrank();

        uint64 contractId = uint64(IContractId(address(concreteBridgedStandardVaultImpl)).ID());
        assertEq(factory.getImplementationByVaultImpl(contractId), address(concreteBridgedStandardVaultImpl));

        vm.label(address(factory), "factory");
        vm.label(address(factoryOwner), "factoryOwner");
        vm.label(address(concreteBridgedStandardVaultImpl), "concreteBridgedStandardVaultImpl");
    }
}

contract ConcreteBridgedStandardVaultImplBaseSetup is TestBaseBridgedStandardSetup {
    address public vaultOwner;
    address public vaultManager;
    address public hookManager;
    address public strategyOperator;
    address public allocator;

    ERC20Mock public asset;
    AllocateModule public allocateModule;
    ConcreteBridgedStandardVaultImpl public concreteBridgedStandardVault;

    function setUp() public virtual override {
        TestBaseBridgedStandardSetup.setUp();

        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        hookManager = makeAddr("hookManager");
        strategyOperator = makeAddr("strategyOperator");
        allocator = makeAddr("allocator");

        asset = new ERC20Mock();
        allocateModule = new AllocateModule();

        uint64 vaultImpl = uint64(IContractId(address(concreteBridgedStandardVaultImpl)).ID());
        concreteBridgedStandardVault = ConcreteBridgedStandardVaultImpl(
            factory.create(
                vaultImpl,
                vaultOwner,
                abi.encode(
                    address(allocateModule), address(asset), vaultManager, "Concrete Bridged Standard Vault", "CBSVault"
                )
            )
        );

        vm.label(address(allocateModule), "allocateModule");
        vm.label(address(concreteBridgedStandardVault), "concreteBridgedStandardVault");
        vm.label(address(asset), "asset");

        assertEq(concreteBridgedStandardVault.asset(), address(asset));
        assertEq(concreteBridgedStandardVault.name(), "Concrete Bridged Standard Vault");
        assertEq(concreteBridgedStandardVault.symbol(), "CBSVault");
        assertEq(concreteBridgedStandardVault.allocateModule(), address(allocateModule));

        // Grant roles
        vm.startPrank(vaultManager);
        concreteBridgedStandardVault.grantRole(RolesLib.STRATEGY_MANAGER, strategyOperator);
        concreteBridgedStandardVault.grantRole(RolesLib.ALLOCATOR, allocator);
        concreteBridgedStandardVault.grantRole(RolesLib.HOOK_MANAGER, hookManager);
        // Set deposit limits to 0 for unbackedMint to work
        concreteBridgedStandardVault.setDepositLimits(0, 0);
        vm.stopPrank();
    }
}

