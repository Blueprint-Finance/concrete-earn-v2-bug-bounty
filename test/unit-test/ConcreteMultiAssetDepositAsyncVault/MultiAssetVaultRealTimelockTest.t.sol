// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {
    ConcreteMultiAssetDepositAsyncVaultBaseSetup
} from "../../common/ConcreteMultiAssetDepositAsyncVaultBaseSetup.t.sol";
import {TimelockRealBaseSetup} from "../../common/TimelockRealBaseSetup.t.sol";
import {
    IConcreteMultiAssetDepositAsyncVault as IMAV
} from "../../../src/interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {TimelockContractTypesLib as CT} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";

/**
 * @dev Multi-asset vault behind a real {Timelock}: permissive {configureMultiAsset} must
 *      flow through `propose → mature → execute`, while the restrictive
 *      {IMAV-removeWhitelistedAsset} stays immediate.
 */
contract MultiAssetVaultRealTimelockTest is ConcreteMultiAssetDepositAsyncVaultBaseSetup, TimelockRealBaseSetup {
    function setUp() public override {
        ConcreteMultiAssetDepositAsyncVaultBaseSetup.setUp();

        _deployTimelock();

        vm.prank(vaultOwner);
        multiAssetVault.setTimelock(address(timelock));

        _bindAndActivate(address(multiAssetVault), CT.CT_VAULT);

        vm.prank(vaultOwner);
        multiAssetVault.activateTimelock();
    }

    function _addWhitelistArgs() internal view returns (bytes memory) {
        return abi.encode(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset)));
    }

    // ── Artifact registry ─────────────────────────────────────────────────────

    function testConfigureMultiAssetRegistered() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_VAULT, bytes32(IMAV.configureMultiAsset.selector)),
            Config.TIER_2,
            "configureMultiAsset tier mismatch"
        );
    }

    function testRemoveWhitelistedAssetUnregistered() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_VAULT, bytes32(IMAV.removeWhitelistedAsset.selector)),
            bytes4(0),
            "removeWhitelistedAsset must be unregistered"
        );
    }

    // ── TIER_2 — configureMultiAsset (24 h) ───────────────────────────────────

    function testTier2_configureMultiAsset_afterDelay() public {
        _proposeAndWarp(address(multiAssetVault), IMAV.configureMultiAsset.selector, _addWhitelistArgs(), TIER_2_DELAY);

        vm.prank(vaultManager);
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset))
        );

        assertTrue(multiAssetVault.isWhitelistedAsset(address(otherAsset)));
    }

    function testConfigureMultiAsset_revertsWithoutProposal() public {
        bytes32 actionId =
            timelock.computeActionId(address(multiAssetVault), IMAV.configureMultiAsset.selector, _addWhitelistArgs());

        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset))
        );
    }

    // ── removeWhitelistedAsset — immediate, no proposal ───────────────────────

    function testRemoveWhitelistedAsset_immediate() public {
        _proposeAndWarp(address(multiAssetVault), IMAV.configureMultiAsset.selector, _addWhitelistArgs(), TIER_2_DELAY);
        vm.prank(vaultManager);
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset))
        );

        vm.prank(vaultManager);
        multiAssetVault.removeWhitelistedAsset(address(otherAsset));

        assertFalse(multiAssetVault.isWhitelistedAsset(address(otherAsset)));
    }
}
