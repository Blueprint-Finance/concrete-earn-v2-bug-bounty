// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    ConcreteMultiAssetDepositAsyncVaultBaseSetup
} from "../../common/ConcreteMultiAssetDepositAsyncVaultBaseSetup.t.sol";
import {
    IConcreteMultiAssetDepositAsyncVault as IMAV
} from "../../../src/interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {IConcreteAsyncVaultImpl} from "../../../src/interface/IConcreteAsyncVaultImpl.sol";
import {ERC4626StrategyMock} from "../../mock/ERC4626StrategyMock.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {ERC20Mock} from "../../mock/ERC20Mock.sol";

contract MultiAssetAdminUnitTest is ConcreteMultiAssetDepositAsyncVaultBaseSetup {
    address public pricer;

    function setUp() public override {
        super.setUp();
        pricer = makeAddr("pricer");
    }

    function _config(IMAV.MultiAssetVaultManagerConfig configType, bytes memory data) internal {
        vm.prank(vaultManager);
        multiAssetVault.configureMultiAsset(configType, data);
    }

    function _addActiveStrategy() internal returns (ERC4626StrategyMock strategy) {
        strategy = new ERC4626StrategyMock(address(asset), address(multiAssetVault));
        vm.prank(strategyOperator);
        multiAssetVault.addStrategy(address(strategy));
    }

    // ── Whitelist ─────────────────────────────────────────────────────────────

    function testAddWhitelistedAsset() public {
        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.WhitelistedAssetAdded(address(otherAsset));
        _config(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset)));

        assertTrue(multiAssetVault.isWhitelistedAsset(address(otherAsset)));
        address[] memory listed = multiAssetVault.getWhitelistedAssets();
        assertEq(listed.length, 1);
        assertEq(listed[0], address(otherAsset));
    }

    function testAddWhitelistedBaseAssetReverts() public {
        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IMAV.CannotWhitelistBaseAsset.selector));
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(asset))
        );
    }

    function testAddWhitelistedShareTokenReverts() public {
        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IMAV.CannotWhitelistShareToken.selector));
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(multiAssetVault))
        );
    }

    function testAddWhitelistedZeroReverts() public {
        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IConcreteAsyncVaultImpl.ZeroAddress.selector));
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(0))
        );
    }

    function testAddWhitelistedAlreadyReverts() public {
        _config(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset)));

        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IMAV.AssetAlreadyWhitelisted.selector, address(otherAsset)));
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset))
        );
    }

    function testRemoveWhitelistedAsset() public {
        _config(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset)));

        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.WhitelistedAssetRemoved(address(otherAsset));
        vm.prank(vaultManager);
        multiAssetVault.removeWhitelistedAsset(address(otherAsset));

        assertFalse(multiAssetVault.isWhitelistedAsset(address(otherAsset)));
        assertEq(multiAssetVault.getWhitelistedAssets().length, 0);
    }

    function testGetWhitelistedAssetsEmptyByDefault() public view {
        assertEq(multiAssetVault.getWhitelistedAssets().length, 0);
    }

    function testGetWhitelistedAssetsListsAll() public {
        ERC20Mock second = new ERC20Mock();
        _config(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset)));
        _config(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(second)));

        address[] memory listed = multiAssetVault.getWhitelistedAssets();
        assertEq(listed.length, 2);
        assertEq(listed[0], address(otherAsset));
        assertEq(listed[1], address(second));
    }

    function testRemoveWhitelistedNotPresentReverts() public {
        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IMAV.AssetNotWhitelisted.selector, address(otherAsset)));
        multiAssetVault.removeWhitelistedAsset(address(otherAsset));
    }

    // ── Pricer ──────────────────────────────────────────────────────────────

    function testSetPricer() public {
        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.MultiAssetPricerSet(pricer);
        _config(IMAV.MultiAssetVaultManagerConfig.SetPricer, abi.encode(pricer));
    }

    function testSetPricerZeroReverts() public {
        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IMAV.InvalidPricer.selector));
        multiAssetVault.configureMultiAsset(IMAV.MultiAssetVaultManagerConfig.SetPricer, abi.encode(address(0)));
    }

    // ── Strategy ──────────────────────────────────────────────────────────────

    function testSetMultiAssetStrategy() public {
        ERC4626StrategyMock strategy = _addActiveStrategy();

        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.MultiAssetStrategySet(address(strategy));
        _config(IMAV.MultiAssetVaultManagerConfig.SetMultiAssetStrategy, abi.encode(address(strategy)));
    }

    function testSetMultiAssetStrategyNotRegisteredReverts() public {
        address rogue = makeAddr("rogue");
        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IMAV.InvalidMultiAssetStrategy.selector, rogue));
        multiAssetVault.configureMultiAsset(IMAV.MultiAssetVaultManagerConfig.SetMultiAssetStrategy, abi.encode(rogue));
    }

    function testSetMultiAssetStrategyHaltedReverts() public {
        ERC4626StrategyMock strategy = _addActiveStrategy();
        vm.prank(strategyOperator);
        multiAssetVault.toggleStrategyStatus(address(strategy)); // Active -> Halted

        vm.prank(vaultManager);
        vm.expectRevert(abi.encodeWithSelector(IMAV.InvalidMultiAssetStrategy.selector, address(strategy)));
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.SetMultiAssetStrategy, abi.encode(address(strategy))
        );
    }

    function testSetMultiAssetStrategyCanRepointWithAllocationOnOld() public {
        // Repointing must not require the previous strategy to be drained.
        ERC4626StrategyMock first = _addActiveStrategy();
        _config(IMAV.MultiAssetVaultManagerConfig.SetMultiAssetStrategy, abi.encode(address(first)));

        // Repointing to a second active strategy must succeed even though `first` may hold allocation.
        ERC4626StrategyMock second = _addActiveStrategy();
        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.MultiAssetStrategySet(address(second));
        _config(IMAV.MultiAssetVaultManagerConfig.SetMultiAssetStrategy, abi.encode(address(second)));
    }

    // ── Access control ──────────────────────────────────────────────────────

    function testConfigureMultiAssetOnlyVaultManager() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, RolesLib.VAULT_MANAGER
            )
        );
        multiAssetVault.configureMultiAsset(
            IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset))
        );
    }

    function testRemoveWhitelistedAssetOnlyVaultManager() public {
        _config(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(address(otherAsset)));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, RolesLib.VAULT_MANAGER
            )
        );
        multiAssetVault.removeWhitelistedAsset(address(otherAsset));
    }
}
