// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OneToOneAssetPricer} from "../../../src/pricer/OneToOneAssetPricer.sol";
import {IAssetPricer} from "../../../src/interface/IAssetPricer.sol";
import {ERC20DecimalsMock} from "../../mock/ERC20DecimalsMock.sol";

contract OneToOneAssetPricerUnitTest is Test {
    OneToOneAssetPricer public pricer;

    ERC20DecimalsMock public base6; // e.g. USDC
    ERC20DecimalsMock public base18; // 18-decimal base asset
    ERC20DecimalsMock public asset18; // 18-decimal deposit asset
    ERC20DecimalsMock public asset6; // 6-decimal deposit asset
    ERC20DecimalsMock public asset8; // 8-decimal deposit asset

    function setUp() public {
        pricer = new OneToOneAssetPricer();
        base6 = new ERC20DecimalsMock(6);
        base18 = new ERC20DecimalsMock(18);
        asset18 = new ERC20DecimalsMock(18);
        asset6 = new ERC20DecimalsMock(6);
        asset8 = new ERC20DecimalsMock(8);
    }

    function _convert(address from, address to, uint256 amount) internal view returns (uint256) {
        return pricer.convertToBase(from, to, amount);
    }

    // ── Same decimals ─────────────────────────────────────────────────────────

    function testSameDecimalsReturnsAmount() public view {
        // 100.000000 (6dp) deposit -> 100.000000 (6dp) base
        assertEq(_convert(address(asset6), address(base6), 100e6), 100e6);
    }

    function testSameAssetReturnsAmount() public view {
        assertEq(_convert(address(base6), address(base6), 12345), 12345);
    }

    // ── Scale down (more decimals -> fewer) ────────────────────────────────────

    function testScaleDown18To6() public view {
        // 100 * 1e18 (18dp) -> 100 * 1e6 (6dp)
        assertEq(_convert(address(asset18), address(base6), 100e18), 100e6);
    }

    function testScaleDown8To6() public view {
        assertEq(_convert(address(asset8), address(base6), 5e8), 5e6);
    }

    function testScaleDownRoundsDown() public view {
        // 12 decimals of extra precision are truncated (floor), never rounded up.
        // 1e18 + 999_999_999_999 wei (18dp) -> 1_000000 (6dp), remainder dropped.
        uint256 amount = 1e18 + 999_999_999_999;
        assertEq(_convert(address(asset18), address(base6), amount), 1e6);
    }

    function testScaleDownDustBelowOneUnitIsZero() public view {
        // Any amount smaller than 10**(18-6) = 1e12 converts to 0 base units.
        assertEq(_convert(address(asset18), address(base6), 1e12 - 1), 0);
        assertEq(_convert(address(asset18), address(base6), 1e12), 1);
    }

    // ── Scale up (fewer decimals -> more) ──────────────────────────────────────

    function testScaleUp6To18() public view {
        assertEq(_convert(address(asset6), address(base18), 100e6), 100e18);
    }

    // ── Zero amount ─────────────────────────────────────────────────────────

    function testZeroAmountReturnsZero() public view {
        assertEq(_convert(address(asset18), address(base6), 0), 0);
    }

    // ── Fuzz: round-trip and monotonicity ──────────────────────────────────────

    function testFuzzScaleUpExact(uint96 amount) public view {
        // Scaling up is lossless: 6dp -> 18dp multiplies by 1e12 exactly.
        assertEq(_convert(address(asset6), address(base18), amount), uint256(amount) * 1e12);
    }

    function testFuzzScaleDownMatchesDivision(uint256 amount) public view {
        amount = bound(amount, 0, type(uint256).max);
        assertEq(_convert(address(asset18), address(base6), amount), amount / 1e12);
    }
}
