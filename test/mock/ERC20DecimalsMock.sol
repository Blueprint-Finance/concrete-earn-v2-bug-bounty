// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 mock with constructor-configurable decimals, for testing decimal-aware logic.
contract ERC20DecimalsMock is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("ERC20DecimalsMock", "E20D") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
