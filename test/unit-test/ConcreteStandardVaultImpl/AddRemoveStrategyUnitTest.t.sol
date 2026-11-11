// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {IStrategyTemplate} from "../../../src/interface/IStrategyTemplate.sol";
import {ERC20Mock} from "../../mock/ERC20Mock.sol";
import {ERC4626StrategyMock} from "../../mock/ERC4626StrategyMock.sol";
import {AddStrategyWithDeallocationOrder} from "../../common/AddStrategyWithDeallocationOrder.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

contract AddRemoveStrategyUnitTest is ConcreteStandardVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    ERC4626StrategyMock public strategy;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();

        strategy = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
    }

    function testAddStrategy() public {
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        address[] memory strategies = concreteStandardVault.getStrategies();
        assertEq(strategies.length, 1);
        assertEq(strategies[0], address(strategy));

        IConcreteStandardVaultImpl.StrategyData memory strategyData =
            concreteStandardVault.getStrategyData(address(strategy));
        assertEq(strategyData.allocated, 0);
        assertEq(uint8(strategyData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Active));

        // should revert when adding existing strategy
        vm.startPrank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyAlreadyAdded.selector);
        concreteStandardVault.addStrategy(address(strategy));
        vm.stopPrank();

        // should revert when adding strategy with different vault
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IStrategyTemplate.getVault.selector),
            abi.encode(address(new ERC20Mock()))
        );
        vm.startPrank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.InvalidStrategyVault.selector);
        concreteStandardVault.addStrategy(address(strategy));
        vm.stopPrank();

        // should revert when adding strategy with different asset
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IStrategyTemplate.asset.selector),
            abi.encode(address(new ERC20Mock()))
        );
        vm.startPrank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.InvalidStrategyAsset.selector);
        concreteStandardVault.addStrategy(address(strategy));
        vm.stopPrank();
    }

    function testRemoveStrategy() public {
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        // Remove strategy from deallocation order first
        address[] memory emptyOrder = new address[](0);
        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(emptyOrder);

        vm.startPrank(strategyOperator);
        concreteStandardVault.removeStrategy(address(strategy));
        vm.stopPrank();

        // should revert when removing non-existent strategy
        vm.startPrank(strategyOperator);
        vm.expectRevert(IConcreteStandardVaultImpl.StrategyDoesNotExist.selector);
        concreteStandardVault.removeStrategy(address(strategy));
        vm.stopPrank();
    }

    function testToggleStrategyStatus() public {
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        // Toggle strategy status to Halted
        vm.startPrank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(strategy));
        vm.stopPrank();

        IConcreteStandardVaultImpl.StrategyData memory strategyData =
            concreteStandardVault.getStrategyData(address(strategy));
        assertEq(uint8(strategyData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Halted));

        // Toggle back to Active
        vm.startPrank(strategyOperator);
        concreteStandardVault.toggleStrategyStatus(address(strategy));
        vm.stopPrank();

        strategyData = concreteStandardVault.getStrategyData(address(strategy));
        assertEq(uint8(strategyData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Active));
    }

    function testPausePreventsAddStrategy() public {
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        vm.prank(strategyOperator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.addStrategy(address(strategy));
    }

    function testPausePreventsRemoveStrategy() public {
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        // Remove strategy from deallocation order first
        address[] memory emptyOrder = new address[](0);
        vm.prank(allocator);
        concreteStandardVault.setDeallocationOrder(emptyOrder);

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        vm.prank(strategyOperator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.removeStrategy(address(strategy));
    }

    function testPausePreventsToggleStrategyStatus() public {
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        vm.prank(strategyOperator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.toggleStrategyStatus(address(strategy));
    }

    function testPausePreventsSetDeallocationOrder() public {
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        address[] memory emptyOrder = new address[](0);
        vm.prank(allocator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.setDeallocationOrder(emptyOrder);
    }
}
