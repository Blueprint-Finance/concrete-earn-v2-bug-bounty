// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IDolomiteMargin} from "../interface/IDolomiteMargin.sol";
import {PositionManagementHelperStorageLib as PMHSLib} from "./PositionManagementHelperStorageLib.sol";

/// @title  DolomiteInitLib
/// @notice Per-clone Dolomite init: validates encoded market IDs and sets MAX token allowances
///         (see `PositionHelperDolomiteBase.__PositionHelperDolomiteBase_init`).
///
/// @dev Deployed as an external library and called via `DELEGATECALL` — like
///      `DolomitePositionViewLib`, this keeps the init logic out of every concrete flavour's
///      own bytecode instead of duplicating it per-flavour, several of which sit close to the
///      EIP-170 runtime size limit.
library DolomiteInitLib {
    using SafeERC20 for IERC20;

    /// @dev Reverts when an encoded market ID does not resolve to the encoded token.
    error MarketIdTokenMismatch(uint256 marketId, address token);

    /// @dev Asserts each encoded market ID round-trips to its encoded token, then sets MAX
    ///      allowances. A missing market-ID suffix makes the read return garbage, so
    ///      `getMarketTokenAddress` reverts (or the comparison fails) and the clone cannot
    ///      finish initialization.
    ///
    ///      Skips approvals for zero addresses (e.g. when flash+swap are omitted in favour of a
    ///      flavour-specific liquidation mechanism). Reads swapModule/flashModule/yieldVault
    ///      straight from storage rather than taking them as params — cheaper calldata for the
    ///      DELEGATECALL and one less thing for callers to keep in sync.
    function init(
        address dolomiteMargin,
        address collateralToken,
        address borrowToken,
        uint256 collateralMarketId,
        uint256 borrowMarketId
    ) public {
        IDolomiteMargin dolomite = IDolomiteMargin(dolomiteMargin);
        if (dolomite.getMarketTokenAddress(collateralMarketId) != collateralToken) {
            revert MarketIdTokenMismatch(collateralMarketId, collateralToken);
        }
        if (dolomite.getMarketTokenAddress(borrowMarketId) != borrowToken) {
            revert MarketIdTokenMismatch(borrowMarketId, borrowToken);
        }

        PMHSLib.PMHStorage storage $ = PMHSLib.fetch();
        address swapModule_ = $.swapModule;
        address flashModule_ = $.flashModule;
        address yieldVault_ = $.yieldVault;

        IERC20(collateralToken).forceApprove(dolomiteMargin, type(uint256).max);
        if (swapModule_ != address(0)) IERC20(collateralToken).forceApprove(swapModule_, type(uint256).max);

        IERC20(borrowToken).forceApprove(dolomiteMargin, type(uint256).max);
        IERC20(borrowToken).forceApprove(yieldVault_, type(uint256).max);
        if (flashModule_ != address(0)) IERC20(borrowToken).forceApprove(flashModule_, type(uint256).max);

        IERC20(yieldVault_).forceApprove(yieldVault_, type(uint256).max);
    }
}
