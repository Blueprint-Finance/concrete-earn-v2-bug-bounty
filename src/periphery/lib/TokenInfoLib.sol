// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

type TokenInfo is uint256;

library TokenInfoLib {
    // ---- Layout ----
    // Bits 0-159: address (160 bits)
    // Bits 160-167: decimals (8 bits)

    // ---- Constants ----
    uint256 private constant ADDRESS_BITS = 160;
    uint256 private constant DECIMALS_SHIFT = 160;

    uint256 private constant ADDRESS_MASK = (uint256(1) << ADDRESS_BITS) - 1; // 160-bit mask
    uint256 private constant DECIMALS_MASK = 0xFF; // 8-bit mask

    // ---- Getters ----

    function getAddress(TokenInfo info_) internal pure returns (address) {
        uint256 v = TokenInfo.unwrap(info_);
        return address(uint160(v & ADDRESS_MASK));
    }

    function getDecimals(TokenInfo info_) internal pure returns (uint8) {
        uint256 v = TokenInfo.unwrap(info_);
        return uint8((v >> DECIMALS_SHIFT) & DECIMALS_MASK);
    }

    // ---- Setters (field-preserving) ----

    function setAddress(TokenInfo info_, address token_) internal pure returns (TokenInfo) {
        uint256 v = TokenInfo.unwrap(info_);
        v = (v & ~ADDRESS_MASK) | uint160(token_);
        return TokenInfo.wrap(v);
    }

    function setDecimals(TokenInfo info_, uint8 decimals_) internal pure returns (TokenInfo) {
        uint256 v = TokenInfo.unwrap(info_);
        v = (v & ~(DECIMALS_MASK << DECIMALS_SHIFT)) | (uint256(decimals_) << DECIMALS_SHIFT);
        return TokenInfo.wrap(v);
    }

    // ---- Pack: build a TokenInfo from all fields ----

    function pack(address token_, uint8 decimals_) internal pure returns (TokenInfo) {
        uint256 v = uint160(token_) | (uint256(decimals_) << DECIMALS_SHIFT);
        return TokenInfo.wrap(v);
    }
}
