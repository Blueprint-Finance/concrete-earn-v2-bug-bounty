// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IConcreteFactory, ConcreteFactory, VaultProxy} from "../../src/factory/ConcreteFactory.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ConcreteFactoryBaseSetup is Test {
    address public factoryOwner;
    address public defaultManagementFeeRecipient;
    address public defaultPerformanceFeeRecipient;

    ConcreteFactory public factory;

    function setUp() public virtual {
        factoryOwner = makeAddr("factoryOwner");
        defaultManagementFeeRecipient = makeAddr("defaultManagementFeeRecipient");
        defaultPerformanceFeeRecipient = makeAddr("defaultPerformanceFeeRecipient");

        vm.prank(factoryOwner);
        address factoryImpl = address(new ConcreteFactory());
        factory = ConcreteFactory(
            address(new ERC1967Proxy(factoryImpl, abi.encodeCall(ConcreteFactory.initialize, (factoryOwner))))
        );

        // Set default configuration
        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(defaultManagementFeeRecipient, defaultPerformanceFeeRecipient);
    }
}
