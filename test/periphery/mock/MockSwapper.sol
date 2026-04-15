// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {ISwapModule} from "../../../src/periphery/interface/ISwapModule.sol";
import {WAD} from "../../../src/periphery/lib/Constants.sol";

import {IMintableERC20} from "./ERC20Mock.sol";

contract MockSwapper is ISwapModule {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error Unauthorized();
    error InvalidRate();
    error InvalidSlippage();
    error InsufficientOutput(uint256 required, uint256 actual);
    error ExcessiveInput(uint256 required, uint256 maxAllowed);

    event RateUpdated(address indexed tokenIn, address indexed tokenOut, uint256 numerator, uint256 denominator);
    event SlippageUpdated(address indexed tokenIn, address indexed tokenOut, uint256 slippageInWad);

    struct Rate {
        uint256 numerator;
        uint256 denominator;
        uint256 slippageInWad;
    }

    address public immutable admin;

    mapping(bytes32 => Rate) private rates;

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    function swapExactAmountIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        Rate memory rate = _getRate(tokenIn, tokenOut);
        amountOut = Math.mulDiv(amountIn, rate.numerator, rate.denominator);
        if (rate.slippageInWad > 0) {
            amountOut = Math.mulDiv(amountOut, WAD - rate.slippageInWad, WAD);
        }
        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IMintableERC20(tokenOut).mint(msg.sender, amountOut);
        IMintableERC20(tokenIn).burn(address(this), amountIn);
    }

    function swapExactAmountOut(address tokenIn, address tokenOut, uint256 maxAmountIn, uint256 amountOut)
        external
        override
        returns (uint256 amountIn)
    {
        Rate memory rate = _getRate(tokenIn, tokenOut);
        amountIn = _mulDivRoundingUp(amountOut, rate.denominator, rate.numerator);
        if (rate.slippageInWad > 0) {
            amountIn = _mulDivRoundingUp(amountIn, WAD, WAD - rate.slippageInWad);
        }
        if (amountIn > maxAmountIn) revert ExcessiveInput(amountIn, maxAmountIn);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IMintableERC20(tokenOut).mint(msg.sender, amountOut);
        IMintableERC20(tokenIn).burn(address(this), amountIn);
    }

    function setRate(address tokenIn, address tokenOut, uint256 numerator, uint256 denominator) external {
        if (msg.sender != admin) revert Unauthorized();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (numerator == 0 || denominator == 0) revert InvalidRate();
        bytes32 key = _pairKey(tokenIn, tokenOut);
        Rate storage rate = rates[key];
        rate.numerator = numerator;
        rate.denominator = denominator;
        emit RateUpdated(tokenIn, tokenOut, numerator, denominator);
    }

    function setSlippage(address tokenIn, address tokenOut, uint256 slippageInWad) external {
        if (msg.sender != admin) revert Unauthorized();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (slippageInWad >= WAD) revert InvalidSlippage();
        bytes32 key = _pairKey(tokenIn, tokenOut);
        Rate storage rate = rates[key];
        if (rate.numerator == 0 || rate.denominator == 0) {
            rate.numerator = 1;
            rate.denominator = 1;
        }
        rate.slippageInWad = slippageInWad;
        emit SlippageUpdated(tokenIn, tokenOut, slippageInWad);
    }

    function getRate(address tokenIn, address tokenOut) external view returns (Rate memory) {
        return _getRate(tokenIn, tokenOut);
    }

    function _pairKey(address tokenIn, address tokenOut) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    function _getRate(address tokenIn, address tokenOut) private view returns (Rate memory rate) {
        rate = rates[_pairKey(tokenIn, tokenOut)];
        if (rate.numerator == 0 || rate.denominator == 0) {
            rate = Rate({numerator: 1, denominator: 1, slippageInWad: 0});
        }
    }

    function _mulDivRoundingUp(uint256 x, uint256 y, uint256 denominator) private pure returns (uint256 result) {
        result = Math.mulDiv(x, y, denominator);
        if (Math.mulDiv(result, denominator, y) < x) {
            result += 1;
        }
    }
}

