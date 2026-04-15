// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {SwapModuleUniV4AndVaultDeposit} from "../../../src/periphery/auxiliary/SwapModuleUniV4AndVaultDeposit.sol";

// ============ Interfaces (matching contract) ============

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IHooks {
    // Empty interface

    }

/// @dev Uniswap V4 StateView interface for checking pool state
interface IStateView {
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// @dev Maple Finance PoolPermissionManager interface
interface IPoolPermissionManager {
    function setLenderAllowlist(address poolManager_, address[] calldata lenders_, bool[] calldata booleans_) external;
    function admin() external view returns (address);
}

// ============ Test Contract ============

contract SwapModuleUniV4AndVaultDepositE2EForkTest is Test {
    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SYRUP_USDC = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    // Uniswap V4 addresses (from user's findings)
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_DESCRIPTOR = 0xd1428Ba554F4C8450b763a0B2040A4935c63f06C;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af; // V4 UniversalRouter
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Mainnet Permit2

    bytes32 constant POOL_ID = 0xcdb422a853a4fa2deb364317db92ad76d1cb7a8e1b82a32219bcb41720a90228;
    uint24 constant FEE = 800;
    int24 constant TICK_SPACING = 5;
    address constant HOOKS = 0x0000000000000000000000000000000000000000;
    address constant SYRUP_USDC_WHALE = 0x33CD35738C06e946dF81aCb3CedAC6DC53cb4f37; // Binance hot wallet
    address constant USDC_WHALE = 0xa82c0BCD611af519BCeC3FAdEc96186099df42Df;

    // Maple Finance addresses
    address constant MAPLE_POOL_MANAGER = 0x7aD5fFa5fdF509E30186F4609c2f6269f4B6158F;
    address constant MAPLE_POOL_PERMISSION_MANAGER = 0xBe10aDcE8B6E3E02Db384E7FaDA5395DD113D8b3; // PROXY address (not implementation!)
    address constant MAPLE_POOL_PERMISSION_MANAGER_IMPL = 0xC3530358e54bC81EfCe4A2e12A898E996B091753; // Implementation address
    address constant MAPLE_POOL_PERMISSION_MANAGER_ADMIN = 0xd6d4Bcde6c816F17889f1Dd3000aF0261B03a196; // Gnosis Safe (admin of proxy)
    address constant MAPLE_GLOBALS = 0x804a6F5F667170F545Bf14e5DDB48C70B788390C;
    address constant MAPLE_OPERATIONAL_ADMIN = 0xCe1cE7c7F436DCc4E28Bc8bf86115514d3DC34E8;
    address constant MAPLE_GOVERNOR = 0x2eFFf88747EB5a3FF00d4d8d0f0800E306C0426b;

    // Test user
    address user = makeAddr("user");

    SwapModuleUniV4AndVaultDeposit swapModule;
    IERC20 usdc;
    IERC4626 syrupUsdc;

    uint256 constant INITIAL_USDC_AMOUNT = 100_000_000_000; // 100k USDC (6 decimals)
    uint256 constant SWAP_AMOUNT = 10_000_000_000; // 10k USDC (6 decimals)

    function setUp() public {
        // Fork mainnet at a recent block
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, 24349516);
        vm.selectFork(forkId);

        // Initialize interfaces
        usdc = IERC20(USDC);
        syrupUsdc = IERC4626(SYRUP_USDC);

        // Label addresses for better trace output
        vm.label(USDC, "USDC");
        vm.label(SYRUP_USDC, "syrupUSDC");
        vm.label(UNIVERSAL_ROUTER, "UniversalRouter");
        vm.label(PERMIT2, "Permit2");
        vm.label(user, "user");
        vm.label(USDC_WHALE, "USDC_WHALE");
        vm.label(SYRUP_USDC_WHALE, "SYRUP_USDC_WHALE");
        vm.label(STATE_VIEW, "StateView");

        console2.log("Pool configuration:");
        console2.log("  Currency0 (COLLATERAL):", SYRUP_USDC);
        console2.log("  Currency1 (BORROW):", USDC);
        console2.log("  Fee:", FEE);
        console2.log("  Tick Spacing:", uint256(int256(TICK_SPACING)));
        console2.log("  Hooks:", HOOKS);
        console2.logBytes32(POOL_ID);

        // Deploy the swap module
        swapModule = new SwapModuleUniV4AndVaultDeposit(
            UNIVERSAL_ROUTER,
            PERMIT2,
            SYRUP_USDC, // collateralToken (currency0)
            USDC, // borrowToken (currency1)
            FEE,
            TICK_SPACING,
            HOOKS
        );
        vm.label(address(swapModule), "SwapModuleUniV4AndVaultDeposit");
        console2.log("SwapModule deployed at:", address(swapModule));
        console2.log("Computed Pool ID:");
        console2.logBytes32(swapModule.POOL_ID());

        // Verify the computed pool ID matches expected
        require(swapModule.POOL_ID() == POOL_ID, "Pool ID mismatch");

        // Check pool liquidity using StateView contract
        IStateView stateView = IStateView(STATE_VIEW);
        try stateView.getLiquidity(POOL_ID) returns (uint128 liquidity) {
            console2.log("Pool liquidity:", liquidity);
            require(liquidity > 0, "Pool has no liquidity");
        } catch {
            console2.log("Warning: Could not check pool liquidity");
        }

        try stateView.getSlot0(POOL_ID) returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
            console2.log("Pool sqrtPriceX96:", sqrtPriceX96);
            console2.log("Pool tick:", uint256(int256(tick)));
            console2.log("Pool protocolFee:", protocolFee);
            console2.log("Pool lpFee:", lpFee);
        } catch {
            console2.log("Warning: Could not check pool slot0");
        }

        // Whitelist the swap module in Maple's permission system
        _whitelistSwapModuleInMaple();

        // Fund user with USDC from a whale
        vm.startPrank(USDC_WHALE);
        usdc.transfer(user, INITIAL_USDC_AMOUNT);
        vm.stopPrank();

        // Approve swap module for user
        vm.prank(user);
        usdc.approve(address(swapModule), type(uint256).max);
        vm.prank(user);
        IERC20(SYRUP_USDC).approve(address(swapModule), type(uint256).max);

        console2.log("FINISHED SETUP");
    }

    function _whitelistSwapModuleInMaple() internal {
        // Maple Finance checks permissions for the receiver (user), not the swap module
        // We need to whitelist the user address

        IPoolPermissionManager ppm = IPoolPermissionManager(MAPLE_POOL_PERMISSION_MANAGER);

        // Try to whitelist via admin
        address adminAddr;
        try ppm.admin() returns (address _admin) {
            adminAddr = _admin;
        } catch {
            // If admin() fails, try direct storage manipulation
            adminAddr = address(0);
        }

        if (adminAddr != address(0)) {
            // Try pranking the admin to whitelist
            address[] memory lenders = new address[](1);
            lenders[0] = user;
            bool[] memory booleans = new bool[](1);
            booleans[0] = true;

            vm.prank(adminAddr);
            try ppm.setLenderAllowlist(MAPLE_POOL_MANAGER, lenders, booleans) {
                console2.log("Successfully whitelisted user via Permission Manager admin()");
                return;
            } catch {
                // Fall through to storage manipulation
            }
        }

        // Last resort: Direct storage manipulation
        // Storage slot for lenderAllowlist[poolManager_][lender_]
        // Slot = keccak256(abi.encode(lender_, keccak256(abi.encode(poolManager_, slot_index))))
        // slot_index for lenderAllowlist mapping is typically 2 (check contract)
        uint256 slot = uint256(keccak256(abi.encode(user, keccak256(abi.encode(MAPLE_POOL_MANAGER, uint256(2))))));
        vm.store(MAPLE_POOL_PERMISSION_MANAGER, bytes32(slot), bytes32(uint256(1))); // Set to true
        console2.log("Whitelisted user via direct storage manipulation");
    }

    /**
     * @notice Test 1: USDC -> syrupUSDC via swapExactAmountIn (direct, uses deposit)
     */
    function test_SwapExactAmountIn_USDCtoSyrupUSDC_Direct() public {
        console2.log("=== Direct USDC -> SyrupUSDC Swap Test (uses deposit) ===");

        // Get USDC from whale
        uint256 usdcAmount = SWAP_AMOUNT;
        vm.startPrank(USDC_WHALE);
        usdc.transfer(user, usdcAmount);
        vm.stopPrank();

        uint256 userUsdcBefore = usdc.balanceOf(user);
        uint256 userSyrupBefore = syrupUsdc.balanceOf(user);
        uint256 expectedShares = syrupUsdc.previewDeposit(usdcAmount);

        vm.prank(user);
        uint256 amountOut = swapModule.swapExactAmountIn(USDC, SYRUP_USDC, usdcAmount, 0);

        uint256 userUsdcAfter = usdc.balanceOf(user);
        uint256 userSyrupAfter = syrupUsdc.balanceOf(user);

        assertEq(userUsdcBefore - userUsdcAfter, usdcAmount, "USDC spent");
        assertEq(userSyrupAfter - userSyrupBefore, amountOut, "SyrupUSDC received");
        assertApproxEqRel(amountOut, expectedShares, 0.001e18, "Shares match preview");
        assertEq(usdc.balanceOf(address(swapModule)), 0, "Contract holds 0 USDC");
        assertEq(syrupUsdc.balanceOf(address(swapModule)), 0, "Contract holds 0 syrupUSDC");
    }

    /**
     * @notice Test 2: USDC -> syrupUSDC via swapExactAmountOut (direct, uses mint)
     */
    function test_SwapExactAmountOut_USDCtoSyrupUSDC_Direct() public {
        console2.log("=== Direct USDC -> SyrupUSDC Swap Test (uses mint) ===");

        uint256 targetShares = SWAP_AMOUNT;
        uint256 maxUsdcAmount = SWAP_AMOUNT * 2;

        vm.startPrank(USDC_WHALE);
        usdc.transfer(user, maxUsdcAmount);
        vm.stopPrank();

        uint256 userUsdcBefore = usdc.balanceOf(user);
        uint256 userSyrupBefore = syrupUsdc.balanceOf(user);

        vm.prank(user);
        uint256 amountIn = swapModule.swapExactAmountOut(USDC, SYRUP_USDC, maxUsdcAmount, targetShares);

        uint256 userUsdcAfter = usdc.balanceOf(user);
        uint256 userSyrupAfter = syrupUsdc.balanceOf(user);

        assertEq(userSyrupAfter - userSyrupBefore, targetShares, "Exact shares received");
        assertEq(userUsdcBefore - userUsdcAfter, amountIn, "USDC spent");
        assertLe(amountIn, maxUsdcAmount, "Within max amount");
        assertEq(usdc.balanceOf(address(swapModule)), 0, "Contract holds 0 USDC");
        assertEq(syrupUsdc.balanceOf(address(swapModule)), 0, "Contract holds 0 syrupUSDC");
    }

    /**
     * @notice Test 3: syrupUSDC -> USDC via swapExactAmountIn (direct)
     */
    function test_SwapExactAmountIn_SyrupUSDCToUSDC_Direct() public {
        console2.log("=== Direct SyrupUSDC -> USDC Swap Test ===");

        uint256 syrupAmount = SWAP_AMOUNT;
        vm.startPrank(SYRUP_USDC_WHALE);
        syrupUsdc.transfer(user, syrupAmount);
        vm.stopPrank();

        uint256 userSyrupBefore = syrupUsdc.balanceOf(user);
        uint256 userUsdcBefore = usdc.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = swapModule.swapExactAmountIn(SYRUP_USDC, USDC, syrupAmount, 0);

        uint256 userSyrupAfter = syrupUsdc.balanceOf(user);
        uint256 userUsdcAfter = usdc.balanceOf(user);

        assertEq(userSyrupBefore - userSyrupAfter, syrupAmount, "SyrupUSDC spent");
        assertEq(userUsdcAfter - userUsdcBefore, amountOut, "USDC received");
        assertGt(amountOut, 0, "Received USDC");
        assertEq(usdc.balanceOf(address(swapModule)), 0, "Contract holds 0 USDC");
        assertEq(syrupUsdc.balanceOf(address(swapModule)), 0, "Contract holds 0 syrupUSDC");
    }

    /**
     * @notice Test 4: syrupUSDC -> USDC via swapExactAmountOut (direct, for repay loop)
     */
    function test_SwapExactAmountOut_SyrupUSDCToUSDC_Direct() public {
        console2.log("=== Direct SyrupUSDC -> USDC Swap Test (exact out, for repay loop) ===");

        uint256 targetUsdc = SWAP_AMOUNT;
        uint256 maxSyrupAmount = SWAP_AMOUNT * 2;

        vm.startPrank(SYRUP_USDC_WHALE);
        syrupUsdc.transfer(user, maxSyrupAmount);
        vm.stopPrank();

        uint256 userSyrupBefore = syrupUsdc.balanceOf(user);
        uint256 userUsdcBefore = usdc.balanceOf(user);

        vm.prank(user);
        uint256 amountIn = swapModule.swapExactAmountOut(SYRUP_USDC, USDC, maxSyrupAmount, targetUsdc);

        uint256 userSyrupAfter = syrupUsdc.balanceOf(user);
        uint256 userUsdcAfter = usdc.balanceOf(user);

        assertGe(userUsdcAfter - userUsdcBefore, targetUsdc, "At least target USDC");
        assertEq(userSyrupBefore - userSyrupAfter, amountIn, "SyrupUSDC spent");
        assertLe(amountIn, maxSyrupAmount, "Within max amount");
        assertEq(usdc.balanceOf(address(swapModule)), 0, "Contract holds 0 USDC");
        assertEq(syrupUsdc.balanceOf(address(swapModule)), 0, "Contract holds 0 syrupUSDC");
    }
}
