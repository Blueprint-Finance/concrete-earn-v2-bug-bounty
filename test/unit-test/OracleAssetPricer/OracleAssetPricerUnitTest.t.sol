// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {OracleModule} from "../../../src/periphery/oracle/OracleModule.sol";
import {OracleAssetPricer} from "../../../src/pricer/OracleAssetPricer.sol";
import {ChainlinkOracleMock} from "../../mock/ChainlinkOracleMock.sol";
import {ERC20DecimalsMock} from "../../mock/ERC20DecimalsMock.sol";

contract OracleAssetPricerUnitTest is Test {
    OracleModule internal oracleModule;
    OracleAssetPricer internal pricer;

    ERC20DecimalsMock internal base6; // e.g. USDC
    ERC20DecimalsMock internal base18;
    ERC20DecimalsMock internal asset18;
    ERC20DecimalsMock internal asset6;

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant ONE_USD = 10 ** uint256(FEED_DECIMALS);

    function setUp() public {
        oracleModule = new OracleModule(address(this), FEED_DECIMALS);
        pricer = new OracleAssetPricer(address(oracleModule));

        base6 = new ERC20DecimalsMock(6);
        base18 = new ERC20DecimalsMock(18);
        asset18 = new ERC20DecimalsMock(18);
        asset6 = new ERC20DecimalsMock(6);
    }

    // ── Price ratio ────────────────────────────────────────────────────────────

    function testEqualPricesAndDecimalsReturnsAmount() public {
        _setPrice(address(asset18), ONE_USD);
        _setPrice(address(base18), ONE_USD);

        assertEq(_convert(address(asset18), address(base18), 100e18), 100e18);
    }

    function testDepositAssetWorthMoreThanBase() public {
        _setPrice(address(asset18), 2500 * ONE_USD); // e.g. WETH
        _setPrice(address(base18), ONE_USD);

        assertEq(_convert(address(asset18), address(base18), 2e18), 5000e18);
    }

    function testDepositAssetWorthLessThanBase() public {
        _setPrice(address(asset18), ONE_USD);
        _setPrice(address(base18), 4 * ONE_USD);

        assertEq(_convert(address(asset18), address(base18), 100e18), 25e18);
    }

    function testSubUnitPricesUseFullFeedPrecision() public {
        // Fractional prices below one quote unit still resolve exactly: 0.00000123 / 0.00000041 = 3.
        _setPrice(address(asset18), 123);
        _setPrice(address(base18), 41);

        assertEq(_convert(address(asset18), address(base18), 10e18), 30e18);
    }

    // ── Decimal delta ──────────────────────────────────────────────────────────

    function testScalesUpWhenBaseHasMoreDecimals() public {
        // 6dp asset @ $3 -> 18dp base @ $1.
        _setPrice(address(asset6), 3 * ONE_USD);
        _setPrice(address(base18), ONE_USD);

        assertEq(_convert(address(asset6), address(base18), 1_000e6), 3_000e18);
    }

    function testScalesDownWhenBaseHasFewerDecimals() public {
        // 18dp asset @ $2 -> 6dp base @ $1.
        _setPrice(address(asset18), 2 * ONE_USD);
        _setPrice(address(base6), ONE_USD);

        assertEq(_convert(address(asset18), address(base6), 100e18), 200e6);
    }

    // ── Rounding ───────────────────────────────────────────────────────────────

    function testRoundsDownOnFractionalRatio() public {
        _setPrice(address(asset18), ONE_USD);
        _setPrice(address(base18), 3 * ONE_USD);

        // floor(10e18 / 3), never the ceiling.
        assertEq(_convert(address(asset18), address(base18), 10e18), 3_333_333_333_333_333_333);
    }

    function testRoundsDownDustToZero() public {
        // 18dp asset @ $1 -> 6dp base @ $1: anything below 1e12 wei is worth zero base units.
        _setPrice(address(asset18), ONE_USD);
        _setPrice(address(base6), ONE_USD);

        assertEq(_convert(address(asset18), address(base6), 1e12 - 1), 0);
        assertEq(_convert(address(asset18), address(base6), 1e12), 1);
    }

    function testFuzzNeverOverValues(uint128 amount, uint64 depositPrice, uint64 basePrice) public {
        depositPrice = uint64(bound(depositPrice, 1, type(uint64).max));
        basePrice = uint64(bound(basePrice, 1, type(uint64).max));
        _setPrice(address(asset18), depositPrice);
        _setPrice(address(base18), basePrice);

        uint256 baseAmount = _convert(address(asset18), address(base18), amount);

        // Floor property: reconstructing the deposit value must never exceed the true value.
        assertLe(baseAmount * basePrice, uint256(amount) * depositPrice, "conversion rounded up");
    }

    // ── Short circuits and reverts ─────────────────────────────────────────────

    function testZeroAmountReturnsZeroWithoutQueryingOracles() public view {
        // No feeds configured for these tokens: a non-short-circuited call would revert.
        assertEq(_convert(address(asset18), address(base18), 0), 0);
    }

    function testSameAssetReturnsAmountWithoutQueryingOracles() public view {
        assertEq(_convert(address(base18), address(base18), 12345), 12345);
    }

    function testRevertsWhenDepositAssetHasNoFeed() public {
        _setPrice(address(base18), ONE_USD);

        vm.expectRevert(OracleModule.InvalidOracle.selector);
        _convert(address(asset18), address(base18), 1e18);
    }

    function testRevertsWhenBaseAssetHasNoFeed() public {
        _setPrice(address(asset18), ONE_USD);

        vm.expectRevert(OracleModule.InvalidOracle.selector);
        _convert(address(asset18), address(base18), 1e18);
    }

    function testRevertsWhenPriceIsStale() public {
        ChainlinkOracleMock depositFeed = new ChainlinkOracleMock(FEED_DECIMALS, int256(ONE_USD));
        oracleModule.setOracle(address(asset18), address(depositFeed), 0, 0, 1 hours, false, true);
        _setPrice(address(base18), ONE_USD);

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(OracleModule.StalePrice.selector);
        _convert(address(asset18), address(base18), 1e18);
    }

    function testConstructorRejectsZeroOracleModule() public {
        vm.expectRevert(OracleAssetPricer.ZeroOracleModule.selector);
        new OracleAssetPricer(address(0));
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _convert(address from, address to, uint256 amount) internal view returns (uint256) {
        return pricer.convertToBase(from, to, amount);
    }

    function _setPrice(address token, uint256 price) internal {
        ChainlinkOracleMock feed = new ChainlinkOracleMock(FEED_DECIMALS, int256(price));
        oracleModule.setOracle(token, address(feed), 0, 0, 1 hours, false, true);
    }
}
