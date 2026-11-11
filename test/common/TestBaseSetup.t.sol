// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IConcreteFactory, ConcreteFactoryBaseSetup, VaultProxy} from "./ConcreteFactoryBaseSetup.t.sol";
import {
    IConcreteStandardVaultImpl,
    ConcreteStandardVaultImpl
} from "../../src/implementation/ConcreteStandardVaultImpl.sol";
import {IContractId} from "../../src/interface/IContractId.sol";

contract TestBaseSetup is ConcreteFactoryBaseSetup {
    ConcreteStandardVaultImpl public concreteStandardVaultImpl;

    function setUp() public virtual override {
        ConcreteFactoryBaseSetup.setUp();

        concreteStandardVaultImpl = new ConcreteStandardVaultImpl(address(factory));

        vm.startPrank(factoryOwner);
        factory.approveImplementation(address(concreteStandardVaultImpl));
        vm.stopPrank();
        uint64 contractId = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        assertEq(factory.getImplementationByVaultImpl(contractId), address(concreteStandardVaultImpl));

        vm.label(address(factory), "factory");
        vm.label(address(factoryOwner), "factoryOwner");
        vm.label(address(concreteStandardVaultImpl), "concreteStandardVaultImpl");
    }
}
