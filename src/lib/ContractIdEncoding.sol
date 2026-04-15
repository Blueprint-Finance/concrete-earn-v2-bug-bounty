// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ContractIdEncoding
 * @notice Library for encoding and decoding contract IDs with version, flavour, and contract type
 * @dev The ID structure is as follows:
 *      - Version: 0-99999 (5 digits)
 *          - Major release: 0-9 (first digit)
 *          - Minor release: 0-99 (next 2 digits)
 *          - Patch/Batch: 0-99 (last 2 digits)
 *          - Version 99999 is reserved for tests or otherwise non-production versions.
 *      - Flavours: 100000-99900000 (next 3 digits, multiplied by 100000)
 *          - E.g. for vault contract types we could have:
 *             0: Concrete Standard Vault
 *             1: Concrete Async Vault
 *             2: Concrete Standard Predeposit Vault
 *             3: Concrete Async Predeposit Vault
 *             4: Concrete Standard Bridged Vault
 *             5: Concrete Async Bridged Vault
 *          - flavour 999 is reserved for tests or otherwise non-production flavours.
 *      - Contract types: 100000000-9900000000 (next 2 digits, multiplied by 100000000)
 *
 *      Contract type mappings:
 *      - 0: Vault contract type
 *      - 1: Multi Asset Vault contract type
 *      - 2: Strategy contract type
 *      - 3: Hook contract type
 *      - 4: Fee splitter contract type
 */
library ContractIdEncoding {
    /// @notice Maximum major version value (9)
    uint256 public constant MAX_MAJOR_VERSION = 9;

    /// @notice Maximum minor version value (99)
    uint256 public constant MAX_MINOR_VERSION = 99;

    /// @notice Maximum patch version value (99)
    uint256 public constant MAX_PATCH_VERSION = 99;

    /// @notice Maximum version value (99999)
    uint256 public constant MAX_VERSION = 99999;

    /// @notice Maximum flavour value (999)
    uint256 public constant MAX_FLAVOUR = 999;

    /// @notice Maximum contract type value (99)
    uint256 public constant MAX_CONTRACT_TYPE = 99;

    /// @notice Multiplier for flavour position
    uint256 private constant FLAVOUR_MULTIPLIER = 100000;

    /// @notice Multiplier for contract type position
    uint256 private constant CONTRACT_TYPE_MULTIPLIER = 100000000;

    /**
     * @notice Encodes contract type, flavour, and version into a single ID
     * @param contractType The contract type (0-99)
     *                  - 0: Vault contract type
     *                  - 1: Strategy contract type
     *                  - 2: Hook contract type
     *                  - 3: Fee splitter contract type
     * @param flavour The flavour (0-999)
     * @param majorVersion The major version (0-9)
     * @param minorVersion The minor version (0-99)
     * @param patchVersion The patch/batch version (0-99)
     * @return encodedId The encoded ID (uint64)
     */
    function encode(
        uint256 contractType,
        uint256 flavour,
        uint256 majorVersion,
        uint256 minorVersion,
        uint256 patchVersion
    ) internal pure returns (uint64 encodedId) {
        require(contractType <= MAX_CONTRACT_TYPE, "IdEncoding: contractType exceeds max");
        require(flavour <= MAX_FLAVOUR, "IdEncoding: flavour exceeds max");
        require(majorVersion <= MAX_MAJOR_VERSION, "IdEncoding: majorVersion exceeds max");
        require(minorVersion <= MAX_MINOR_VERSION, "IdEncoding: minorVersion exceeds max");
        require(patchVersion <= MAX_PATCH_VERSION, "IdEncoding: patchVersion exceeds max");

        uint256 version = majorVersion * 10000 + minorVersion * 100 + patchVersion;
        encodedId = uint64(version + (flavour * FLAVOUR_MULTIPLIER) + (contractType * CONTRACT_TYPE_MULTIPLIER));
    }

    /**
     * @notice Decodes an encoded ID into contract type, flavour, and version components
     * @param encodedId The encoded ID to decode (uint64)
     * @return contractType The contract type (0-99)
     *                  - 0: Single Asset Vault contract type
     *                  - 1: Multi Asset Vault contract type
     *                  - 2: Strategy contract type
     *                  - 3: Hook contract type
     *                  - 4: Fee splitter contract type
     * @return flavour The flavour (0-999)
     * @return majorVersion The major version (0-9)
     * @return minorVersion The minor version (0-99)
     * @return patchVersion The patch/batch version (0-99)
     */
    function decode(uint64 encodedId)
        internal
        pure
        returns (
            uint256 contractType,
            uint256 flavour,
            uint256 majorVersion,
            uint256 minorVersion,
            uint256 patchVersion
        )
    {
        uint256 version = uint256(encodedId) % FLAVOUR_MULTIPLIER;
        flavour = (uint256(encodedId) / FLAVOUR_MULTIPLIER) % (CONTRACT_TYPE_MULTIPLIER / FLAVOUR_MULTIPLIER);
        contractType = uint256(encodedId) / CONTRACT_TYPE_MULTIPLIER;

        majorVersion = version / 10000;
        minorVersion = (version / 100) % 100;
        patchVersion = version % 100;
    }
}

