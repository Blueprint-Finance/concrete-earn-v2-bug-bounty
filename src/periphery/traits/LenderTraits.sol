// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

abstract contract LenderOpTraits {
    function _supply(address token, uint256 amount) internal virtual;
    function _withdraw(address token, uint256 amount) internal virtual;
    function _repay(address token, uint256 amount) internal virtual;
    function _borrow(address token, uint256 amount) internal virtual;
}

abstract contract SimpleLenderOpTraits {
    function _supply(uint256 amount) internal virtual;
    function _withdraw(uint256 amount) internal virtual;
    function _repay(uint256 amount) internal virtual;
    function _borrow(uint256 amount) internal virtual;
}
