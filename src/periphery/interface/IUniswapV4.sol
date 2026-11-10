// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Currency type wrapper (needed for UniversalRouter encoding)
type Currency is address;

/// @dev PoolKey struct (using addresses directly for simplicity)
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev PoolKey for UniversalRouter (uses Currency types)
struct RouterPoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Permit2 interface
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev UniversalRouter interface with V4 swap params
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;

    struct ExactInputSingleParams {
        RouterPoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct ExactOutputSingleParams {
        RouterPoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }
}
