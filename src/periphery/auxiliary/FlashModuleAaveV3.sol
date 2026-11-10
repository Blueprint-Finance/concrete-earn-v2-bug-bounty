// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IFlashLoanSimpleReceiver} from "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {IFlashModule} from "../interface/IFlashModule.sol";
import {ILoopingPrimitive} from "../interface/ILoopingPrimitive.sol";
import {LoopModality} from "../lib/Looping/LoopModalityLib.sol";

import {WAD, BASIS_POINTS_MAX} from "../lib/Constants.sol";

contract FlashModuleAaveV3 is IFlashModule, IFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    error PoolAddressesProviderCannotBeZeroAddress();
    error PoolNotSet();
    error PoolDataProviderNotSet();
    error InvalidCaller(address caller, address expected);
    error InvalidInitiator(address initiator, address expected);

    IPoolAddressesProvider private immutable _ADDRESSES_PROVIDER;
    IPool private immutable _POOL;
    IPoolDataProvider private immutable _POOL_DATA_PROVIDER;

    constructor(address addressesProvider_) {
        if (addressesProvider_ == address(0)) revert PoolAddressesProviderCannotBeZeroAddress();
        _ADDRESSES_PROVIDER = IPoolAddressesProvider(addressesProvider_);

        address poolAddress = _ADDRESSES_PROVIDER.getPool();
        if (poolAddress == address(0)) revert PoolNotSet();
        _POOL = IPool(poolAddress);

        address poolDataProviderAddress = _ADDRESSES_PROVIDER.getPoolDataProvider();
        if (poolDataProviderAddress == address(0)) revert PoolDataProviderNotSet();
        _POOL_DATA_PROVIDER = IPoolDataProvider(poolDataProviderAddress);
    }

    function flash(address token, uint256 amount, LoopModality loopModality, bytes memory data)
        external
        override(IFlashModule)
        returns (bool)
    {
        bytes memory params = abi.encode(msg.sender, loopModality, data);
        _POOL.flashLoanSimple(address(this), token, amount, params, 0);
        return true;
    }

    function executeOperation(
        address token,
        uint256 amountInToken,
        uint256 premiumInToken,
        address initiator,
        bytes calldata params
    ) external override(IFlashLoanSimpleReceiver) returns (bool) {
        if (msg.sender != address(_POOL)) revert InvalidCaller(msg.sender, address(_POOL));
        if (initiator != address(this)) revert InvalidInitiator(initiator, address(this));

        (address requester, LoopModality loopModality, bytes memory data) =
            abi.decode(params, (address, LoopModality, bytes));

        IERC20 tokenContract = IERC20(token);
        tokenContract.safeTransfer(requester, amountInToken);

        ILoopingPrimitive(requester).executeFlash(token, amountInToken, premiumInToken, requester, loopModality, data);

        tokenContract.safeTransferFrom(requester, address(this), amountInToken + premiumInToken);
        tokenContract.forceApprove(address(_POOL), amountInToken + premiumInToken);

        return true;
    }

    function depthOfFlashLiquidityExact(address token) public view override(IFlashModule) returns (uint256) {
        return _depthOfLiquidityInPool(token);
    }

    function flashPremiumMaxInWad(
        address /*token*/
    )
        public
        view
        override(IFlashModule)
        returns (uint64 premiumInWad, bool premiumDependsOnLiquidity)
    {
        premiumInWad = uint64(_flashLoanPremiumInWad());
        premiumDependsOnLiquidity = false;
    }

    function flashPremiumQuoteInWad(
        address,
        /* token */
        uint256 /* requiredFlashLiquidity */
    )
        public
        view
        override(IFlashModule)
        returns (uint64 premiumInWad)
    {
        premiumInWad = uint64(_flashLoanPremiumInWad());
    }

    function ADDRESSES_PROVIDER() external view override returns (IPoolAddressesProvider) {
        return _ADDRESSES_PROVIDER;
    }

    function POOL() external view override returns (IPool) {
        return _POOL;
    }

    /**
     * @dev Converts the flash loan premium from basis points to wad
     * @dev Consult https://aave.com/docs/developers/smart-contracts/pool-configurator
     */
    function _flashLoanPremiumInWad() internal view returns (uint256) {
        return Math.mulDiv(uint256(_POOL.FLASHLOAN_PREMIUM_TOTAL()), WAD, BASIS_POINTS_MAX);
    }

    function _depthOfLiquidityInPool(address token) internal view returns (uint256) {
        if (!_POOL_DATA_PROVIDER.getFlashLoanEnabled(token)) return 0;
        DataTypes.ReserveData memory reserveData = _POOL.getReserveData(token);
        address aTokenAddress = reserveData.aTokenAddress;
        if (aTokenAddress == address(0)) return 0;
        return IERC20(token).balanceOf(aTokenAddress);
    }
}
