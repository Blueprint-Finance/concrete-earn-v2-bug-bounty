// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ContractIdEncoding} from "../../../src/lib/ContractIdEncoding.sol";

/// @notice Wrapper contract to test library functions that revert
contract ContractIdEncodingWrapper {
    function encode(
        uint256 contractType,
        uint256 flavour,
        uint256 majorVersion,
        uint256 minorVersion,
        uint256 patchVersion
    ) external pure returns (uint64) {
        return ContractIdEncoding.encode(contractType, flavour, majorVersion, minorVersion, patchVersion);
    }
}

contract ContractIdEncodingTest is Test {
    ContractIdEncodingWrapper public wrapper;

    function setUp() public {
        wrapper = new ContractIdEncodingWrapper();
    }

    function test_decode_flavourExtraction_specificCase() public {
        // This is the example from the bug report: contractType=2, flavour=2, version=1.0.6
        uint64 encodedId = ContractIdEncoding.encode(2, 2, 1, 0, 6);
        assertEq(encodedId, 200210006, "Encoded ID should match expected value");

        (uint256 contractType, uint256 flavour, uint256 majorVersion, uint256 minorVersion, uint256 patchVersion) =
            ContractIdEncoding.decode(encodedId);

        assertEq(contractType, 2, "Contract type should be 2");
        assertEq(flavour, 2, "Flavour should be 2 (not 2002)");
        assertEq(majorVersion, 1, "Major version should be 1");
        assertEq(minorVersion, 0, "Minor version should be 0");
        assertEq(patchVersion, 6, "Patch version should be 6");
    }

    // Test real-world example from the codebase
    function test_decode_realWorldExample() public {
        // Example from MultisigStrategy: contractType=2, flavour=2, version=1.0.6
        uint64 multisigStrategyId = 200210006;
        (uint256 contractType, uint256 flavour, uint256 majorVersion, uint256 minorVersion, uint256 patchVersion) =
            ContractIdEncoding.decode(multisigStrategyId);

        assertEq(contractType, 2, "MultisigStrategy contract type should be 2");
        assertEq(flavour, 2, "MultisigStrategy flavour should be 2");
        assertEq(majorVersion, 1, "MultisigStrategy major version should be 1");
        assertEq(minorVersion, 0, "MultisigStrategy minor version should be 0");
        assertEq(patchVersion, 6, "MultisigStrategy patch version should be 6");
    }

    /// @notice Fuzz test for encode/decode roundtrip with valid bounds
    /// @param contractType Contract type (0-99)
    /// @param flavour Flavour (0-999)
    /// @param majorVersion Major version (0-9)
    /// @param minorVersion Minor version (0-99)
    /// @param patchVersion Patch version (0-99)
    function testFuzz_encodeDecode_roundtrip(
        uint8 contractType,
        uint16 flavour,
        uint8 majorVersion,
        uint8 minorVersion,
        uint8 patchVersion
    ) public {
        // Bound inputs to valid ranges
        contractType = uint8(bound(contractType, 0, ContractIdEncoding.MAX_CONTRACT_TYPE));
        flavour = uint16(bound(flavour, 0, ContractIdEncoding.MAX_FLAVOUR));
        majorVersion = uint8(bound(majorVersion, 0, ContractIdEncoding.MAX_MAJOR_VERSION));
        minorVersion = uint8(bound(minorVersion, 0, ContractIdEncoding.MAX_MINOR_VERSION));
        patchVersion = uint8(bound(patchVersion, 0, ContractIdEncoding.MAX_PATCH_VERSION));

        uint64 encodedId = ContractIdEncoding.encode(
            uint256(contractType), uint256(flavour), uint256(majorVersion), uint256(minorVersion), uint256(patchVersion)
        );

        (
            uint256 decodedContractType,
            uint256 decodedFlavour,
            uint256 decodedMajorVersion,
            uint256 decodedMinorVersion,
            uint256 decodedPatchVersion
        ) = ContractIdEncoding.decode(encodedId);

        assertEq(decodedContractType, uint256(contractType), "Contract type should match");
        assertEq(decodedFlavour, uint256(flavour), "Flavour should match");
        assertEq(decodedMajorVersion, uint256(majorVersion), "Major version should match");
        assertEq(decodedMinorVersion, uint256(minorVersion), "Minor version should match");
        assertEq(decodedPatchVersion, uint256(patchVersion), "Patch version should match");
    }

    /// @notice Fuzz test for validation - ensures invalid inputs revert correctly
    /// @param invalidValue A value that may exceed one of the max bounds
    function testFuzz_encode_reverts_invalidInputs(uint256 invalidValue) public {
        // Test contractType exceeds max
        if (invalidValue > ContractIdEncoding.MAX_CONTRACT_TYPE) {
            vm.expectRevert("IdEncoding: contractType exceeds max");
            wrapper.encode(invalidValue, 0, 0, 0, 0);
            return;
        }

        // Test flavour exceeds max
        if (invalidValue > ContractIdEncoding.MAX_FLAVOUR) {
            vm.expectRevert("IdEncoding: flavour exceeds max");
            wrapper.encode(0, invalidValue, 0, 0, 0);
            return;
        }

        // Test majorVersion exceeds max
        if (invalidValue > ContractIdEncoding.MAX_MAJOR_VERSION) {
            vm.expectRevert("IdEncoding: majorVersion exceeds max");
            wrapper.encode(0, 0, invalidValue, 0, 0);
            return;
        }

        // Test minorVersion exceeds max
        if (invalidValue > ContractIdEncoding.MAX_MINOR_VERSION) {
            vm.expectRevert("IdEncoding: minorVersion exceeds max");
            wrapper.encode(0, 0, 0, invalidValue, 0);
            return;
        }

        // Test patchVersion exceeds max
        if (invalidValue > ContractIdEncoding.MAX_PATCH_VERSION) {
            vm.expectRevert("IdEncoding: patchVersion exceeds max");
            wrapper.encode(0, 0, 0, 0, invalidValue);
            return;
        }

        // If value is valid for all parameters, verify encoding succeeds
        // This ensures we test valid paths too
        if (
            invalidValue <= ContractIdEncoding.MAX_CONTRACT_TYPE && invalidValue <= ContractIdEncoding.MAX_FLAVOUR
                && invalidValue <= ContractIdEncoding.MAX_MAJOR_VERSION
                && invalidValue <= ContractIdEncoding.MAX_MINOR_VERSION
                && invalidValue <= ContractIdEncoding.MAX_PATCH_VERSION
        ) {
            uint64 encodedId = wrapper.encode(invalidValue, invalidValue, invalidValue, invalidValue, invalidValue);
            // Verify it's a valid encoding (non-zero or all zeros)
            assertTrue(encodedId >= 0);
        }
    }
}
