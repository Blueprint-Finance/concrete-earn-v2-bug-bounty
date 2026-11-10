// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IHook} from "../../src/interface/IHook.sol";

contract StandardHookMock is IHook {
    error NotImplemented();
    error DepositLimitExceeded(uint256 assets, uint256 depositLimit);
    error NotOwner();
    error TransferLimitExceeded(uint256 shares, uint256 transferLimit);

    address public immutable VAULT;
    uint256 public depositLimit;

    constructor(address _vault, uint256 _depositLimit) {
        VAULT = _vault;
        depositLimit = _depositLimit;
    }

    /// @dev Test mock has no factory binding; returns zero.
    function FACTORY() external pure returns (address) {
        return address(0);
    }

    // USER ACTION HOOKS

    function preDeposit(
        address,
        /* sender */
        uint256 assets,
        uint256,
        /* shares */
        address,
        /* receiver */
        uint256 /* totalAssets */
    )
        external
        view
    {
        if (assets > depositLimit) revert DepositLimitExceeded(assets, depositLimit);
    }

    /// @dev This mock stands in for a standard-vault hook; the multi-asset entry point is unused.
    function preMultiDeposit(
        address, /* sender */
        address, /* depositAsset */
        uint256, /* depositAssetAmount */
        uint256, /* baseAssets */
        uint256, /* shares */
        address, /* receiver */
        uint256 /* totalAssets */
    )
        external
        pure
    {
        revert NotImplemented();
    }

    function preMint(
        address,
        /* sender */
        uint256,
        /* assets */
        uint256,
        /* shares */
        address,
        /* receiver */
        uint256 /* totalAssets */
    )
        external
        pure
    {
        // call the sender
        revert NotImplemented();
    }

    function preWithdraw(
        address sender,
        uint256, /* assets */
        uint256, /* shares */
        address, /* receiver */
        address owner,
        uint256 /* totalAssets */
    )
        external
        pure
    {
        if (sender != owner) revert NotOwner();
    }

    function preRedeem(
        address sender,
        uint256, /* assets */
        uint256, /* shares */
        address, /* receiver */
        address owner,
        uint256 /* totalAssets */
    )
        external
        pure
    {
        if (sender != owner) revert NotOwner();
    }

    function postDeposit(
        address, /* sender */
        uint256, /* assets */
        uint256, /* shares */
        address, /* receiver */
        uint256 /* totalAssets */
    )
        external
        pure
    {
        // not implemented
        revert NotImplemented();
    }

    function postMint(
        address, /* sender */
        uint256 assets,
        uint256, /* shares */
        address, /* receiver */
        uint256 /* totalAssets */
    )
        external
        view
    {
        // check deposit limit
        if (assets > depositLimit) revert DepositLimitExceeded(assets, depositLimit);
    }

    function postWithdraw(
        address, /* sender */
        uint256, /* assets */
        uint256, /* shares */
        address, /* receiver */
        uint256 /* totalAssets */
    )
        external
        pure
    {
        // not implemented
        revert NotImplemented();
    }

    function postRedeem(
        address, /* sender */
        uint256, /* assets */
        uint256, /* shares */
        address, /* receiver */
        uint256 /* totalAssets */
    )
        external
        pure
    {
        // not implemented
        revert NotImplemented();
    }

    function preTransfer(
        address sender,
        address from,
        address,
        /* to */
        uint256 /* shares */
    )
        external
        pure
    {
        if (sender != from) revert NotOwner();
    }

    function postTransfer(
        address,
        /* sender */
        address,
        /* from */
        address,
        /* to */
        uint256 shares
    )
        external
        view
    {
        if (shares > depositLimit) revert TransferLimitExceeded(shares, depositLimit);
    }
}
