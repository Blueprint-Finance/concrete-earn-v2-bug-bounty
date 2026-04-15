// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SwapModuleUniV3} from "../../../src/periphery/auxiliary/SwapModuleUniV3.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {console2 as console} from "forge-std/console2.sol";

interface IQuoter {
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);

    function quoteExactOutput(bytes memory path, uint256 amountOut) external returns (uint256 amountIn);
}

contract UniV3SimplePairSwapperMainnetForkTest is Test {
    using SafeERC20 for IERC20;
    // ======== Mainnet tokens ========
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // ======== Uniswap v3 contracts on mainnet ========
    ISwapRouter constant ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IQuoter constant QUOTER = IQuoter(0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6);

    // Fee tiers
    uint24 constant FEE_WETH_USDC = 500; // 0.05%
    uint24 constant FEE_USDC_USDT = 100; // 0.01%

    SwapModuleUniV3 public swapper;

    function setUp() public {
        // Fork Ethereum mainnet — get MAINNET_RPC_URL from environment variables
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, 23800000);
        vm.selectFork(forkId);

        swapper = new SwapModuleUniV3(
            ROUTER,
            WETH, // COLLATERAL
            USDT, // BORROW
            USDC, // INTERMEDIARY
            FEE_WETH_USDC, // FEE_1: WETH <-> USDC
            FEE_USDC_USDT // FEE_2: USDT <-> USDC
        );

        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(address(swapper), "UniV3SimplePairSwapper");
        vm.label(address(ROUTER), "UniswapV3Router");
        vm.label(address(QUOTER), "UniswapV3Quoter");
    }

    // helper to mint tokens to this contract (forge-std cheatcode)
    function _fund(address token, uint256 amount) internal {
        deal(token, address(this), amount);
    }

    function test_WETH_USDT_via_USDC() public {
        uint256 wethIn = 1 ether; // 1 WETH

        // --- prepare WETH balance & approvals ---
        _fund(WETH, wethIn);
        IERC20(WETH).approve(address(swapper), type(uint256).max);

        // ================================
        // 1) exactInput: WETH -> USDT
        // ================================

        // path for Quoter: WETH -(0.05%)-> USDC -(0.01%)-> USDT
        bytes memory pathIn = abi.encodePacked(WETH, FEE_WETH_USDC, USDC, FEE_USDC_USDT, USDT);

        uint256 quotedUsdtOut = QUOTER.quoteExactInput(pathIn, wethIn);
        // Allow 1% slippage on the quote
        uint256 minUsdtOut = (quotedUsdtOut * 99) / 100;

        uint256 usdtBefore = IERC20(USDT).balanceOf(address(this));

        uint256 actualUsdtOut = swapper.swapExactAmountIn(WETH, USDT, wethIn, minUsdtOut);

        uint256 usdtAfter = IERC20(USDT).balanceOf(address(this));

        assertGt(actualUsdtOut, 0, "no USDT out");
        assertEq(usdtAfter - usdtBefore, actualUsdtOut, "USDT balance mismatch");
        assertGe(actualUsdtOut, minUsdtOut, "slipped below minUsdtOut");
    }

    /// @notice E2E fork test:
    /// - swapExactAmountOut: USDT -> WETH via USDC
    function test_USDT_WETH_via_USDC() public {
        uint256 usdtMintAmount = 10_000 * 1e6; // 10,000 USDT
        uint256 targetWethOut = 1 ether; // 1 WETH
        // --- prepare WETH balance & approvals ---
        _fund(USDT, usdtMintAmount);
        console.log("USDT balance");
        console.log(IERC20(USDT).balanceOf(address(this)));
        IERC20(USDT).forceApprove(address(swapper), type(uint256).max);
        console.log("USDT approved");
        console.log(IERC20(USDT).allowance(address(this), address(swapper)));

        // ================================
        // 2) exactOutput: USDT -> WETH
        // ================================

        bytes memory pathOutReverse = abi.encodePacked(
            WETH,
            FEE_WETH_USDC, // 500
            USDC,
            FEE_USDC_USDT, // 100
            USDT
        );

        console.log("pathOutReverse");
        console.logBytes(pathOutReverse);
        uint256 quotedUsdtIn = QUOTER.quoteExactOutput(pathOutReverse, targetWethOut);
        console.log("quotedUsdtIn");
        console.log(quotedUsdtIn);
        // uint256 maxUsdtIn = (quotedUsdtIn * 101) / 100; // allow 1% slippage
        // console.log("maxUsdtIn");
        // console.log(maxUsdtIn);
        // // Approve USDT to swapper
        // console.log("maxUsdtIn approved");
    }

    /// @notice E2E fork test:
    /// - swapExactAmountOut: USDT -> WETH via USDC
    function test_USDT_WETH_via_USDC_beta() public {
        uint256 usdtMintAmount = 10_000 * 1e6; // 10,000 USDT
        uint256 targetWethOut = 1 ether; // 1 WETH
        // --- prepare WETH balance & approvals ---
        _fund(USDT, usdtMintAmount);
        IERC20(USDT).forceApprove(address(swapper), type(uint256).max);

        // ================================
        // 2) exactOutput: USDT -> WETH
        // ================================

        // Small trick: we can quote USDT->WETH by building USDT->USDC->WETH path instead,
        // but it's equivalent if we just directly encode the correct path.
        // Let's explicitly build USDT -> USDC -> WETH reverse path:
        bytes memory pathOutReverse = abi.encodePacked(
            WETH,
            FEE_WETH_USDC, // 500
            USDC,
            FEE_USDC_USDT, // 100
            USDT
        );
        uint256 quotedUsdtIn = QUOTER.quoteExactOutput(pathOutReverse, targetWethOut);
        uint256 maxUsdtIn = (quotedUsdtIn * 101) / 100; // allow 1% slippage

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdtBeforeBack = IERC20(USDT).balanceOf(address(this));

        uint256 actualUsdtIn = swapper.swapExactAmountOut(USDT, WETH, maxUsdtIn, targetWethOut);
        uint256 wethAfter = IERC20(WETH).balanceOf(address(this));
        uint256 usdtAfterBack = IERC20(USDT).balanceOf(address(this));

        assertEq(wethAfter - wethBefore, targetWethOut, "WETH out != targetWethOut");
        assertEq(usdtBeforeBack - usdtAfterBack, actualUsdtIn, "USDT in mismatch");
        assertLe(actualUsdtIn, maxUsdtIn, "needed more USDT than maxUsdtIn (too much slippage)");
    }
}
