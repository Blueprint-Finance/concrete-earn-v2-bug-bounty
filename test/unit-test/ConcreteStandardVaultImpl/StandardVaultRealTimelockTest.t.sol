// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {TimelockRealBaseSetup} from "../../common/TimelockRealBaseSetup.t.sol";
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {IConcreteMultiAssetDepositAsyncVault} from "../../../src/interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {ITimelockProtected} from "../../../src/interface/ITimelockProtected.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {TimelockContractTypesLib as CT} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";

contract StandardVaultRealTimelockTest is ConcreteStandardVaultImplBaseSetup, TimelockRealBaseSetup {
    function setUp() public override {
        // Deploy vault — afterDelay is no-op until timelock is activated
        ConcreteStandardVaultImplBaseSetup.setUp();

        // Deploy real Timelock
        _deployTimelock();

        // Bootstrap: set timelock address → bind + activate Timelock → activate on vault
        vm.prank(vaultOwner);
        concreteStandardVault.setTimelock(address(timelock));

        _bindAndActivate(address(concreteStandardVault), CT.CT_VAULT);

        vm.prank(vaultOwner);
        concreteStandardVault.activateTimelock();
    }

    // ── Artifact registry ─────────────────────────────────────────────────────

    function testArtifactsRegistered() public view {
        // TIER_1 selectors
        assertEq(
            timelock.artifactDelayTier(CT.CT_VAULT, bytes32(OwnableUpgradeable.transferOwnership.selector)),
            Config.TIER_1
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_VAULT, bytes32(ITimelockProtected.setTimelock.selector)), Config.TIER_1
        );
        assertEq(timelock.artifactDelayTier(CT.CT_VAULT, RolesLib.VAULT_MANAGER), Config.TIER_1);
        assertEq(timelock.artifactDelayTier(CT.CT_VAULT, RolesLib.ROLE_ADMIN), Config.TIER_1);

        // TIER_2 selectors
        assertEq(
            timelock.artifactDelayTier(CT.CT_VAULT, bytes32(IConcreteStandardVaultImpl.configure.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_VAULT, bytes32(IConcreteStandardVaultImpl.addStrategy.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_VAULT, bytes32(IConcreteStandardVaultImpl.setHooks.selector)),
            Config.TIER_2
        );
        assertEq(
            timelock.artifactDelayTier(
                CT.CT_VAULT, bytes32(IConcreteMultiAssetDepositAsyncVault.configureMultiAsset.selector)
            ),
            Config.TIER_2
        );
        assertEq(timelock.artifactDelayTier(CT.CT_VAULT, RolesLib.STRATEGY_MANAGER), Config.TIER_2);
        assertEq(timelock.artifactDelayTier(CT.CT_VAULT, RolesLib.HOOK_MANAGER), Config.TIER_2);
        assertEq(timelock.artifactDelayTier(CT.CT_VAULT, RolesLib.ALLOCATOR), Config.TIER_2);
    }

    // ── TIER_1 — transferOwnership (48 h) ─────────────────────────────────────

    function testTier1_transferOwnership_afterDelay() public {
        address newOwner = makeAddr("newOwner");
        _proposeAndWarp(
            address(concreteStandardVault),
            ConcreteStandardVaultImpl.transferOwnership.selector,
            abi.encode(newOwner),
            TIER_1_DELAY
        );

        vm.prank(vaultOwner);
        concreteStandardVault.transferOwnership(newOwner);

        // Ownable2Step: transfer only sets the pending owner; ownership flips on acceptance
        assertEq(concreteStandardVault.owner(), vaultOwner);
        assertEq(concreteStandardVault.pendingOwner(), newOwner);

        vm.prank(newOwner);
        concreteStandardVault.acceptOwnership();

        assertEq(concreteStandardVault.owner(), newOwner);
    }

    function testTier1_transferOwnership_revertsBeforeDelay() public {
        address newOwner = makeAddr("newOwner");
        bytes memory args = abi.encode(newOwner);
        vm.prank(timelockAdmin);
        bytes32 actionId = timelock.propose(
            address(concreteStandardVault), ConcreteStandardVaultImpl.transferOwnership.selector, args
        );

        // Warp only to TIER_2 delay — not enough for TIER_1
        vm.warp(block.timestamp + TIER_2_DELAY + 1);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        concreteStandardVault.transferOwnership(newOwner);
    }

    // ── TIER_2 — configure (24 h) ─────────────────────────────────────────────

    function testTier2_configure_afterDelay() public {
        uint256 minDeposit = 100e18;
        uint256 maxDeposit = 1_000_000e18;
        bytes memory innerData = abi.encode(minDeposit, maxDeposit);
        bytes memory args = abi.encode(IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, innerData);

        _proposeAndWarp(
            address(concreteStandardVault), IConcreteStandardVaultImpl.configure.selector, args, TIER_2_DELAY
        );

        vm.prank(vaultManager);
        concreteStandardVault.configure(IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, innerData);

        (uint256 maxGlobal, uint256 minTx) = concreteStandardVault.getDepositLimits();
        assertEq(minTx, minDeposit);
        assertEq(maxGlobal, maxDeposit);
    }

    function testTier2_revertsWithoutProposal() public {
        uint256 minDeposit = 100e18;
        uint256 maxDeposit = 1_000_000e18;
        bytes memory innerData = abi.encode(minDeposit, maxDeposit);
        bytes memory args = abi.encode(IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, innerData);

        bytes32 actionId = timelock.computeActionId(
            address(concreteStandardVault), IConcreteStandardVaultImpl.configure.selector, args
        );

        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        concreteStandardVault.configure(IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, innerData);
    }

    // ── TIER_1 — grantRole(VAULT_MANAGER) ────────────────────────────────────

    function testTier1_grantRole_vaultManager_afterDelay() public {
        address newManager = makeAddr("newManager");
        bytes memory args = abi.encode(RolesLib.VAULT_MANAGER, newManager);

        _proposeAndWarp(address(concreteStandardVault), IAccessControl.grantRole.selector, args, TIER_1_DELAY);

        // vaultManager holds ROLE_ADMIN (admin of VAULT_MANAGER)
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.VAULT_MANAGER, newManager);

        assertTrue(concreteStandardVault.hasRole(RolesLib.VAULT_MANAGER, newManager));
    }

    function testTier1_grantRole_vaultManager_revertsBeforeDelay() public {
        address newManager = makeAddr("newManager");
        bytes memory args = abi.encode(RolesLib.VAULT_MANAGER, newManager);

        vm.prank(timelockAdmin);
        bytes32 actionId = timelock.propose(address(concreteStandardVault), IAccessControl.grantRole.selector, args);

        // Warp only to TIER_2 — not enough for TIER_1
        vm.warp(block.timestamp + TIER_2_DELAY + 1);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        concreteStandardVault.grantRole(RolesLib.VAULT_MANAGER, newManager);
    }

    // ── TIER_2 — grantRole(STRATEGY_MANAGER) ──────────────────────────────────

    function testTier2_grantRole_strategyManager_afterDelay() public {
        address newStratManager = makeAddr("newStratManager");
        bytes memory args = abi.encode(RolesLib.STRATEGY_MANAGER, newStratManager);

        _proposeAndWarp(address(concreteStandardVault), IAccessControl.grantRole.selector, args, TIER_2_DELAY);

        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.STRATEGY_MANAGER, newStratManager);

        assertTrue(concreteStandardVault.hasRole(RolesLib.STRATEGY_MANAGER, newStratManager));
    }
}
