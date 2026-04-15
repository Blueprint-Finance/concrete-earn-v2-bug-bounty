// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface ISwapModule {
    function swapExactAmountIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
    function swapExactAmountOut(address tokenIn, address tokenOut, uint256 maxAmountIn, uint256 amountOut)
        external
        returns (uint256 amountIn);
}
