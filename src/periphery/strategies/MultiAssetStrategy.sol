// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MultisigStrategy} from "./MultisigStrategy.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";
import {MultisigStrategyStorageLib as MultisigStrategyStorage} from "../lib/MultisigStrategyStorageLib.sol";
import {PositionAccountingLib} from "../lib/PositionAccountingLib.sol";
import {IMultiAssetDepositStrategy} from "../../interface/IMultiAssetDepositStrategy.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MultiAssetStrategy
 * @notice Multisig-custody strategy that additionally accepts multi-asset deposits routed straight
 *         from a {ConcreteMultiAssetDepositAsyncVault}. It behaves exactly like {MultisigStrategy}
 *         for base-asset flows, and adds {allocateFundsMultiAsset} so the bound vault can push a
 *         raw non-base asset while the strategy records the position in base units.
 * @dev Reuses the {MultisigStrategy} storage, accounting and initializer verbatim; only the
 *      contract flavour and the multi-asset entrypoint are added.
 * @dev Uses EIP-7201 storage layout for upgradeability.
 */
contract MultiAssetStrategy is MultisigStrategy, IMultiAssetDepositStrategy {
    using SafeERC20 for IERC20;

    /// @notice Thrown when `depositAmount` or `baseValue` is zero.
    error ZeroMultiAssetAllocation();

    /// @notice Emitted when a non-base deposit is forwarded to the multi-sig and booked in base units.
    /// @param multiSig The multi-sig wallet that received `depositAsset`.
    /// @param depositAsset The raw non-base asset forwarded.
    /// @param depositAmount The amount of `depositAsset` forwarded.
    /// @param baseValue The base-asset value booked in strategy accounting.
    event AllocateFundsMultiAsset(
        address indexed multiSig, address indexed depositAsset, uint256 depositAmount, uint256 baseValue
    );

    function FLAVOUR() public pure virtual override returns (uint256) {
        return 8; // multi-asset (multisig custody) strategy
    }

    function ID() public pure virtual override(MultisigStrategy) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 7, 0);
    }

    /**
     * @inheritdoc IMultiAssetDepositStrategy
     * @dev Multi-asset variant of {allocateFunds}: instead of pulling the base `asset()`, it pulls
     *      the raw `depositAsset` from the calling vault and forwards it to the multi-sig, while
     *      recording the vault-supplied `baseValue` in the base-denominated `vaultDepositedAmount`.
     *      This keeps `totalAllocatedValue()` in lockstep with the vault's `allocated`.
     */
    function allocateFundsMultiAsset(address depositAsset, uint256 depositAmount, uint256 baseValue)
        external
        override
        onlyVault
        whenNotPaused
        returns (uint256)
    {
        if (depositAmount == 0 || baseValue == 0) revert ZeroMultiAssetAllocation();

        PositionAccountingLib._checkAccountingValidity();

        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        multisigStrategyStorage.vaultDepositedAmount += baseValue;

        // Mirror base allocate: AssetsForwarded (custody hop) + AllocateFundsMultiAsset (base units booked).
        IERC20(depositAsset).safeTransferFrom(msg.sender, multisigStrategyStorage.multiSig, depositAmount);
        emit AssetsForwarded(multisigStrategyStorage.multiSig, depositAsset, depositAmount);
        emit AllocateFundsMultiAsset(multisigStrategyStorage.multiSig, depositAsset, depositAmount, baseValue);

        return baseValue;
    }
}
