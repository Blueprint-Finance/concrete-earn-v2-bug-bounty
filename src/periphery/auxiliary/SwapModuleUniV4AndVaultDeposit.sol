// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

import {ISwapModule} from "../interface/ISwapModule.sol";
import {IPermit2, IUniversalRouter, PoolKey, RouterPoolKey, Currency} from "../interface/IUniswapV4.sol";

/**
 * @title SwapModuleUniV4AndVaultDeposit
 * @notice Swap module for bidirectional swaps between an ERC4626 vault share token and its underlying asset.
 *         Uses Uniswap V4 for share token swaps and direct ERC4626 operations for deposits/mints.
 *
 * @dev Main Use Case:
 *      Designed for looping strategies where users:
 *      1. Deposit underlying assets to receive vault shares (via ERC4626 deposit/mint)
 *      2. Swap shares back to underlying assets (via Uniswap V4)
 *      3. Repeat to compound returns
 *
 * @dev Architecture:
 *      - Underlying -> Shares: Uses ERC4626 deposit() or mint() directly
 *      - Shares -> Underlying: Uses Uniswap V4 swap via UniversalRouter with Permit2
 *      - Maintains zero token balance after each operation (invariant)
 */
contract SwapModuleUniV4AndVaultDeposit is ISwapModule {
    using SafeERC20 for IERC20;

    // ------- constants -------
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 6;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 8;
    uint8 internal constant SETTLE_ALL = 12;
    uint8 internal constant TAKE_ALL = 15;

    uint160 internal constant MAX_UINT160 = type(uint160).max;
    uint48 internal constant MAX_UINT48 = type(uint48).max;
    uint256 internal constant MAX_UINT256 = type(uint256).max;

    // ------- immutables -------
    IUniversalRouter public immutable ROUTER;
    IPermit2 public immutable PERMIT2;

    address public immutable COLLATERAL; // ERC4626 vault share token (currency0)
    address public immutable BORROW; // Underlying asset (currency1)
    uint24 public immutable FEE;
    int24 public immutable TICK_SPACING;
    address public immutable HOOKS;

    bytes32 public immutable POOL_ID;

    // ------- errors -------
    error ZeroAmount();
    error InvalidTokenIn();
    error InvalidTokenOut();
    error MinAmountOutTooLow(uint256 received, uint256 minimum);
    error MaxAmountInTooLow(uint256 required, uint256 maximum);
    error RouterCannotBeZero();
    error Permit2CannotBeZero();
    error CollateralTokenCannotBeZero();
    error BorrowTokenCannotBeZero();
    error CollateralAndBorrowTokensCannotBeEqual();
    error FeeCannotBeZero();
    error InvalidTickSpacing();

    /**
     * @notice Constructs a new SwapModuleUniV4AndVaultDeposit
     * @param _router Uniswap V4 UniversalRouter address
     * @param _permit2 Permit2 contract address
     * @param _collateralToken ERC4626 vault share token (currency0)
     * @param _borrowToken Underlying asset (currency1)
     * @param _fee Uniswap V4 pool fee
     * @param _tickSpacing Uniswap V4 pool tick spacing
     * @param _hooks Uniswap V4 hooks address (address(0) for no hooks)
     */
    constructor(
        address _router,
        address _permit2,
        address _collateralToken,
        address _borrowToken,
        uint24 _fee,
        int24 _tickSpacing,
        address _hooks
    ) {
        if (_router == address(0)) revert RouterCannotBeZero();
        if (_permit2 == address(0)) revert Permit2CannotBeZero();
        if (_collateralToken == address(0)) revert CollateralTokenCannotBeZero();
        if (_borrowToken == address(0)) revert BorrowTokenCannotBeZero();
        if (_collateralToken == _borrowToken) revert CollateralAndBorrowTokensCannotBeEqual();
        if (_fee == 0) revert FeeCannotBeZero();
        if (_tickSpacing == 0) revert InvalidTickSpacing();

        ROUTER = IUniversalRouter(_router);
        PERMIT2 = IPermit2(_permit2);

        COLLATERAL = _collateralToken;
        BORROW = _borrowToken;
        FEE = _fee;
        TICK_SPACING = _tickSpacing;
        HOOKS = _hooks;

        // Compute pool ID from constructor parameters
        POOL_ID = toPoolId(POOL_KEY());

        // Approvals:
        // - Underlying asset must be approved to the vault for deposit/mint
        IERC20(BORROW).forceApprove(COLLATERAL, MAX_UINT256);

        // - Permit2 needs allowance from this contract for both tokens
        //   UniversalRouter uses Permit2 to pull tokens via SETTLE_ALL action
        IERC20(COLLATERAL).forceApprove(_permit2, MAX_UINT256);
        IERC20(BORROW).forceApprove(_permit2, MAX_UINT256);

        // - Permit2 approvals to the UniversalRouter
        //   (max uint160 amount, max uint48 expiration)
        IPermit2(_permit2).approve(COLLATERAL, _router, MAX_UINT160, MAX_UINT48);
        IPermit2(_permit2).approve(BORROW, _router, MAX_UINT160, MAX_UINT48);
    }

    /**
     * @notice Swaps an exact amount of input tokens for output tokens
     * @param tokenIn Input token (must be COLLATERAL or BORROW)
     * @param tokenOut Output token (must be the other token)
     * @param amountIn Exact amount of input tokens
     * @param minAmountOut Minimum output tokens (slippage protection)
     * @return amountOut Amount of output tokens received
     */
    function swapExactAmountIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();

        if (tokenIn == BORROW) {
            // Underlying -> Shares via ERC4626 deposit
            if (tokenOut != COLLATERAL) revert InvalidTokenOut();

            IERC20(BORROW).safeTransferFrom(msg.sender, address(this), amountIn);
            amountOut = IERC4626(COLLATERAL).deposit(amountIn, msg.sender);
            if (amountOut < minAmountOut) revert MinAmountOutTooLow(amountOut, minAmountOut);
            return amountOut;
        }

        if (tokenIn == COLLATERAL) {
            // Shares -> Underlying via Uniswap V4
            if (tokenOut != BORROW) revert InvalidTokenOut();

            // Record BORROW balance before to exclude any donations
            uint256 borrowBalanceBefore = IERC20(BORROW).balanceOf(address(this));

            IERC20(COLLATERAL).safeTransferFrom(msg.sender, address(this), amountIn);
            _v4SwapExactIn(COLLATERAL, BORROW, amountIn, minAmountOut);

            // Calculate output excluding any pre-existing BORROW balance (donations)
            amountOut = IERC20(BORROW).balanceOf(address(this)) - borrowBalanceBefore;
            IERC20(BORROW).safeTransfer(msg.sender, amountOut);

            // Refund any remaining collateral (should be zero, but handle donations gracefully)
            uint256 collateralRemaining = IERC20(COLLATERAL).balanceOf(address(this));
            if (collateralRemaining > 0) {
                IERC20(COLLATERAL).safeTransfer(msg.sender, collateralRemaining);
            }

            return amountOut;
        }

        revert InvalidTokenIn();
    }

    /**
     * @notice Swaps for an exact amount of output tokens, using up to maxAmountIn input tokens
     * @param tokenIn Input token (must be COLLATERAL or BORROW)
     * @param tokenOut Output token (must be the other token)
     * @param maxAmountIn Maximum input tokens to spend
     * @param amountOut Exact output tokens to receive
     * @return amountIn Input tokens actually used
     */
    function swapExactAmountOut(address tokenIn, address tokenOut, uint256 maxAmountIn, uint256 amountOut)
        external
        override
        returns (uint256 amountIn)
    {
        if (maxAmountIn == 0 || amountOut == 0) revert ZeroAmount();

        if (tokenIn == BORROW) {
            // Underlying -> Shares exact out via ERC4626 mint
            if (tokenOut != COLLATERAL) revert InvalidTokenOut();

            IERC20(BORROW).safeTransferFrom(msg.sender, address(this), maxAmountIn);
            uint256 assetsReq = IERC4626(COLLATERAL).previewMint(amountOut);
            if (assetsReq > maxAmountIn) revert MaxAmountInTooLow(assetsReq, maxAmountIn);

            amountIn = IERC4626(COLLATERAL).mint(amountOut, msg.sender);

            // Refund unused input
            if (amountIn < maxAmountIn) {
                IERC20(BORROW).safeTransfer(msg.sender, maxAmountIn - amountIn);
            }
            return amountIn;
        }

        if (tokenIn == COLLATERAL) {
            // Shares -> Underlying exact out via Uniswap V4
            if (tokenOut != BORROW) revert InvalidTokenOut();

            // Record BORROW balance before to exclude any donations
            uint256 borrowBalanceBefore = IERC20(BORROW).balanceOf(address(this));

            IERC20(COLLATERAL).safeTransferFrom(msg.sender, address(this), maxAmountIn);
            _v4SwapExactOut(COLLATERAL, BORROW, maxAmountIn, amountOut);

            // Calculate output excluding any pre-existing BORROW balance (donations)
            uint256 received = IERC20(BORROW).balanceOf(address(this)) - borrowBalanceBefore;
            IERC20(BORROW).safeTransfer(msg.sender, received);

            // Refund any unused input (invariant: contract holds no tokens)
            uint256 collateralRemaining = IERC20(COLLATERAL).balanceOf(address(this));
            uint256 refundAmount = 0;
            if (collateralRemaining > 0) {
                // Cap refund at maxAmountIn to prevent sending donated tokens to wrong recipient
                refundAmount = collateralRemaining > maxAmountIn ? maxAmountIn : collateralRemaining;
                IERC20(COLLATERAL).safeTransfer(msg.sender, refundAmount);
            }

            // Calculate actual amount used: maxAmountIn minus what we're refunding
            amountIn = maxAmountIn - refundAmount;
            return amountIn;
        }

        revert InvalidTokenIn();
    }

    /**
     * @notice Constructs PoolKey from immutable storage
     * @return Pool key struct
     */
    function POOL_KEY() public view returns (PoolKey memory) {
        return PoolKey({currency0: COLLATERAL, currency1: BORROW, fee: FEE, tickSpacing: TICK_SPACING, hooks: HOOKS});
    }

    /**
     * @notice Computes pool ID from PoolKey
     * @param key Pool key struct
     * @return Computed pool ID
     */
    function toPoolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
    }

    /**
     * @notice Determines swap direction (zeroForOne)
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @return true if currency0 -> currency1, false otherwise
     */
    function _zeroForOne(address tokenIn, address tokenOut) internal view returns (bool) {
        PoolKey memory key = POOL_KEY();
        address c0 = key.currency0;
        address c1 = key.currency1;

        if (tokenIn == c0 && tokenOut == c1) return true; // currency0 -> currency1
        if (tokenIn == c1 && tokenOut == c0) return false; // currency1 -> currency0
        revert InvalidTokenOut();
    }

    /**
     * @notice Executes Uniswap V4 exact-input swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Exact input amount
     * @param minOut Minimum output amount
     */
    function _v4SwapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal {
        bool zeroForOne = _zeroForOne(tokenIn, tokenOut);
        PoolKey memory key = POOL_KEY();

        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IUniversalRouter.ExactInputSingleParams({
                poolKey: RouterPoolKey({
                    currency0: Currency.wrap(key.currency0),
                    currency1: Currency.wrap(key.currency1),
                    fee: key.fee,
                    tickSpacing: key.tickSpacing,
                    hooks: key.hooks
                }),
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                hookData: bytes("")
            })
        );

        // SETTLE_ALL(currencyIn, amountIn) - UniversalRouter uses Permit2 to pull tokens
        params[1] = abi.encode(Currency.wrap(tokenIn), amountIn);

        // TAKE_ALL(currencyOut, minOut)
        params[2] = abi.encode(Currency.wrap(tokenOut), minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        ROUTER.execute(commands, inputs, block.timestamp + 30);
    }

    /**
     * @notice Executes Uniswap V4 exact-output swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param maxIn Maximum input amount
     * @param amountOut Exact output amount
     */
    function _v4SwapExactOut(address tokenIn, address tokenOut, uint256 maxIn, uint256 amountOut) internal {
        bool zeroForOne = _zeroForOne(tokenIn, tokenOut);
        PoolKey memory key = POOL_KEY();

        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes memory actions = abi.encodePacked(SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IUniversalRouter.ExactOutputSingleParams({
                poolKey: RouterPoolKey({
                    currency0: Currency.wrap(key.currency0),
                    currency1: Currency.wrap(key.currency1),
                    fee: key.fee,
                    tickSpacing: key.tickSpacing,
                    hooks: key.hooks
                }),
                zeroForOne: zeroForOne,
                amountOut: uint128(amountOut),
                amountInMaximum: uint128(maxIn),
                hookData: bytes("")
            })
        );

        // SETTLE_ALL(currencyIn, maxIn) - UniversalRouter uses Permit2 to pull tokens
        params[1] = abi.encode(Currency.wrap(tokenIn), maxIn);

        // TAKE_ALL(currencyOut, amountOut)
        params[2] = abi.encode(Currency.wrap(tokenOut), amountOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        ROUTER.execute(commands, inputs, block.timestamp + 30);
    }
}
