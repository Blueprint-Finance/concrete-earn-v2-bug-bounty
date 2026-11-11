// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {LoopModality} from "./LoopModalityLib.sol";

library LoopingPrimitiveErrors {
    error InvalidCaller(address caller, address expected);
    error InvalidRequester(address requester, address expected);
    error InsufficientFlashLiquidity(address token, uint256 requiredFlashLiquidity, uint256 depthOfFlashLiquidity);
    error TargetLtvUpperBoundReached(LoopModality loopModality, uint64 targetLtvInWad, uint256 targetLtvUpperBound);
    error DeallocationUpperBoundReached(
        LoopModality loopModality, uint256 floatingAmount, uint256 deallocationUpperBound
    );
    error InsufficientSwapOutput(uint256 amountOut, uint256 requiredPayBackAmount);
    error InvalidFloatingAmount(uint256 floatingAmount, uint256 flashAmount);
    error ZeroFlashModuleAddress();
    error ZeroSwapModuleAddress();
    error FlashLoanFailed();
}
