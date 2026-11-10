// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IConcreteFactory, ConcreteFactoryBaseSetup, VaultProxy} from "./ConcreteFactoryBaseSetup.t.sol";
import {IConcreteAsyncVaultImpl, ConcreteAsyncVaultImpl} from "../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {IContractId} from "../../src/interface/IContractId.sol";

contract TestBaseAsyncSetup is ConcreteFactoryBaseSetup {
    ConcreteAsyncVaultImpl public concreteAsyncVaultImpl;

    function setUp() public virtual override {
        ConcreteFactoryBaseSetup.setUp();

        concreteAsyncVaultImpl = new ConcreteAsyncVaultImpl(address(factory));

        vm.startPrank(factoryOwner);
        factory.approveImplementation(address(concreteAsyncVaultImpl));
        vm.stopPrank();
        uint64 contractId = uint64(IContractId(address(concreteAsyncVaultImpl)).ID());
        assertEq(factory.getImplementationByVaultImpl(contractId), address(concreteAsyncVaultImpl));

        vm.label(address(factory), "factory");
        vm.label(address(factoryOwner), "factoryOwner");
        vm.label(address(concreteAsyncVaultImpl), "concreteAsyncVaultImpl");
    }
}
