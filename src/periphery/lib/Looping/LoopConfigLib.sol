// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

type LoopConfig is uint256;

library LoopConfigLib {
    // ---- Layout ----
    // Bit 0: isLooping (bool)
    // Bit 1: permissioned (bool)

    // ---- Bit masks ----
    uint256 private constant IS_LOOPING_BIT = 1 << 0;
    uint256 private constant PERMISSIONED_BIT = 1 << 1;

    // ---- Getters ----

    function isLooping(LoopConfig config_) internal pure returns (bool) {
        return (LoopConfig.unwrap(config_) & IS_LOOPING_BIT) != 0;
    }

    function permissioned(LoopConfig config_) internal pure returns (bool) {
        return (LoopConfig.unwrap(config_) & PERMISSIONED_BIT) != 0;
    }

    // ---- Setters (field-preserving) ----

    function setIsLooping(LoopConfig config_, bool value_) internal pure returns (LoopConfig) {
        uint256 v = LoopConfig.unwrap(config_);
        v = value_ ? (v | IS_LOOPING_BIT) : (v & ~IS_LOOPING_BIT);
        return LoopConfig.wrap(v);
    }

    function setPermissioned(LoopConfig config_, bool value_) internal pure returns (LoopConfig) {
        uint256 v = LoopConfig.unwrap(config_);
        v = value_ ? (v | PERMISSIONED_BIT) : (v & ~PERMISSIONED_BIT);
        return LoopConfig.wrap(v);
    }

    // ---- Pack: build a LoopConfig from all fields ----

    function pack(bool isLooping_, bool permissioned_) internal pure returns (LoopConfig) {
        uint256 v = 0;

        if (isLooping_) v |= IS_LOOPING_BIT;
        if (permissioned_) v |= PERMISSIONED_BIT;

        return LoopConfig.wrap(v);
    }
}
