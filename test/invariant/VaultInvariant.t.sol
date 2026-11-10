// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {InvariantTestBase} from "./InvariantTestBase.t.sol";
import {ConcreteStandardVaultHandler} from "./handlers/ConcreteStandardVaultHandler.t.sol";
import {InvariantUtils} from "./helpers/InvariantUtils.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

contract VaultInvariant is InvariantTestBase {
    ConcreteStandardVaultHandler public handler;

    function setUp() public override {
        super.setUp();

        handler = new ConcreteStandardVaultHandler(vault, asset, actorUtil);

        targetContract(address(handler));

        vm.label(address(handler), "ConcreteStandardVaultHandler");
    }

    /// @dev vault must always be solvent
    function invariant_vault_solvency() public view {
        uint256 totalShares = vault.totalSupply();

        // Vault must have enough assets to cover all shares
        uint256 redeemableAssets = vault.previewRedeem(totalShares);
        uint256 totalAssets = vault.totalAssets();
        assertGe(totalAssets, redeemableAssets, "INVARIANT: Vault is insolvent");
    }

    /// @dev Asset conservation - total assets must equal idle + allocated
    function invariant_asset_conservation() public view {
        uint256 totalAssets = vault.cachedTotalAssets();
        uint256 idleAssets = IERC20(vault.asset()).balanceOf(address(vault));
        uint256 strategiesTotal = vault.getTotalAllocated();

        assertEq(totalAssets, idleAssets + strategiesTotal, "INVARIANT: Asset conservation failed");
    }

    /// @dev deallocationOrder ⊆ strategies (every strategy in deallocation order must be in the strategies set)
    function invariant_deallocation_order_subset_of_strategies() public view {
        address[] memory deallocationOrder = vault.getDeallocationOrder();
        address[] memory strategies = vault.getStrategies();

        for (uint256 i = 0; i < deallocationOrder.length; i++) {
            address strategy = deallocationOrder[i];
            bool found = false;
            for (uint256 j = 0; j < strategies.length; j++) {
                if (strategies[j] == strategy) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "INVARIANT: deallocationOrder contains strategy not in strategies set");
        }
    }

    /// @dev Strategy allocation bounds
    function invariant_strategy_allocation_bounds() public view {
        uint256 totalAssets = vault.cachedTotalAssets();
        uint256 totalAllocated = vault.getTotalAllocated();

        // Total allocated cannot exceed total assets
        assertLe(totalAllocated, totalAssets, "INVARIANT: Total allocation exceeds total assets");
    }

    /// @dev ERC4626 max function accuracy with fee consideration
    function invariant_erc4626_max_functions() public view {
        (address user,) = actorUtil.fetchActor(5);

        // maxRedeem should be min(userBalance, maxWithdraw converted to shares)
        uint256 maxRedeem = vault.maxRedeem(user);
        uint256 userBalance = vault.balanceOf(user);

        // Calculate what maxWithdraw should be: min(user assets, available liquidity)
        // Use previewAccrueYield for up-to-date total assets like maxWithdraw() does
        (uint256 expectedTotalAssets, uint256 totalSupply) = vault.previewAccrueYield();

        uint256 availableLiquidity = InvariantUtils.calculateAvailableLiquidity(vault);

        // Convert expected maxWithdraw back to shares using same math as vault
        uint256 availableLiquidityShares =
            InvariantUtils.convertToShares(availableLiquidity, totalSupply, expectedTotalAssets, Math.Rounding.Floor);

        uint256 expectedMaxRedeem = userBalance < availableLiquidityShares ? userBalance : availableLiquidityShares;
        // Check if vault has fees
        (uint16 managementFee,,, uint16 performanceFee,) = vault.getFeeConfig();

        bool hasFees = managementFee > 0 || performanceFee > 0;

        if (hasFees) {
            // With fees, maxRedeem should be <= expectedMaxRedeem (fees reduce redeemable amount)
            assertLe(maxRedeem, expectedMaxRedeem, "INVARIANT: maxRedeem > expectedMaxRedeem with fees");
        } else {
            // Without fees, maxRedeem should equal expectedMaxRedeem
            assertEq(maxRedeem, expectedMaxRedeem, "INVARIANT: maxRedeem != expectedMaxRedeem without fees");
        }
    }
}
