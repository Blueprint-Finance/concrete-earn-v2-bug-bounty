// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

type ErrorInfo is uint256;

library ErrorInfoLib {
    // ---- Layout ----
    // Bits 0-7: error flags (uint8 bitmap)
    // Bits 8-71: wadPayloadPrimary (uint64)
    // Bits 72-135: wadPayloadSecondary (uint64)
    // Bits 136-199: wadPayloadTertiary (uint64)
    // Bits 200-255: reserved

    // ---- Masks and shifts ----
    uint256 private constant ERROR_FLAGS_MASK = 0xFF;
    uint256 private constant WAD_MASK = (uint256(1) << 64) - 1;

    uint256 private constant WAD_PAYLOAD_PRIMARY_SHIFT = 8;
    uint256 private constant WAD_PAYLOAD_SECONDARY_SHIFT = 72;
    uint256 private constant WAD_PAYLOAD_TERTIARY_SHIFT = 136;
    uint256 private constant PAYLOAD_120_MASK = (uint256(1) << 120) - 1;

    // ---- Errors ----
    error ErrorIndexOutOfBounds(uint8 index);
    error WadPayloadIndexOutOfBounds(uint8 index);

    // ---- Getters ----
    function errorBitmap(ErrorInfo info_) internal pure returns (uint8) {
        return uint8(ErrorInfo.unwrap(info_) & ERROR_FLAGS_MASK);
    }

    function hasError(ErrorInfo info_) internal pure returns (bool) {
        return errorBitmap(info_) != 0;
    }

    function hasError(ErrorInfo info_, uint8 index) internal pure returns (bool) {
        if (index >= 8) revert ErrorIndexOutOfBounds(index);
        return (ErrorInfo.unwrap(info_) & (uint256(1) << index)) != 0;
    }

    function wadPayload(ErrorInfo info_, uint8 index) internal pure returns (uint64) {
        uint256 v = ErrorInfo.unwrap(info_);

        if (index == 0) return uint64((v >> WAD_PAYLOAD_PRIMARY_SHIFT) & WAD_MASK);
        if (index == 1) return uint64((v >> WAD_PAYLOAD_SECONDARY_SHIFT) & WAD_MASK);
        if (index == 2) return uint64((v >> WAD_PAYLOAD_TERTIARY_SHIFT) & WAD_MASK);

        revert WadPayloadIndexOutOfBounds(index);
    }

    // ---- Setters (field-preserving) ----
    function setErrorBitmap(ErrorInfo info_, uint8 bitmap_) internal pure returns (ErrorInfo) {
        uint256 v = ErrorInfo.unwrap(info_);
        v = (v & ~ERROR_FLAGS_MASK) | uint256(bitmap_);
        return ErrorInfo.wrap(v);
    }

    function setError(ErrorInfo info_, uint8 index, bool value_) internal pure returns (ErrorInfo) {
        if (index >= 8) revert ErrorIndexOutOfBounds(index);
        uint256 v = ErrorInfo.unwrap(info_);
        uint256 bit = uint256(1) << index;
        v = value_ ? (v | bit) : (v & ~bit);
        return ErrorInfo.wrap(v);
    }

    function setWadPayload(ErrorInfo info_, uint8 index, uint64 value_) internal pure returns (ErrorInfo) {
        uint256 v = ErrorInfo.unwrap(info_);

        if (index == 0) {
            v = (v & ~(WAD_MASK << WAD_PAYLOAD_PRIMARY_SHIFT)) | (uint256(value_) << WAD_PAYLOAD_PRIMARY_SHIFT);
            return ErrorInfo.wrap(v);
        }

        if (index == 1) {
            v = (v & ~(WAD_MASK << WAD_PAYLOAD_SECONDARY_SHIFT)) | (uint256(value_) << WAD_PAYLOAD_SECONDARY_SHIFT);
            return ErrorInfo.wrap(v);
        }

        if (index == 2) {
            v = (v & ~(PAYLOAD_120_MASK << WAD_PAYLOAD_TERTIARY_SHIFT))
                | (uint256(value_) << WAD_PAYLOAD_TERTIARY_SHIFT);
            return ErrorInfo.wrap(v);
        }

        revert WadPayloadIndexOutOfBounds(index);
    }

    // ---- Pack & Init ----
    function pack(uint8 bitmap_, uint64 wadPayloadPrimary_, uint64 wadPayloadSecondary_, uint64 wadPayloadTertiary_)
        internal
        pure
        returns (ErrorInfo)
    {
        uint256 v = uint256(bitmap_);
        v |= uint256(wadPayloadPrimary_) << WAD_PAYLOAD_PRIMARY_SHIFT;
        v |= uint256(wadPayloadSecondary_) << WAD_PAYLOAD_SECONDARY_SHIFT;
        v |= uint256(wadPayloadTertiary_) << WAD_PAYLOAD_TERTIARY_SHIFT;
        return ErrorInfo.wrap(v);
    }

    function init() internal pure returns (ErrorInfo) {
        return ErrorInfo.wrap(0);
    }
}
