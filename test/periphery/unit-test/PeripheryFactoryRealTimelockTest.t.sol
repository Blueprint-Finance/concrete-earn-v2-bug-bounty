// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";

import {TimelockRealBaseSetup} from "../../common/TimelockRealBaseSetup.t.sol";
import {PeripheryFactory} from "../../../src/periphery/factory/PeripheryFactory.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {TimelockContractTypesLib as CT} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ITimelockProtected} from "../../../src/interface/ITimelockProtected.sol";

// ── Minimal mock strategy (for approveStrategyImpl) ───────────────────────────

contract MockStrategyImpl2 is IContractId, AccessControlUpgradeable {
    uint64 private immutable _implId;

    constructor(uint64 implId_) {
        _implId = implId_;
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        __AccessControl_init();
        _grantRole(PeripheryRolesLib.ROLE_ADMIN, admin);
    }

    function ID() public view override returns (uint64) {
        return _implId;
    }
}

// ── Minimal mock hook (for approveHookImpl) ───────────────────────────────────

contract MockHookImpl is IContractId {
    uint64 private immutable _implId;

    constructor(uint64 implId_) {
        _implId = implId_;
    }

    function ID() public view override returns (uint64) {
        return _implId;
    }
}

// ── PeripheryFactoryRealTimelockTest ──────────────────────────────────────────

contract PeripheryFactoryRealTimelockTest is TimelockRealBaseSetup {
    PeripheryFactory public factory;
    address public factoryOwner;

    uint64 constant STRAT_ID_1 = 3001;
    uint64 constant HOOK_ID_1 = 4001;
    address public stratImpl1;

    function setUp() public {
        factoryOwner = makeAddr("factoryOwner");
        stratImpl1 = address(new MockStrategyImpl2(STRAT_ID_1));

        // Deploy factory (no timelock yet)
        address factoryImpl = address(new PeripheryFactory());
        factory = PeripheryFactory(
            address(
                new ERC1967Proxy(factoryImpl, abi.encodeCall(PeripheryFactory.initialize, (factoryOwner, address(0))))
            )
        );

        // Deploy real Timelock
        _deployTimelock();

        // Bootstrap sequence
        vm.prank(factoryOwner);
        factory.setTimelock(address(timelock));

        _bindAndActivate(address(factory), CT.CT_PERIPHERY_FACTORY);

        vm.prank(factoryOwner);
        factory.activateTimelock();
    }

    // ── Artifact registry ─────────────────────────────────────────────────────

    function testArtifactsRegistered() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(OwnableUpgradeable.transferOwnership.selector)),
            Config.TIER_1
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(UUPSUpgradeable.upgradeToAndCall.selector)),
            Config.TIER_1
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(ITimelockProtected.setTimelock.selector)),
            Config.TIER_1
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(PeripheryFactory.approveStrategyImpl.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(PeripheryFactory.approvePMHImpl.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(PeripheryFactory.approveHookImpl.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(PeripheryFactory.unpause.selector)),
            Config.TIER_3
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(PeripheryFactory.unblockStrategyImpl.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(PeripheryFactory.unblockPMHImpl.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_PERIPHERY_FACTORY, bytes32(PeripheryFactory.unblockHookImpl.selector)),
            Config.TIER_2
        );
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
        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.pause();
    }

    function testDeployStrategy_revertsWhenPaused() public {
        vm.prank(factoryOwner);
        factory.pause();

        // whenNotPaused runs before any implementation lookup, so deploy reverts immediately
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.deployStrategy(STRAT_ID_1, abi.encodeCall(MockStrategyImpl2.initialize, (factoryOwner)));
    }

    function testClonePMH_revertsWhenPaused() public {
        vm.prank(factoryOwner);
        factory.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.clonePMH(1, makeAddr("posOwner"), makeAddr("col"), makeAddr("borrow"), "");
    }

    function testCloneHook_revertsWhenPaused() public {
        vm.prank(factoryOwner);
        factory.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.cloneHook(HOOK_ID_1, makeAddr("vault"), "");
    }

    // ── TIER_3 — unpause (owner-gated, behind timelock) ───────────────────────

    function testTier3_unpause_afterDelay() public {
        vm.prank(factoryOwner);
        factory.pause();

        _proposeAndWarp(address(factory), PeripheryFactory.unpause.selector, "", TIER_3_DELAY);

        vm.prank(factoryOwner);
        factory.unpause();

        assertFalse(factory.paused());
    }

    function testUnpause_revertsWithoutProposal() public {
        vm.prank(factoryOwner);
        factory.pause();

        bytes32 actionId = timelock.computeActionId(address(factory), PeripheryFactory.unpause.selector, "");

        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.unpause();
    }

    // ── TIER_1 — transferOwnership (48 h) ─────────────────────────────────────

    function testTier1_transferOwnership_afterDelay() public {
        address newOwner = makeAddr("newOwner");
        _proposeAndWarp(
            address(factory), PeripheryFactory.transferOwnership.selector, abi.encode(newOwner), TIER_1_DELAY
        );

        // Ownable2Step: transferOwnership only sets the pending owner.
        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
    }

    function testTier1_transferOwnership_revertsBeforeDelay() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(timelockAdmin);
        bytes32 actionId =
            timelock.propose(address(factory), PeripheryFactory.transferOwnership.selector, abi.encode(newOwner));

        // Warp only to TIER_2 — not enough for TIER_1
        vm.warp(block.timestamp + TIER_2_DELAY + 1);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        factory.transferOwnership(newOwner);
    }

    // ── TIER_2 — approveStrategyImpl (24 h) ───────────────────────────────────

    function testTier2_approveStrategyImpl_afterDelay() public {
        _proposeAndWarp(
            address(factory), PeripheryFactory.approveStrategyImpl.selector, abi.encode(stratImpl1), TIER_2_DELAY
        );

        vm.prank(factoryOwner);
        factory.approveStrategyImpl(stratImpl1);

        assertEq(factory.getStrategyImpl(STRAT_ID_1), stratImpl1);
    }

    function testTier2_revertsWithoutProposal() public {
        bytes32 actionId = timelock.computeActionId(
            address(factory), PeripheryFactory.approveStrategyImpl.selector, abi.encode(stratImpl1)
        );

        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.approveStrategyImpl(stratImpl1);
    }

    // ── TIER_2 — unblockStrategyImpl (behind timelock) ────────────────────────

    function testUnblockStrategyImpl_revertsWithoutProposal() public {
        bytes memory args = abi.encode(STRAT_ID_1);
        bytes32 actionId =
            timelock.computeActionId(address(factory), PeripheryFactory.unblockStrategyImpl.selector, args);

        // afterDelay runs before the ImplNotFound/NotBlocked checks, so the missing proposal is caught first
        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.unblockStrategyImpl(STRAT_ID_1);
    }

    function testUnblockPMHImpl_revertsWithoutProposal() public {
        bytes memory args = abi.encode(uint64(2001));
        bytes32 actionId = timelock.computeActionId(address(factory), PeripheryFactory.unblockPMHImpl.selector, args);

        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.unblockPMHImpl(2001);
    }

    function testUnblockHookImpl_revertsWithoutProposal() public {
        bytes memory args = abi.encode(HOOK_ID_1);
        bytes32 actionId = timelock.computeActionId(address(factory), PeripheryFactory.unblockHookImpl.selector, args);

        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.unblockHookImpl(HOOK_ID_1);
    }

    // ── TIER_2 — approveHookImpl (behind timelock) ────────────────────────────

    function testTier2_approveHookImpl_afterDelay() public {
        address hookImpl = address(new MockHookImpl(HOOK_ID_1));
        _proposeAndWarp(address(factory), PeripheryFactory.approveHookImpl.selector, abi.encode(hookImpl), TIER_2_DELAY);

        vm.prank(factoryOwner);
        factory.approveHookImpl(hookImpl);

        assertEq(factory.getHookImpl(HOOK_ID_1), hookImpl);
    }

    function testApproveHookImpl_revertsWithoutProposal() public {
        address hookImpl = address(new MockHookImpl(HOOK_ID_1));
        bytes32 actionId =
            timelock.computeActionId(address(factory), PeripheryFactory.approveHookImpl.selector, abi.encode(hookImpl));

        vm.prank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        factory.approveHookImpl(hookImpl);
    }
}
