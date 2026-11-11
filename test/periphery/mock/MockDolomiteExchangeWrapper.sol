// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  MockDolomiteExchangeWrapper
/// @notice Test double for Dolomite's `IExchangeWrapper` (dolomite-margin is pinned to Solidity
///         ^0.5.7, so it can't be imported directly into this ^0.8 test suite — this mirrors only
///         the ABI, which is all DolomiteMargin's low-level `operate()` call cares about).
///
/// @dev DolomiteMargin's `Sell` action, for a `Sell` of `takerToken` (collateral) into
///      `makerToken` (borrow token):
///        1. transfers `_requestedFillAmount` of `takerToken` to this contract BEFORE calling
///           `exchange` (see `Exchange.exchange` in dolomite-margin's `TradeImpl`/`Exchange.sol`).
///        2. calls `exchange(...)`, expecting the returned `uint256` to be the amount of
///           `makerToken` this contract will hand over.
///        3. immediately `transferFrom`s that returned amount of `makerToken` from this contract,
///           so this contract must hold the balance and have approved `_receiver` beforehand.
///      The payout is whatever the test last set via `setOutputAmount`, decoupled from the taker
///      amount actually received — that lets tests dial in exact slippage scenarios (favourable,
///      within bound, breaching bound) independent of live oracle/market prices.
contract MockDolomiteExchangeWrapper {
    using SafeERC20 for IERC20;

    uint256 public outputAmount;

    /// @notice Sets the amount of `makerToken` this wrapper reports/pays out on the next `exchange` call.
    function setOutputAmount(uint256 outputAmount_) external {
        outputAmount = outputAmount_;
    }

    /// @dev Signature must match dolomite-margin's `IExchangeWrapper.exchange` exactly (ABI-level
    ///      call from DolomiteMargin, so only the selector/types matter, not the pragma).
    function exchange(
        address, /* tradeOriginator */
        address receiver,
        address makerToken,
        address, /* takerToken */
        uint256, /* requestedFillAmount */
        bytes calldata /* orderData */
    )
        external
        returns (uint256)
    {
        IERC20(makerToken).forceApprove(receiver, outputAmount);
        return outputAmount;
    }

    /// @dev Only used by dolomite-margin's `Buy` action; unused by `Sell` but kept for interface parity.
    function getExchangeCost(address, address, uint256, bytes calldata) external view returns (uint256) {
        return outputAmount;
    }
}
