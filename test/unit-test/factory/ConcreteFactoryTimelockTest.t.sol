// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IConcreteFactory, ConcreteFactory, ConcreteFactoryBaseSetup} from "../../common/ConcreteFactoryBaseSetup.t.sol";

import {MockTimelock} from "../../mocks/MockTimelock.sol";
import {TimelockIntegrationLib} from "../../../src/lib/TimelockIntegrationLib.sol";

contract ConcreteFactoryTimelockTest is ConcreteFactoryBaseSetup {
    MockTimelock public mockTimelock;

    function setUp() public override {
        ConcreteFactoryBaseSetup.setUp();
        mockTimelock = new MockTimelock();
    }

    // ── setTimelock ───────────────────────────────────────────────────────────

    function testSetTimelock() public {
        vm.prank(factoryOwner);
        factory.setTimelock(address(mockTimelock));

        (address tl, bool active) = factory.getTimelock();
        assertEq(tl, address(mockTimelock));
        assertFalse(active);
    }

    // ── activateTimelock ──────────────────────────────────────────────────────

    function testActivateTimelock() public {
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock();
        vm.stopPrank();

        (, bool active) = factory.getTimelock();
        assertTrue(active);
    }

    function testActivateTimelockRevertsIfAlreadyActive() public {
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock();
        vm.expectRevert(TimelockIntegrationLib.TimelockAlreadyActive.selector);
        factory.activateTimelock();
        vm.stopPrank();
    }

    // ── Timelock-gated function (transferOwnership) ───────────────────────────

    function testTimelockGatedTransferOwnership() public {
        // 1. Wire up and activate the timelock
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock();
        mockTimelock.activateTimelock();
        vm.stopPrank();

        // 2. Propose the action on the timelock
        address newOwner = makeAddr("newOwner");
        bytes4 selector = ConcreteFactory.transferOwnership.selector;
        bytes memory args = abi.encode(newOwner);
        mockTimelock.propose(address(factory), selector, args);

        // 3. Warp past the delay
        vm.warp(block.timestamp + mockTimelock.DELAY() + 1);

        // 4. Execute — afterDelay modifier validates and consumes the schedule entry.
        //    Ownable2Step: this only sets the pending owner.
        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        // 5. New owner accepts ownership (two-step flow).
        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
    }

    function testTimelockGatedFunctionRevertsBeforeDelay() public {
        // Wire up and activate
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock();
        mockTimelock.activateTimelock();
        vm.stopPrank();

        // Propose but do NOT warp
        address newOwner = makeAddr("newOwner");
        bytes4 selector = ConcreteFactory.transferOwnership.selector;
        bytes memory args = abi.encode(newOwner);
        mockTimelock.propose(address(factory), selector, args);

        // Attempt execution before delay — should revert from MockTimelock
        vm.prank(factoryOwner);
        vm.expectRevert("MockTimelock: not ready");
        factory.transferOwnership(newOwner);
    }

    function testTimelockGatedFunctionRevertsWithoutProposal() public {
        // Wire up and activate
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock();
        mockTimelock.activateTimelock();
        vm.stopPrank();

        // No propose — attempt execution directly
        address newOwner = makeAddr("newOwner");
        vm.prank(factoryOwner);
        vm.expectRevert("MockTimelock: unknown action");
        factory.transferOwnership(newOwner);
    }

    function testGatedFunctionPassesBeforeTimelockActivated() public {
        // Timelock set on factory but NOT yet activated on MockTimelock
        // (factory.activateTimelock called, but mockTimelock.activateTimelock() not called)
        // checkDelayExpired returns early — gated function executes freely
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock(); // factory enforcement is active...
        // ...but mockTimelock.active == false, so checkDelayExpired is a no-op
        vm.stopPrank();

        address newOwner = makeAddr("newOwner");
        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner); // passes without proposal (sets pending owner)

        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
    }
}
