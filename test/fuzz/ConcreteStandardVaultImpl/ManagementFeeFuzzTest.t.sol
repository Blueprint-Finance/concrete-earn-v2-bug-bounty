// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy,
    IConcreteStandardVaultImpl,
    ConcreteStandardVaultImpl,
    ConcreteStandardVaultImplBaseSetup
} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";

import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {InvariantUtils} from "../../invariant/helpers/InvariantUtils.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

contract ManagementFeeFuzzTest is ConcreteStandardVaultImplBaseSetup {
    address public user1;
    address public managementFeeRecipient;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        managementFeeRecipient = makeAddr("managementFeeRecipient");
    }

    function testFuzzManagementFeeAccrual(uint256 timeElapsed, uint256 initialDeposit, uint16 managementFee) public {
        // Bound inputs to realistic ranges
        timeElapsed = bound(timeElapsed, 1 seconds, 2 * 365 days); // 1 second to 2 years
        initialDeposit = bound(initialDeposit, 1e18, 1000000e18); // 1 to 1M tokens
        managementFee = uint16(bound(managementFee, 1, 1000)); // 0.01% to 10% (max allowed)

        // Set up fresh vault with new parameters
        uint64 vaultImpl = uint64(IContractId(address(concreteStandardVaultImpl)).ID());
        ConcreteStandardVaultImpl newVault = ConcreteStandardVaultImpl(
            factory.create(
                vaultImpl,
                vaultManager,
                abi.encode(address(allocateModule), address(asset), vaultManager, "Test Vault", "TV")
            )
        );
        vm.prank(vaultManager);
        newVault.grantRole(RolesLib.ALLOCATOR, vaultManager);

        // Set management fee
        vm.prank(factoryOwner);
        newVault.updateManagementFeeRecipient(managementFeeRecipient);

        vm.prank(vaultManager);
        newVault.updateManagementFee(managementFee);

        // Make initial deposit
        asset.mint(user1, initialDeposit);
        vm.startPrank(user1);
        asset.approve(address(newVault), initialDeposit);
        newVault.deposit(initialDeposit, user1);
        vm.stopPrank();
        // management fee shares should always be 0 on first deposit
        assertEq(newVault.balanceOf(managementFeeRecipient), 0);

        // Skip time
        vm.warp(block.timestamp + timeElapsed);

        (,, uint32 lastAccrual,,) = newVault.getFeeConfig();
        uint256 annualFeeAmount = (newVault.cachedTotalAssets() * managementFee) / 10_000;
        uint256 expectedFeeAmount = (annualFeeAmount * (block.timestamp - lastAccrual)) / 365 days;
        uint256 expectedShares = InvariantUtils.convertToShares(
            expectedFeeAmount,
            newVault.totalSupply(),
            newVault.cachedTotalAssets() - expectedFeeAmount,
            Math.Rounding.Floor
        );

        // Accrue yield and verify
        vm.prank(vaultManager);
        newVault.accrueYield();
        uint256 actualShares = newVault.balanceOf(managementFeeRecipient);
        assertEq(actualShares, expectedShares);

        timeElapsed = bound(timeElapsed, 1 seconds, 2 * 365 days);
        vm.warp(block.timestamp + timeElapsed);

        (,, lastAccrual,,) = newVault.getFeeConfig();
        annualFeeAmount = (newVault.cachedTotalAssets() * managementFee) / 10_000;
        expectedFeeAmount = (annualFeeAmount * (block.timestamp - lastAccrual)) / 365 days;
        expectedShares = InvariantUtils.convertToShares(
            expectedFeeAmount,
            newVault.totalSupply(),
            newVault.cachedTotalAssets() - expectedFeeAmount,
            Math.Rounding.Floor
        );
        uint256 recipientSharesBefore = newVault.balanceOf(managementFeeRecipient);

        // Accrue yield and verify
        vm.prank(vaultManager);
        newVault.accrueYield();
        actualShares = newVault.balanceOf(managementFeeRecipient);
        assertEq(actualShares, recipientSharesBefore + expectedShares);
    }
}
