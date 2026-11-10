// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    IConcreteStandardVaultImpl,
    ConcreteStandardVaultImplBaseSetup
} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {IAllocateModule} from "../../../src/interface/IAllocateModule.sol";
import {ERC4626StrategyMock} from "../../mock/ERC4626StrategyMock.sol";
import {AddStrategyWithDeallocationOrder} from "../../common/AddStrategyWithDeallocationOrder.sol";

/// @notice Tests for the derived floating amount (cachedTotalAssets - SUM(allocated) + lockedAssets).
///         They assert the two properties that the refactor must preserve:
///         (1) donations never enter the vault accounting, and
///         (2) allocation can never exceed the idle (un-donated) balance.
contract DerivedFloatingUnitTest is ConcreteStandardVaultImplBaseSetup, AddStrategyWithDeallocationOrder {
    address public user1;
    ERC4626StrategyMock public strategy;

    uint256 internal constant DEPOSIT = 1000e18;
    uint256 internal constant DONATION = 500e18;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");

        strategy = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));
        addStrategyWithDeallocationOrder(address(strategy), address(concreteStandardVault), allocator, strategyOperator);

        asset.mint(user1, 1_000_000e18);
        vm.startPrank(user1);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        concreteStandardVault.deposit(DEPOSIT, user1);
        vm.stopPrank();

        assertEq(concreteStandardVault.cachedTotalAssets(), DEPOSIT);
    }

    function _donate(uint256 amount) internal {
        asset.mint(address(concreteStandardVault), amount);
    }

    function _allocate(uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({
            isDeposit: true, strategy: address(strategy), extraData: abi.encode(amount)
        });
        vm.prank(allocator);
        concreteStandardVault.allocate(abi.encode(params));
    }

    // ── Donation immunity ────────────────────────────────────────────────────

    /// @dev A direct token donation must not change the share price, total assets,
    ///      or what a holder can withdraw. The donated funds stay sweepable.
    function test_donation_doesNotAffectAccounting() public {
        uint256 shares = concreteStandardVault.balanceOf(user1);
        uint256 ptaBefore = concreteStandardVault.convertToAssets(shares);
        uint256 maxWithdrawBefore = concreteStandardVault.maxWithdraw(user1);
        uint256 totalAssetsBefore = concreteStandardVault.totalAssets();

        _donate(DONATION);

        assertEq(concreteStandardVault.cachedTotalAssets(), DEPOSIT, "cachedTotalAssets must ignore donation");
        assertEq(concreteStandardVault.totalAssets(), totalAssetsBefore, "totalAssets must ignore donation");
        assertEq(concreteStandardVault.convertToAssets(shares), ptaBefore, "share price must ignore donation");
        assertEq(concreteStandardVault.maxWithdraw(user1), maxWithdrawBefore, "maxWithdraw must ignore donation");

        // The donated surplus is sweepable.
        address sweepRecipient = makeAddr("sweepRecipient");
        vm.prank(vaultManager);
        concreteStandardVault.sweepDonatedTokens(address(asset), sweepRecipient);
        assertEq(asset.balanceOf(sweepRecipient), DONATION, "full donation must be sweepable");
    }

    /// @dev Even with idle funds fully allocated, a donation does not become withdrawable
    ///      value: redeeming pulls only the legitimately-backed assets and leaves the donation.
    function test_withdraw_ignoresDonation_whenFullyAllocated() public {
        _allocate(DEPOSIT); // idle -> 0
        _donate(DONATION);

        uint256 shares = concreteStandardVault.balanceOf(user1);
        vm.prank(user1);
        concreteStandardVault.redeem(shares, user1, user1);

        // The donation was never handed to the user; it remains in the vault, still sweepable.
        assertEq(asset.balanceOf(address(concreteStandardVault)), DONATION, "donation must remain in the vault");
    }

    // ── Over-allocation guard (Marcin note 1) ────────────────────────────────

    /// @dev Allocating more than the idle balance must revert, even though the donated
    ///      funds make the physical balance large enough for the strategy transfer to succeed.
    ///      Without the guard this would push donated funds into the strategy and drift accounting.
    function test_allocate_revertsWhenExceedingIdle_withDonation() public {
        _donate(DONATION); // physical balance is now DEPOSIT + DONATION

        vm.expectRevert(IConcreteStandardVaultImpl.InsufficientBalance.selector);
        _allocate(DEPOSIT + DONATION);

        // State is unchanged: nothing was allocated.
        assertEq(concreteStandardVault.getStrategyData(address(strategy)).allocated, 0);
        assertEq(concreteStandardVault.cachedTotalAssets(), DEPOSIT);
    }

    /// @dev Allocating exactly the idle balance succeeds even when a donation is present,
    ///      and the donation stays untouched (sweepable).
    function test_allocate_uptoIdle_succeeds_withDonation() public {
        _donate(DONATION);

        _allocate(DEPOSIT);

        assertEq(concreteStandardVault.getStrategyData(address(strategy)).allocated, DEPOSIT);
        assertEq(asset.balanceOf(address(concreteStandardVault)), DONATION, "donation must remain idle");

        address sweepRecipient = makeAddr("sweepRecipient");
        vm.prank(vaultManager);
        concreteStandardVault.sweepDonatedTokens(address(asset), sweepRecipient);
        assertEq(asset.balanceOf(sweepRecipient), DONATION);
    }
}
