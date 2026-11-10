// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    IConcreteStandardVaultImpl,
    ConcreteStandardVaultImplBaseSetup
} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {ERC4626Upgradeable} from "@openzeppelin-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {console2 as console} from "forge-std/console2.sol";

contract UserInteractionsUnitTest is ConcreteStandardVaultImplBaseSetup {
    address public user1;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");

        // fund user account
        asset.mint(user1, 2000000e18);

        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), 2000000e18);
        concreteStandardVault.deposit(1000000e18, user1);
        vm.stopPrank();
    }

    function testDepositInvalidReceiver() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidReceiver.selector));
        concreteStandardVault.deposit(1000000e18, address(0));
        vm.stopPrank();
    }

    function testDepositInvalidUpperLimitAmount() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(0, 1000000e18)
        );

        // `ERC4626ExceededMaxDeposit(receiver, assets, max)` — max is 0 here because the base setup
        // already deposited up to `maxGlobalDepositAmount`, so `calcMaxDeposit` returns no headroom.
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user1, 1000000e19, 0)
        );
        vm.startPrank(user1);
        concreteStandardVault.deposit(1000000e19, user1);
        vm.stopPrank();
    }

    function testDepositInvalidLowerLimitAmount() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(1000000e18, 2000000e18)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteStandardVaultImpl.MinimumDepositAmountNotMet.selector, user1, 1000000e17, 1000000e18
            )
        );

        console.log("antes de deposit");
        vm.startPrank(user1);
        concreteStandardVault.deposit(1000000e17, user1);
        vm.stopPrank();
    }

    function testMintInvalidReceiver() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidReceiver.selector));
        concreteStandardVault.mint(1000000e18, address(0));
        vm.stopPrank();
    }

    function testMintInvalidUpperLimitAmount() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(0, 1000000e16)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, user1, 1000000e17, 0)
        );
        vm.startPrank(user1);
        concreteStandardVault.mint(1000000e17, user1);
        vm.stopPrank();
    }

    function testMintInvalidLowerLimitAmount() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(1000000e18, 2000000e18)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteStandardVaultImpl.MinimumDepositAmountNotMet.selector, user1, 1000000e17, 1000000e18
            )
        );
        vm.startPrank(user1);
        concreteStandardVault.mint(1000000e17, user1);
        vm.stopPrank();
    }

    function testWithdrawInvalidReceiver() public {
        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidReceiver.selector));
        concreteStandardVault.withdraw(1000000e18, address(0), user1);

        vm.stopPrank();
    }

    function testWithdrawInvalidUpperLimitAmount() public {
        // First deposit to have assets to withdraw
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), 1000000e18);
        concreteStandardVault.deposit(1000000e18, user1);

        // Verify the deposit worked
        uint256 userShares = concreteStandardVault.balanceOf(user1);
        uint256 userAssets = concreteStandardVault.previewRedeem(userShares);
        assertGt(userShares, 0, "User should have shares after deposit");
        assertGt(userAssets, 0, "User should have assets after deposit");
        vm.stopPrank();

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(0, 1000000e17)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 1000000e18, 1000000e17
            )
        );
        vm.startPrank(user1);
        concreteStandardVault.withdraw(1000000e18, user1, user1);
        vm.stopPrank();
    }

    function testWithdrawInvalidLowerLimitAmount() public {
        // First deposit to have assets to withdraw
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), 1000000e18);
        concreteStandardVault.deposit(1000000e18, user1);

        // Verify the deposit worked
        uint256 userShares = concreteStandardVault.balanceOf(user1);
        uint256 userAssets = concreteStandardVault.previewRedeem(userShares);
        assertGt(userShares, 0, "User should have shares after deposit");
        assertGt(userAssets, 0, "User should have assets after deposit");
        vm.stopPrank();

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(1000000e18, 1000000e18)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteStandardVaultImpl.MinimumWithdrawAmountNotMet.selector, user1, 1000000e17, 1000000e18
            )
        );
        vm.startPrank(user1);
        concreteStandardVault.withdraw(1000000e17, user1, user1);
        vm.stopPrank();
    }

    function testRedeemInvalidReceiver() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InvalidReceiver.selector));
        concreteStandardVault.redeem(1000000e18, address(0), user1);
        vm.stopPrank();
    }

    function testRedeemInvalidUpperLimitAmount() public {
        // First deposit to have shares to redeem
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), 1000000e18);
        concreteStandardVault.deposit(1000000e18, user1);

        // Verify the deposit worked
        uint256 userShares = concreteStandardVault.balanceOf(user1);
        assertGt(userShares, 0, "User should have shares after deposit");
        vm.stopPrank();

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(0, 1000000e17)
        );
        console.log("usuarios shares", concreteStandardVault.balanceOf(user1));
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, 1000000e18, 1000000e17)
        );
        vm.startPrank(user1);

        concreteStandardVault.redeem(1000000e18, user1, user1);
        vm.stopPrank();
    }

    function testRedeemInvalidLowerLimitAmount() public {
        // First deposit to have shares to redeem
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), 1000000e18);
        concreteStandardVault.deposit(1000000e18, user1);

        // Verify the deposit worked
        uint256 userShares = concreteStandardVault.balanceOf(user1);
        assertGt(userShares, 0, "User should have shares after deposit");
        vm.stopPrank();

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(1000000e18, 1000000e18)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IConcreteStandardVaultImpl.MinimumWithdrawAmountNotMet.selector, user1, 1000000e17, 1000000e18
            )
        );
        vm.startPrank(user1);
        concreteStandardVault.redeem(1000000e17, user1, user1);
        vm.stopPrank();
    }

    // ─── maxDeposit / maxMint must return 0 when below minimum ─────────

    function testMaxDepositReturnsZeroWhenRemainingCapacityBelowMinimum() public {
        // Global limit = 1_050_000e18. Already deposited 1_000_000e18 in setUp.
        // Remaining = 50_000e18. Set min deposit = 100_000e18.
        // maxDeposit should return 0 because 50_000 < 100_000.
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(100_000e18, 1_050_000e18)
        );

        uint256 maxDep = concreteStandardVault.maxDeposit(user1);
        assertEq(maxDep, 0, "maxDeposit should be 0 when remaining capacity < minTxDepositAmount");
    }

    function testMaxDepositReturnsValueWhenRemainingCapacityAboveMinimum() public {
        // Global limit = 1_200_000e18. Already deposited 1_000_000e18.
        // Remaining = 200_000e18. Set min deposit = 100_000e18.
        // maxDeposit should return 200_000e18.
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(100_000e18, 1_200_000e18)
        );

        uint256 maxDep = concreteStandardVault.maxDeposit(user1);
        assertEq(maxDep, 200_000e18, "maxDeposit should return remaining capacity when >= minTxDepositAmount");
    }

    function testMaxDepositReturnsValueWhenRemainingCapacityEqualsMinimum() public {
        // Remaining exactly equals minimum — should still be valid.
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(100_000e18, 1_100_000e18)
        );

        uint256 maxDep = concreteStandardVault.maxDeposit(user1);
        assertEq(maxDep, 100_000e18, "maxDeposit should return remaining capacity when == minTxDepositAmount");
    }

    function testMaxMintReturnsZeroWhenRemainingCapacityBelowMinimum() public {
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(100_000e18, 1_050_000e18)
        );

        uint256 maxM = concreteStandardVault.maxMint(user1);
        assertEq(maxM, 0, "maxMint should be 0 when remaining deposit capacity < minTxDepositAmount");
    }

    function testDepositMaxDepositShouldNotRevert() public {
        // Ensure calling deposit(maxDeposit(user)) succeeds when maxDeposit > 0
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(100_000e18, 1_200_000e18)
        );

        uint256 maxDep = concreteStandardVault.maxDeposit(user1);
        assertGt(maxDep, 0, "precondition: maxDeposit should be > 0");

        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), maxDep);
        concreteStandardVault.deposit(maxDep, user1);
        vm.stopPrank();
    }

    // ─── maxWithdraw / maxRedeem must return 0 when below minimum ────

    function testMaxWithdrawReturnsZeroWhenOwnerBalanceBelowMinimum() public {
        address smallUser = makeAddr("smallUser");
        asset.mint(smallUser, 50e18);

        vm.startPrank(smallUser);
        asset.approve(address(concreteStandardVault), 50e18);
        concreteStandardVault.deposit(50e18, smallUser);
        vm.stopPrank();

        // Set min withdraw = 100e18, which is above smallUser's 50e18 balance.
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(100e18, type(uint256).max)
        );

        uint256 maxW = concreteStandardVault.maxWithdraw(smallUser);
        assertEq(maxW, 0, "maxWithdraw should be 0 when owner assets < minTxWithdrawAmount");
    }

    function testMaxWithdrawReturnsValueWhenOwnerBalanceAboveMinimum() public {
        // user1 has 1_000_000e18 deposited.  min = 100e18, max = type(uint256).max
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(100e18, type(uint256).max)
        );

        uint256 maxW = concreteStandardVault.maxWithdraw(user1);
        assertGt(maxW, 0, "maxWithdraw should be > 0 when owner assets >= minTxWithdrawAmount");
    }

    function testMaxRedeemReturnsZeroWhenResultingAssetsBelowMinimum() public {
        address smallUser = makeAddr("smallUser");
        asset.mint(smallUser, 50e18);

        vm.startPrank(smallUser);
        asset.approve(address(concreteStandardVault), 50e18);
        concreteStandardVault.deposit(50e18, smallUser);
        vm.stopPrank();

        // Set min withdraw = 100e18, which is above smallUser's ~50e18 worth of shares.
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(100e18, type(uint256).max)
        );

        uint256 maxR = concreteStandardVault.maxRedeem(smallUser);
        assertEq(maxR, 0, "maxRedeem should be 0 when resulting assets < minTxWithdrawAmount");
    }

    function testMaxRedeemReturnsValueWhenResultingAssetsAboveMinimum() public {
        // user1 has 1_000_000e18.  min = 100e18 → maxRedeem should be > 0.
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(100e18, type(uint256).max)
        );

        uint256 maxR = concreteStandardVault.maxRedeem(user1);
        assertGt(maxR, 0, "maxRedeem should be > 0 when resulting assets >= minTxWithdrawAmount");
    }

    function testWithdrawMaxWithdrawShouldNotRevert() public {
        // Ensure calling withdraw(maxWithdraw(user)) succeeds when maxWithdraw > 0
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(100e18, 500_000e18)
        );

        uint256 maxW = concreteStandardVault.maxWithdraw(user1);
        assertGt(maxW, 0, "precondition: maxWithdraw should be > 0");

        vm.prank(user1);
        concreteStandardVault.withdraw(maxW, user1, user1);
    }

    function testRedeemMaxRedeemShouldNotRevert() public {
        // Ensure calling redeem(maxRedeem(user)) succeeds when maxRedeem > 0
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(100e18, 500_000e18)
        );

        uint256 maxR = concreteStandardVault.maxRedeem(user1);
        assertGt(maxR, 0, "precondition: maxRedeem should be > 0");

        vm.prank(user1);
        concreteStandardVault.redeem(maxR, user1, user1);
    }

    function testDepositInsufficientShares() public {
        vm.prank(user1);
        concreteStandardVault.deposit(1e18, user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientShares.selector));
        concreteStandardVault.deposit(0, user1); // Zero amount should result in 0 shares
    }

    function testRedeemInsufficientAssets() public {
        vm.prank(user1);
        concreteStandardVault.deposit(1000000e18, user1);

        vm.expectRevert(abi.encodeWithSelector(IConcreteStandardVaultImpl.InsufficientAssets.selector));
        vm.prank(user1);
        concreteStandardVault.redeem(0, user1, user1); // Zero shares should result in 0 assets
    }

    function testPausePreventsDeposit() public {
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.deposit(1000e18, user1);
    }

    function testPausePreventsMint() public {
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.mint(1000e18, user1);
    }

    function testPausePreventsWithdraw() public {
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.withdraw(100e18, user1, user1);
    }

    function testPausePreventsRedeem() public {
        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);

        vm.prank(pauser);
        concreteStandardVault.pause();

        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        concreteStandardVault.redeem(100e18, user1, user1);
    }

    function testMaxDepositReturnsZeroWhenPaused() public {
        assertGt(concreteStandardVault.maxDeposit(user1), 0, "precondition: maxDeposit > 0 when unpaused");

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);
        vm.prank(pauser);
        concreteStandardVault.pause();

        assertEq(concreteStandardVault.maxDeposit(user1), 0);
    }

    function testMaxMintReturnsZeroWhenPaused() public {
        assertGt(concreteStandardVault.maxMint(user1), 0, "precondition: maxMint > 0 when unpaused");

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);
        vm.prank(pauser);
        concreteStandardVault.pause();

        assertEq(concreteStandardVault.maxMint(user1), 0);
    }

    function testMaxWithdrawReturnsZeroWhenPaused() public {
        assertGt(concreteStandardVault.maxWithdraw(user1), 0, "precondition: maxWithdraw > 0 when unpaused");

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);
        vm.prank(pauser);
        concreteStandardVault.pause();

        assertEq(concreteStandardVault.maxWithdraw(user1), 0);
    }

    function testMaxRedeemReturnsZeroWhenPaused() public {
        assertGt(concreteStandardVault.maxRedeem(user1), 0, "precondition: maxRedeem > 0 when unpaused");

        address pauser = makeAddr("pauser");
        vm.prank(vaultManager);
        concreteStandardVault.grantRole(RolesLib.PAUSER, pauser);
        vm.prank(pauser);
        concreteStandardVault.pause();

        assertEq(concreteStandardVault.maxRedeem(user1), 0);
    }
}
