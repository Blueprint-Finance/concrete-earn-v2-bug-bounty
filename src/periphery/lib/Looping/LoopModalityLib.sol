// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

type LoopModality is uint256;

enum LeverageOperation {
    None,
    PlainSupply,
    PlainWithdraw,
    LoopSupplyAndAllocate,
    LoopSupplyAndDeallocate,
    LoopWithdrawAndAllocate,
    LoopWithdrawAndDeallocate
}

library LoopModalityLib {
    // ---- Layout ----
    // Bit 0: loopSupply (bool)
    // Bit 1: plainOperation (bool)
    // Bit 2: allocateFloating (bool)
    // Bit 3: maxWithdraw (bool)
    // Bits 8-71: targetLtvInWad (uint64) - starting at byte boundary
    // Bits 72-135: deviationLtvInWad (uint64)

    // ---- Bit masks and shifts ----
    uint256 private constant LOOP_SUPPLY_BIT = 1 << 0;
    uint256 private constant PLAIN_OPERATION_BIT = 1 << 1;
    uint256 private constant ALLOCATE_FLOATING_BIT = 1 << 2;
    uint256 private constant MAX_WITHDRAW_BIT = 1 << 3;

    uint256 private constant TARGET_LTV_SHIFT = 8;
    uint256 private constant DEVIATION_LTV_SHIFT = 72;
    uint256 private constant WAD_MASK = (uint256(1) << 64) - 1; // 64-bit mask

    // ---- Getters ----

    function loopSupply(LoopModality modality_) internal pure returns (bool) {
        return (LoopModality.unwrap(modality_) & LOOP_SUPPLY_BIT) != 0;
    }

    function plainOperation(LoopModality modality_) internal pure returns (bool) {
        return (LoopModality.unwrap(modality_) & PLAIN_OPERATION_BIT) != 0;
    }

    function allocateFloating(LoopModality modality_) internal pure returns (bool) {
        return (LoopModality.unwrap(modality_) & ALLOCATE_FLOATING_BIT) != 0;
    }

    function maxWithdraw(LoopModality modality_) internal pure returns (bool) {
        return (LoopModality.unwrap(modality_) & MAX_WITHDRAW_BIT) != 0;
    }

    function targetLtvInWad(LoopModality modality_) internal pure returns (uint64) {
        uint256 v = LoopModality.unwrap(modality_);
        return uint64((v >> TARGET_LTV_SHIFT) & WAD_MASK);
    }

    function deviationLtvInWad(LoopModality modality_) internal pure returns (uint64) {
        uint256 v = LoopModality.unwrap(modality_);
        return uint64((v >> DEVIATION_LTV_SHIFT) & WAD_MASK);
    }

    // ---- Setters (field-preserving) ----

    function setLoopSupply(LoopModality modality_, bool value_) internal pure returns (LoopModality) {
        uint256 v = LoopModality.unwrap(modality_);
        v = value_ ? (v | LOOP_SUPPLY_BIT) : (v & ~LOOP_SUPPLY_BIT);
        return LoopModality.wrap(v);
    }

    function setPlainOperation(LoopModality modality_, bool value_) internal pure returns (LoopModality) {
        uint256 v = LoopModality.unwrap(modality_);
        v = value_ ? (v | PLAIN_OPERATION_BIT) : (v & ~PLAIN_OPERATION_BIT);
        return LoopModality.wrap(v);
    }

    function setAllocateFloating(LoopModality modality_, bool value_) internal pure returns (LoopModality) {
        uint256 v = LoopModality.unwrap(modality_);
        v = value_ ? (v | ALLOCATE_FLOATING_BIT) : (v & ~ALLOCATE_FLOATING_BIT);
        return LoopModality.wrap(v);
    }

    function setMaxWithdraw(LoopModality modality_, bool value_) internal pure returns (LoopModality) {
        uint256 v = LoopModality.unwrap(modality_);
        v = value_ ? (v | MAX_WITHDRAW_BIT) : (v & ~MAX_WITHDRAW_BIT);
        return LoopModality.wrap(v);
    }

    function setTargetLtvInWad(LoopModality modality_, uint64 value_) internal pure returns (LoopModality) {
        uint256 v = LoopModality.unwrap(modality_);
        v = (v & ~(WAD_MASK << TARGET_LTV_SHIFT)) | (uint256(value_) << TARGET_LTV_SHIFT);
        return LoopModality.wrap(v);
    }

    function setDeviationLtvInWad(LoopModality modality_, uint64 value_) internal pure returns (LoopModality) {
        uint256 v = LoopModality.unwrap(modality_);
        v = (v & ~(WAD_MASK << DEVIATION_LTV_SHIFT)) | (uint256(value_) << DEVIATION_LTV_SHIFT);
        return LoopModality.wrap(v);
    }

    function leverageOperation(LoopModality modality_) internal pure returns (LeverageOperation) {
        bool supply = loopSupply(modality_);
        bool plainOperation_ = plainOperation(modality_);
        bool allocateFloating_ = allocateFloating(modality_);
        // if loopSupply is true, and plain operation is true, then return PlainSupply
        if (plainOperation_) {
            if (supply) return LeverageOperation.PlainSupply;
            else return LeverageOperation.PlainWithdraw;
        }
        if (supply) {
            if (allocateFloating_) return LeverageOperation.LoopSupplyAndAllocate;
            else return LeverageOperation.LoopSupplyAndDeallocate;
        }
        if (allocateFloating_) return LeverageOperation.LoopWithdrawAndAllocate;
        else return LeverageOperation.LoopWithdrawAndDeallocate;
    }

    // ---- Pack: build a LoopModality from all fields ----

    function pack(
        bool loopSupply_,
        bool plainOperation_,
        bool allocateFloating_,
        bool maxWithdraw_,
        uint64 targetLtvInWad_,
        uint64 deviationLtvInWad_
    ) internal pure returns (LoopModality) {
        uint256 v = 0;

        if (loopSupply_) v |= LOOP_SUPPLY_BIT;
        if (plainOperation_) v |= PLAIN_OPERATION_BIT;
        if (allocateFloating_) v |= ALLOCATE_FLOATING_BIT;
        if (maxWithdraw_) v |= MAX_WITHDRAW_BIT;

        v |= uint256(targetLtvInWad_) << TARGET_LTV_SHIFT;
        v |= uint256(deviationLtvInWad_) << DEVIATION_LTV_SHIFT;

        return LoopModality.wrap(v);
    }

    // ---- Init: simplified constructor that sets allocateFloating ----

    function init(bool allocateFloating_) internal pure returns (LoopModality) {
        uint256 v = 0;

        if (allocateFloating_) v |= ALLOCATE_FLOATING_BIT;

        return LoopModality.wrap(v);
    }
}
