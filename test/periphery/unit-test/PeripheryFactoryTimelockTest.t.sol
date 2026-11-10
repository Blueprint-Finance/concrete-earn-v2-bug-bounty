// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";

import {PeripheryFactory} from "../../../src/periphery/factory/PeripheryFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";
import {TimelockIntegrationLib} from "../../../src/lib/TimelockIntegrationLib.sol";
import {MockTimelock} from "../../mocks/MockTimelock.sol";

// ── Minimal mocks ─────────────────────────────────────────────────────────────

contract MockStrategyImpl is IContractId, AccessControlUpgradeable {
    uint64 private immutable _implId;

    constructor(uint64 implId_) {
        _implId = implId_;
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        __AccessControl_init();
        _setRoleAdmin(PeripheryRolesLib.ROLE_ADMIN, PeripheryRolesLib.ROLE_ADMIN);
        _grantRole(PeripheryRolesLib.ROLE_ADMIN, admin);
        _grantRole(PeripheryRolesLib.STRATEGY_ADMIN, admin);
        _grantRole(PeripheryRolesLib.STRATEGY_UPGRADER, admin);
    }

    function ID() public view override returns (uint64) {
        return _implId;
    }
}

contract MockPMHImpl is IContractId {
    uint64 private immutable _implId;

    constructor(uint64 implId_) {
        _implId = implId_;
    }

    function ID() public view override returns (uint64) {
        return _implId;
    }

    function initialize(address, address, address, address, address, uint64, uint64, uint64) external {}
}

// ── PeripheryFactoryTimelockTest ──────────────────────────────────────────────

contract PeripheryFactoryTimelockTest is Test {
    PeripheryFactory public factory;
    MockTimelock public mockTimelock;

    address public factoryOwner;

    uint64 constant STRAT_ID_1 = 1001;
    uint64 constant STRAT_ID_2 = 1002;
    uint64 constant PMH_ID_1 = 2001;

    address public stratImpl1;
    address public stratImpl2;
    address public pmhImpl1;

    function setUp() public {
        factoryOwner = makeAddr("factoryOwner");

        address factoryImpl = address(new PeripheryFactory());
        factory = PeripheryFactory(
            address(
                new ERC1967Proxy(factoryImpl, abi.encodeCall(PeripheryFactory.initialize, (factoryOwner, address(0))))
            )
        );

        mockTimelock = new MockTimelock();

        stratImpl1 = address(new MockStrategyImpl(STRAT_ID_1));
        stratImpl2 = address(new MockStrategyImpl(STRAT_ID_2));
        pmhImpl1 = address(new MockPMHImpl(PMH_ID_1));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// Wire up the timelock and activate enforcement on both sides.
    function _activateTimelock() internal {
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock();
        mockTimelock.activateTimelock();
        vm.stopPrank();
    }

    /// Propose, warp past the mock delay, and return.
    function _proposeAndWarp(bytes4 selector, bytes memory args) internal {
        mockTimelock.propose(address(factory), selector, args);
        vm.warp(block.timestamp + mockTimelock.DELAY() + 1);
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

    // ── transferOwnership (TIER_1) ────────────────────────────────────────────

    function testTransferOwnership_afterDelay() public {
        _activateTimelock();

        address newOwner = makeAddr("newOwner");
        _proposeAndWarp(PeripheryFactory.transferOwnership.selector, abi.encode(newOwner));

        // Ownable2Step: transferOwnership only sets the pending owner.
        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
    }

    // ── approveStrategyImpl (TIER_2) ──────────────────────────────────────────

    function testApproveStrategyImpl_afterDelay() public {
        _activateTimelock();

        _proposeAndWarp(PeripheryFactory.approveStrategyImpl.selector, abi.encode(stratImpl1));

        vm.prank(factoryOwner);
        factory.approveStrategyImpl(stratImpl1);

        assertEq(factory.getStrategyImpl(STRAT_ID_1), stratImpl1);
    }

    // ── setStrategyMigratable (TIER_2) ────────────────────────────────────────

    function testSetStrategyMigratable_afterDelay() public {
        // Approve both impls before activating the timelock (no delay yet).
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(stratImpl1);
        factory.approveStrategyImpl(stratImpl2);
        vm.stopPrank();

        _activateTimelock();

        _proposeAndWarp(PeripheryFactory.setStrategyMigratable.selector, abi.encode(STRAT_ID_1, STRAT_ID_2));

        vm.prank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);

        assertTrue(factory.isStrategyMigratable(STRAT_ID_1, STRAT_ID_2));
    }

    // ── approvePMHImpl (TIER_2) ───────────────────────────────────────────────

    function testApprovePMHImpl_afterDelay() public {
        _activateTimelock();

        _proposeAndWarp(PeripheryFactory.approvePMHImpl.selector, abi.encode(pmhImpl1));

        vm.prank(factoryOwner);
        factory.approvePMHImpl(pmhImpl1);

        assertEq(factory.getPMHImpl(PMH_ID_1), pmhImpl1);
    }

    // ── upgradeToAndCall (TIER_1) ─────────────────────────────────────────────

    function testUpgradeToAndCall_afterDelay() public {
        _activateTimelock();

        address newImpl = address(new PeripheryFactory());
        bytes memory args = abi.encode(newImpl, bytes(""));
        _proposeAndWarp(UUPSUpgradeable.upgradeToAndCall.selector, args);

        vm.prank(factoryOwner);
        factory.upgradeToAndCall(newImpl, "");
    }

    function testUpgradeToAndCall_revertsWithoutProposal() public {
        _activateTimelock();

        address newImpl = address(new PeripheryFactory());
        vm.prank(factoryOwner);
        vm.expectRevert("MockTimelock: unknown action");
        factory.upgradeToAndCall(newImpl, "");
    }

    // ── gated calls pass before timelock is activated ─────────────────────────

    function testGatedCallPassesBeforeTimelockActivated() public {
        // Timelock set and factory enforcement active, but mockTimelock.active == false
        // so checkDelayExpired is a no-op — no proposal needed.
        vm.startPrank(factoryOwner);
        factory.setTimelock(address(mockTimelock));
        factory.activateTimelock();
        factory.approveStrategyImpl(stratImpl1);
        vm.stopPrank();

        assertEq(factory.getStrategyImpl(STRAT_ID_1), stratImpl1);
    }
}
