// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {ConcreteFactory, ConcreteFactoryBaseSetup} from "../../common/ConcreteFactoryBaseSetup.t.sol";
import {TimelockRealBaseSetup} from "../../common/TimelockRealBaseSetup.t.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {IConcreteFactory} from "../../../src/interface/IConcreteFactory.sol";
import {TimelockContractTypesLib as CT} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

contract ConcreteFactoryRealTimelockTest is ConcreteFactoryBaseSetup, TimelockRealBaseSetup {
    function setUp() public override {
        // Deploy factory (no timelock yet — afterDelay is a no-op during setUp)
        ConcreteFactoryBaseSetup.setUp();

        // Deploy real Timelock
        _deployTimelock();

        // Bootstrap sequence
        vm.prank(factoryOwner);
        factory.setTimelock(address(timelock));

        _bindAndActivate(address(factory), CT.CT_FACTORY);

        vm.prank(factoryOwner);
        factory.activateTimelock();
    }

    // ── Artifact registry ─────────────────────────────────────────────────────

    function testArtifactsRegistered() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_FACTORY, bytes32(OwnableUpgradeable.transferOwnership.selector)),
            Config.TIER_1
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_FACTORY, bytes32(UUPSUpgradeable.upgradeToAndCall.selector)), Config.TIER_1
        );
        assertEq(
            timelock.artifactDelayTier(
                CT.CT_FACTORY, bytes32(IConcreteFactory.setDefaultEnforcedVaultConfiguration.selector)
            ),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_FACTORY, bytes32(IConcreteFactory.approveImplementation.selector)),
            Config.TIER_2
        );
        assertEq(timelock.artifactDelayTier(CT.CT_FACTORY, bytes32(IConcreteFactory.unpause.selector)), Config.TIER_3);
        assertEq(
            timelock.artifactDelayTier(CT.CT_FACTORY, bytes32(IConcreteFactory.unblockImplementation.selector)),
            Config.TIER_2
        );
    }

    // ── TIER_2 — unblockImplementation (owner-gated, behind timelock) ──────────

    function testUnblockImplementation_revertsWithoutProposal() public {
        uint64 vaultImpl = 1;
        bytes memory args = abi.encode(vaultImpl);
        bytes32 actionId =
            timelock.computeActionId(address(factory), IConcreteFactory.unblockImplementation.selector, args);

        // afterDelay runs before checkVersion, so the missing proposal is caught first
        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.unblockImplementation(vaultImpl);
    }

    // ── Pause — manager-only, immediate (no timelock) ─────────────────────────

    function testPause_byManager_immediate() public {
        // factoryManager defaults to factoryOwner in the base setup
        vm.prank(factoryOwner);
        factory.pause();
        assertTrue(factory.paused());
    }

    function testPause_revertsForNonManager() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IConcreteFactory.NotFactoryManager.selector);
        factory.pause();
    }

    function testCreate_revertsWhenPaused() public {
        vm.prank(factoryOwner);
        factory.pause();

        // whenNotPaused runs before any implementation lookup, so create reverts immediately
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.create(1, makeAddr("vaultOwner"), "");
    }

    // ── TIER_3 — unpause (owner-gated, behind timelock) ───────────────────────

    function testTier3_unpause_afterDelay() public {
        vm.prank(factoryOwner);
        factory.pause();

        _proposeAndWarp(address(factory), IConcreteFactory.unpause.selector, "", Config.TIER_3_DEFAULT);

        vm.prank(factoryOwner);
        factory.unpause();

        assertFalse(factory.paused());
    }

    function testUnpause_revertsWithoutProposal() public {
        vm.prank(factoryOwner);
        factory.pause();

        bytes32 actionId = timelock.computeActionId(address(factory), IConcreteFactory.unpause.selector, "");

        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.unpause();
    }

    // ── TIER_1 — transferOwnership (48 h) ─────────────────────────────────────

    function testTier1_transferOwnership_afterDelay() public {
        address newOwner = makeAddr("newOwner");
        _proposeAndWarp(
            address(factory), ConcreteFactory.transferOwnership.selector, abi.encode(newOwner), TIER_1_DELAY
        );

        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        // Ownable2Step: transfer only sets the pending owner; ownership flips on acceptance
        assertEq(factory.owner(), factoryOwner);
        assertEq(factory.pendingOwner(), newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
    }

    function testTier1_transferOwnership_revertsBeforeDelay() public {
        address newOwner = makeAddr("newOwner");
        bytes memory args = abi.encode(newOwner);
        vm.prank(timelockAdmin);
        bytes32 actionId = timelock.propose(address(factory), ConcreteFactory.transferOwnership.selector, args);

        // Warp to only TIER_2 delay — not enough for TIER_1
        vm.warp(block.timestamp + TIER_2_DELAY + 1);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        factory.transferOwnership(newOwner);
    }

    // ── TIER_2 — setDefaultEnforcedVaultConfiguration (24 h) ─────────────────

    function testTier2_setDefaultEnforcedVaultConfiguration_afterDelay() public {
        address newMgmt = makeAddr("newMgmt");
        address newPerf = makeAddr("newPerf");
        _proposeAndWarp(
            address(factory),
            IConcreteFactory.setDefaultEnforcedVaultConfiguration.selector,
            abi.encode(newMgmt, newPerf),
            TIER_2_DELAY
        );

        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(newMgmt, newPerf);

        (address mgmt, address perf) = factory.getDefaultEnforcedVaultConfiguration();
        assertEq(mgmt, newMgmt);
        assertEq(perf, newPerf);
    }

    function testTier2_revertsWithoutProposal() public {
        address newMgmt = makeAddr("newMgmt");
        address newPerf = makeAddr("newPerf");
        bytes32 actionId = timelock.computeActionId(
            address(factory),
            IConcreteFactory.setDefaultEnforcedVaultConfiguration.selector,
            abi.encode(newMgmt, newPerf)
        );

        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.setDefaultEnforcedVaultConfiguration(newMgmt, newPerf);
    }
}
