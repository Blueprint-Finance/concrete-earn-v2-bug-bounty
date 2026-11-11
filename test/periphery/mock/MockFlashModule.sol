// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import {IFlashModule} from "../../../src/periphery/interface/IFlashModule.sol";
import {ILoopingPrimitive} from "../../../src/periphery/interface/ILoopingPrimitive.sol";
import {LoopModality} from "../../../src/periphery/lib/Looping/LoopModalityLib.sol";
import {WAD} from "../../../src/periphery/lib/Constants.sol";

import {IMintableERC20} from "./ERC20Mock.sol";

contract MockFlashModule is IFlashModule {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error Unauthorized();
    error FlashAmountExceedsLiquidity(uint256 requested, uint256 available);

    event LiquidityCapUpdated(address indexed token, uint256 cap);
    event PremiumUpdated(uint64 premiumInWad);
    event FlashExecutedByFlashModule(
        address indexed requester, address indexed token, uint256 amount, uint256 premiumAmount
    );

    address public immutable admin;

    mapping(address => uint256) public liquidityCap;
    uint64 public flashPremiumInWad;

    constructor(address admin_, uint64 flashPremiumInWad_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        flashPremiumInWad = flashPremiumInWad_;
    }

    function flash(address token, uint256 amount, LoopModality loopModality, bytes calldata data)
        external
        override
        returns (bool)
    {
        address requester = msg.sender;
        uint256 available = liquidityCap[token];
        if (amount > available) revert FlashAmountExceedsLiquidity(amount, available);

        uint256 premiumAmount = Math.mulDiv(amount, flashPremiumInWad, WAD);

        IMintableERC20(token).mint(requester, amount);

        ILoopingPrimitive(requester).executeFlash(token, amount, premiumAmount, requester, loopModality, data);

        IERC20(token).safeTransferFrom(requester, address(this), amount + premiumAmount);
        IMintableERC20(token).burn(address(this), amount + premiumAmount);

        emit FlashExecutedByFlashModule(requester, token, amount, premiumAmount);
        return true;
    }

    function depthOfFlashLiquidityExact(address token) external view override returns (uint256) {
        return liquidityCap[token];
    }

    function flashPremiumMaxInWad(address token)
        external
        view
        override
        returns (uint64 premiumInWad, bool premiumDependsOnLiquidity)
    {
        token;
        premiumInWad = flashPremiumInWad;
        premiumDependsOnLiquidity = false;
    }

    function flashPremiumQuoteInWad(address token, uint256 requiredFlashLiquidity)
        external
        view
        override
        returns (uint64 premiumInWad)
    {
        token;
        requiredFlashLiquidity;
        premiumInWad = flashPremiumInWad;
    }

    function setLiquidityCap(address token, uint256 cap) external {
        if (msg.sender != admin) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();
        liquidityCap[token] = cap;
        emit LiquidityCapUpdated(token, cap);
    }

    function setFlashPremium(uint64 premiumInWad) external {
        if (msg.sender != admin) revert Unauthorized();
        flashPremiumInWad = premiumInWad;
        emit PremiumUpdated(premiumInWad);
    }
}
