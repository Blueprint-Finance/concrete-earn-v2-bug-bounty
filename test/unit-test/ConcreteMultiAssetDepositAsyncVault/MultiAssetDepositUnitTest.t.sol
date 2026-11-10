// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    ConcreteMultiAssetDepositAsyncVaultBaseSetup
} from "../../common/ConcreteMultiAssetDepositAsyncVaultBaseSetup.t.sol";
import {IConcreteMultiAssetDepositAsyncVault} from "../../../src/interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

contract MultiAssetDepositUnitTest is ConcreteMultiAssetDepositAsyncVaultBaseSetup {
    address public user1;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        asset.mint(user1, 10 * DEPOSIT_AMOUNT);
        otherAsset.mint(user1, 10 * DEPOSIT_AMOUNT);

        vm.startPrank(user1);
        asset.approve(address(multiAssetVault), type(uint256).max);
        otherAsset.approve(address(multiAssetVault), type(uint256).max);
        vm.stopPrank();
    }

    // ── Base passthrough ────────────────────────────────────────────────

    function testBaseDepositRoutesToInheritedFlow() public {
        uint256 expectedShares = multiAssetVault.previewDeposit(DEPOSIT_AMOUNT);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(asset), DEPOSIT_AMOUNT, user1);

        assertEq(shares, expectedShares, "shares mismatch vs inherited previewDeposit");
        assertEq(multiAssetVault.balanceOf(user1), shares, "receiver did not get shares");
        // Base assets land idle in the vault (no strategy configured).
        assertEq(asset.balanceOf(address(multiAssetVault)), DEPOSIT_AMOUNT, "assets not held idle by vault");
        assertEq(multiAssetVault.cachedTotalAssets(), DEPOSIT_AMOUNT, "cachedTotalAssets not updated");
    }

    function testBaseDepositMatchesInheritedDeposit() public {
        // Multi-asset base deposit must mint the same shares as the inherited deposit(uint256,address).
        vm.prank(user1);
        uint256 multiAssetShares = multiAssetVault.deposit(address(asset), DEPOSIT_AMOUNT, user1);

        address user2 = makeAddr("user2");
        asset.mint(user2, DEPOSIT_AMOUNT);
        vm.startPrank(user2);
        asset.approve(address(multiAssetVault), type(uint256).max);
        uint256 inheritedShares = multiAssetVault.deposit(DEPOSIT_AMOUNT, user2);
        vm.stopPrank();

        assertEq(multiAssetShares, inheritedShares, "base multi-asset deposit diverges from inherited deposit");
    }

    function testBaseDepositRespectsPause() public {
        vm.startPrank(vaultManager);
        multiAssetVault.grantRole(RolesLib.PAUSER, vaultManager);
        multiAssetVault.pause();
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        multiAssetVault.deposit(address(asset), DEPOSIT_AMOUNT, user1);
    }

    // ── Non-base rejection ──────────────────────────────────────────────

    function testNonBaseDepositReverts() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteMultiAssetDepositAsyncVault.AssetNotWhitelisted.selector, address(otherAsset)
            )
        );
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testNonBaseDepositDoesNotMoveFunds() public {
        uint256 userBalanceBefore = otherAsset.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteMultiAssetDepositAsyncVault.AssetNotWhitelisted.selector, address(otherAsset)
            )
        );
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        assertEq(otherAsset.balanceOf(user1), userBalanceBefore, "user funds moved on revert");
        assertEq(otherAsset.balanceOf(address(multiAssetVault)), 0, "vault received non-base asset");
    }

    // ── previewDeposit ───────────────────────────────────────────────────────

    function testPreviewDepositBaseMatchesInherited() public view {
        uint256 previewMultiAsset = multiAssetVault.previewDeposit(address(asset), DEPOSIT_AMOUNT);
        uint256 previewInherited = multiAssetVault.previewDeposit(DEPOSIT_AMOUNT);
        assertEq(previewMultiAsset, previewInherited, "base previewDeposit diverges from inherited");
    }

    function testPreviewDepositNonBaseReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteMultiAssetDepositAsyncVault.AssetNotWhitelisted.selector, address(otherAsset)
            )
        );
        multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);
    }
}
