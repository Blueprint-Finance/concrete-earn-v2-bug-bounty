// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;
pragma abicoder v2;

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {ISwapModule} from "../interface/ISwapModule.sol";

/**
 * @notice Uniswap V3 swapper for exactly one pair:
 *         COLLATERAL_TOKEN <-> BORROW_TOKEN, optionally via INTERMEDIARY_TOKEN.
 *
 * Immutable constructor args:
 *  - router
 *  - collateralToken
 *  - borrowToken
 *  - intermediaryToken (optional)
 *  - fee1
 *  - fee2 (optional)
 *
 * Semantics:
 *  - If intermediaryToken == address(0):
 *      * Direct pool between collateralToken and borrowToken.
 *      * fee1 is the pool fee (same both ways).
 *      * fee2 must be 0.
 *  - If intermediaryToken != address(0):
 *      * Two pools:
 *          collateralToken <-> intermediaryToken with fee1
 *          borrowToken     <-> intermediaryToken with fee2
 *      * fee1 and fee2 must both be non-zero.
 */
contract SwapModuleUniV3 is ISwapModule {
    using SafeERC20 for IERC20;

    // ---------- immutables ----------
    ISwapRouter public immutable ROUTER;
    address public immutable COLLATERAL;
    address public immutable BORROW;
    address public immutable INTERMEDIARY; // optional
    uint24 public immutable FEE1;
    uint24 public immutable FEE2;

    // ---------- custom errors ----------
    error ZeroAddress();
    error ZeroToken();
    error ZeroFee();
    error InvalidConfig();
    error ZeroAmount();
    error InvalidTokenIn();
    error InvalidTokenOut();
    error InvalidPair();

    constructor(
        ISwapRouter _router,
        address _collateralToken,
        address _borrowToken,
        address _intermediaryToken,
        uint24 _fee1,
        uint24 _fee2
    ) {
        if (address(_router) == address(0)) revert ZeroAddress();
        if (_collateralToken == address(0) || _borrowToken == address(0)) revert ZeroToken();
        if (_collateralToken == _borrowToken) revert InvalidConfig();
        if (_fee1 == 0) revert ZeroFee();

        if (_intermediaryToken == address(0)) {
            // Direct swap only, FEE2 must be zero for sanity.
            if (_fee2 != 0) revert InvalidConfig();
        } else {
            // Two-hop via intermediary
            if (_intermediaryToken == _collateralToken || _intermediaryToken == _borrowToken) {
                revert InvalidConfig();
            }
            if (_fee2 == 0) revert ZeroFee();
        }

        ROUTER = _router;
        COLLATERAL = _collateralToken;
        BORROW = _borrowToken;
        INTERMEDIARY = _intermediaryToken;
        FEE1 = _fee1;
        FEE2 = _fee2;

        IERC20(COLLATERAL).forceApprove(address(ROUTER), type(uint256).max);
        IERC20(BORROW).forceApprove(address(ROUTER), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function swapExactAmountIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();

        bool collateralToBorrow;

        if (tokenIn == COLLATERAL) {
            if (tokenOut != BORROW) revert InvalidTokenOut();
            collateralToBorrow = true; // COLLATERAL -> BORROW
        } else if (tokenIn == BORROW) {
            if (tokenOut != COLLATERAL) revert InvalidTokenOut();
            collateralToBorrow = false; // BORROW -> COLLATERAL
        } else {
            revert InvalidTokenIn();
        }

        // Pull from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (INTERMEDIARY == address(0)) {
            // Direct single-hop
            amountOut = _swapExactInDirect(collateralToBorrow, amountIn, minAmountOut);
        } else {
            // Two-hop via INTERMEDIARY
            amountOut = _swapExactInViaIntermediary(collateralToBorrow, amountIn, minAmountOut);
        }
    }

    function swapExactAmountOut(address tokenIn, address tokenOut, uint256 maxAmountIn, uint256 amountOut)
        external
        override
        returns (uint256 amountIn)
    {
        if (maxAmountIn == 0 || amountOut == 0) revert ZeroAmount();

        bool collateralToBorrow;

        if (tokenIn == COLLATERAL) {
            if (tokenOut != BORROW) revert InvalidTokenOut();
            collateralToBorrow = true; // COLLATERAL -> BORROW
        } else if (tokenIn == BORROW) {
            if (tokenOut != COLLATERAL) revert InvalidTokenOut();
            collateralToBorrow = false; // BORROW -> COLLATERAL
        } else {
            revert InvalidTokenIn();
        }

        // Pull max from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), maxAmountIn);

        if (INTERMEDIARY == address(0)) {
            // Direct single-hop
            amountIn = _swapExactOutDirect(collateralToBorrow, maxAmountIn, amountOut);
        } else {
            // Two-hop via INTERMEDIARY
            amountIn = _swapExactOutViaIntermediary(collateralToBorrow, maxAmountIn, amountOut);
        }

        // Refund any unused input
        if (amountIn < maxAmountIn) {
            IERC20(tokenIn).safeTransfer(msg.sender, maxAmountIn - amountIn);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL SWAP HELPERS
    //////////////////////////////////////////////////////////////*/

    // -------- exact in, direct (no intermediary) --------

    function _swapExactInDirect(bool collateralToBorrow, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        (address tokenIn, address tokenOut) = collateralToBorrow ? (COLLATERAL, BORROW) : (BORROW, COLLATERAL);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE1,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = ROUTER.exactInputSingle(params);
    }

    // -------- exact in, with intermediary --------

    function _swapExactInViaIntermediary(bool collateralToBorrow, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        // path: tokenIn -> INTERMEDIARY -> tokenOut
        bytes memory path;

        if (collateralToBorrow) {
            // COLLATERAL -(FEE1)-> INTERMEDIARY -(FEE2)-> BORROW
            path = abi.encodePacked(COLLATERAL, FEE1, INTERMEDIARY, FEE2, BORROW);
        } else {
            // BORROW -(FEE2)-> INTERMEDIARY -(FEE1)-> COLLATERAL
            path = abi.encodePacked(BORROW, FEE2, INTERMEDIARY, FEE1, COLLATERAL);
        }

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut
        });

        amountOut = ROUTER.exactInput(params);
    }

    // -------- exact out, direct (no intermediary) --------

    function _swapExactOutDirect(bool collateralToBorrow, uint256 maxAmountIn, uint256 amountOut)
        internal
        returns (uint256 amountIn)
    {
        (address tokenIn, address tokenOut) = collateralToBorrow ? (COLLATERAL, BORROW) : (BORROW, COLLATERAL);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE1,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: amountOut,
            amountInMaximum: maxAmountIn,
            sqrtPriceLimitX96: 0
        });

        amountIn = ROUTER.exactOutputSingle(params);
    }

    // -------- exact out, with intermediary --------

    function _swapExactOutViaIntermediary(bool collateralToBorrow, uint256 maxAmountIn, uint256 amountOut)
        internal
        returns (uint256 amountIn)
    {
        // For exactOutput, path is reversed: tokenOut -> INTERMEDIARY -> tokenIn
        bytes memory path;

        if (collateralToBorrow) {
            // input: COLLATERAL, output: BORROW
            // path: BORROW -(FEE2)-> INTERMEDIARY -(FEE1)-> COLLATERAL
            path = abi.encodePacked(BORROW, FEE2, INTERMEDIARY, FEE1, COLLATERAL);
        } else {
            // input: BORROW, output: COLLATERAL
            // path: COLLATERAL -(FEE1)-> INTERMEDIARY -(FEE2)-> BORROW
            path = abi.encodePacked(COLLATERAL, FEE1, INTERMEDIARY, FEE2, BORROW);
        }

        ISwapRouter.ExactOutputParams memory params = ISwapRouter.ExactOutputParams({
            path: path,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: amountOut,
            amountInMaximum: maxAmountIn
        });

        amountIn = ROUTER.exactOutput(params);
    }
}
