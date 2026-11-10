// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {ILiquidationModule, Liquidation} from "../../../src/periphery/interface/ILiquidationModule.sol";

/// @dev Minimal test double for `ILiquidationModule`. Exposes a bare-bones `hasRole` so it can be
///      cast to `IAccessControl` by `PositionHelperDolomiteAssetCX._hasLiquidatorRole`, plus a
///      settable `Liquidation` record per redemption id and call-tracking for
///      `initiateLiquidationCollateralSwap`.
contract MockLiquidationModule is ILiquidationModule {
    mapping(bytes32 => mapping(address => bool)) internal _roles;
    mapping(uint256 => Liquidation) internal _liquidations;
    mapping(address => mapping(uint256 => uint256[])) internal _liquidationIds;

    address public lastPositionOwner;
    uint256 public lastAccountNumber;
    uint256 public lastDebtAmountToLiquidate;
    address public lastReceiver;
    uint256 public callCount;
    uint256 public nextRedemptionId;

    // ── IAccessControl-compatible role check ──────────────────────────────────

    function grantRole(bytes32 role, address account) external {
        _roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external {
        _roles[role][account] = false;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    // ── Liquidation record setter/getters ──────────────────────────────────────

    /// @dev Seeds a `Liquidation` record and indexes it under `(liq.positionOwner, liq.accountNumber)`.
    function setLiquidation(uint256 redemptionId, Liquidation calldata liq) external {
        _liquidations[redemptionId] = liq;
        _liquidationIds[liq.positionOwner][liq.accountNumber].push(redemptionId);
    }

    function getLiquidation(uint256 redemptionId) external view returns (Liquidation memory) {
        return _liquidations[redemptionId];
    }

    function getLiquidationIds(address positionOwner, uint256 accountNumber) external view returns (uint256[] memory) {
        return _liquidationIds[positionOwner][accountNumber];
    }

    // ── Liquidation entry point ────────────────────────────────────────────────

    function initiateLiquidationCollateralSwap(
        address positionOwner,
        uint256 accountNumber,
        uint256 debtAmountToLiquidate,
        address receiver
    ) external returns (uint256 redemptionId) {
        lastPositionOwner = positionOwner;
        lastAccountNumber = accountNumber;
        lastDebtAmountToLiquidate = debtAmountToLiquidate;
        lastReceiver = receiver;
        callCount++;
        redemptionId = ++nextRedemptionId;
    }
}
