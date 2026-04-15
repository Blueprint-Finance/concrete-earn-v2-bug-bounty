// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {TokenPair} from "./ILoopingPrimitive.sol";

interface ILenderModule {
    // Mutating operations
    function supply(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function borrow(uint256 amount) external;
    function repay(uint256 amount) external;

    // Token Addresses
    function collateralToken() external view returns (address);
    function borrowToken() external view returns (address);
    function getTokenPair() external view returns (TokenPair memory);

    // Position
    function getPosition() external view returns (uint256 collateralAmount, uint256 debtAmount);
    function getFullPosition()
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount, uint64 currentLtvInWad, uint256 collateralPriceInRay);
    function getCollateralAmount() external view returns (uint256);
    function getDebtAmount() external view returns (uint256);
    function getCurrentLtvInWad() external view returns (uint64);
    function getAvailablePoolLiquidity() external view returns (uint256);

    // Lender Parameters and Prices
    function getMaxLtvInWad() external view returns (uint64);
    function getCurrentBorrowRateInWad() external view returns (uint64);
    function getCurrentLiquidityRateInWad() external view returns (uint64);
    function getCurrentEstimatedRewards() external view returns (uint64 rateInWad, uint256 amount);
    function collateralPriceInBorrowTokensInRay() external view returns (uint256);
}

