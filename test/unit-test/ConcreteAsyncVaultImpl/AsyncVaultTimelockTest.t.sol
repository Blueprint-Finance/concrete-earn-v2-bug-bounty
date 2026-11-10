// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteAsyncVaultImplBaseSetup} from "../../common/ConcreteAsyncVaultImplBaseSetup.t.sol";
import {ConcreteAsyncVaultImpl} from "../../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
import {MockTimelock} from "../../mocks/MockTimelock.sol";
import {TimelockIntegrationLib} from "../../../src/lib/TimelockIntegrationLib.sol";

contract AsyncVaultTimelockTest is ConcreteAsyncVaultImplBaseSetup {
    MockTimelock public mockTimelock;

    function setUp() public override {
        ConcreteAsyncVaultImplBaseSetup.setUp();
        mockTimelock = new MockTimelock();
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// Wires the timelock to the vault and activates enforcement on both sides.
    function _activateFull() internal {
        vm.startPrank(vaultOwner);
        concreteAsyncVault.setTimelock(address(mockTimelock));
        concreteAsyncVault.activateTimelock();
        mockTimelock.activateTimelock();
        vm.stopPrank();
    }

    /// Proposes an action and warps past the delay.
    function _proposeAndWarp(bytes4 selector, bytes memory args) internal {
        mockTimelock.propose(address(concreteAsyncVault), selector, args);
        vm.warp(block.timestamp + mockTimelock.DELAY() + 1);
    }

    // ── setTimelock ───────────────────────────────────────────────────────────

    function testSetTimelock() public {
        vm.prank(vaultOwner);
        concreteAsyncVault.setTimelock(address(mockTimelock));

        (address tl, bool active) = concreteAsyncVault.getTimelock();
        assertEq(tl, address(mockTimelock));
        assertFalse(active);
    }

    // ── activateTimelock ──────────────────────────────────────────────────────

    function testActivateTimelock() public {
        vm.startPrank(vaultOwner);
        concreteAsyncVault.setTimelock(address(mockTimelock));
        concreteAsyncVault.activateTimelock();
        vm.stopPrank();

        (, bool active) = concreteAsyncVault.getTimelock();
        assertTrue(active);
    }

    // ── transferOwnership ─────────────────────────────────────────────────────

    function testTimelockGatedTransferOwnership() public {
        _activateFull();

        address newOwner = makeAddr("newOwner");
        _proposeAndWarp(ConcreteStandardVaultImpl.transferOwnership.selector, abi.encode(newOwner));

        // Ownable2Step: transferOwnership only sets the pending owner.
        vm.prank(vaultOwner);
        concreteAsyncVault.transferOwnership(newOwner);

        vm.prank(newOwner);
        concreteAsyncVault.acceptOwnership();

        assertEq(concreteAsyncVault.owner(), newOwner);
    }

    // ── setUnwindCostCap (async-specific gated function) ──────────────────────

    function testTimelockGatedSetUnwindCostCap() public {
        _activateFull();

        uint16 newCap = 300;
        _proposeAndWarp(ConcreteAsyncVaultImpl.setUnwindCostCap.selector, abi.encode(newCap));

        vm.prank(vaultManager);
        concreteAsyncVault.setUnwindCostCap(newCap);

        assertEq(concreteAsyncVault.getUnwindCostCap(), newCap);
    }

    // ── enforcement ───────────────────────────────────────────────────────────

    function testGatedFunctionRevertsWithoutProposal() public {
        _activateFull();

        vm.prank(vaultOwner);
        vm.expectRevert("MockTimelock: unknown action");
        concreteAsyncVault.transferOwnership(makeAddr("newOwner"));
    }
}
