// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {OffchainHurdleRateOracle} from "../../../src/oracle/OffchainHurdleRateOracle.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

contract OffchainHurdleRateOracleTest is Test {
    OffchainHurdleRateOracle public oracle;

    uint256 internal constant INITIAL_RATE = 1e18;
    uint256 internal constant NEW_RATE = 1.05e18;
    uint256 internal constant ANOTHER_RATE = 2e18;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);

    function setUp() public {
        oracle = new OffchainHurdleRateOracle(owner, INITIAL_RATE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Constructor sets initial rate correctly
    // ─────────────────────────────────────────────────────────────────────

    function test_constructor_setsRate() public {
        OffchainHurdleRateOracle o = new OffchainHurdleRateOracle(owner, NEW_RATE);

        assertEq(o.rate(), NEW_RATE);
        assertEq(o.getHurdleRate(), NEW_RATE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Constructor reverts on zero rate
    // ─────────────────────────────────────────────────────────────────────

    function test_constructor_revertsOnZero() public {
        vm.expectRevert(OffchainHurdleRateOracle.ZeroRate.selector);
        new OffchainHurdleRateOracle(owner, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2b. Constructor reverts on rate > 100e18
    // ─────────────────────────────────────────────────────────────────────

    function test_constructor_revertsOnRateTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(OffchainHurdleRateOracle.RateTooHigh.selector, 100e18 + 1, 100e18));
        new OffchainHurdleRateOracle(owner, 100e18 + 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. setRate updates the stored rate
    // ─────────────────────────────────────────────────────────────────────

    function test_setRate_updatesRate() public {
        oracle.setRate(NEW_RATE);

        assertEq(oracle.rate(), NEW_RATE);
        assertEq(oracle.getHurdleRate(), NEW_RATE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. setRate emits RateUpdated event
    // ─────────────────────────────────────────────────────────────────────

    function test_setRate_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit OffchainHurdleRateOracle.RateUpdated(INITIAL_RATE, NEW_RATE);

        oracle.setRate(NEW_RATE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. setRate reverts on zero
    // ─────────────────────────────────────────────────────────────────────

    function test_setRate_revertsOnZero() public {
        vm.expectRevert(OffchainHurdleRateOracle.ZeroRate.selector);
        oracle.setRate(0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5b. setRate reverts on rate > 100e18
    // ─────────────────────────────────────────────────────────────────────

    function test_setRate_revertsOnRateTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(OffchainHurdleRateOracle.RateTooHigh.selector, 100e18 + 1, 100e18));
        oracle.setRate(100e18 + 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. setRate reverts for non-owner
    // ─────────────────────────────────────────────────────────────────────

    function test_setRate_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        oracle.setRate(NEW_RATE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Rate is independent of time (no compounding)
    // ─────────────────────────────────────────────────────────────────────

    function test_rateUnaffectedByTime() public {
        oracle.setRate(NEW_RATE);
        vm.warp(block.timestamp + 365.25 days * 10);

        assertEq(oracle.getHurdleRate(), NEW_RATE, "Rate should not change with time");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. Rate is independent of caller
    // ─────────────────────────────────────────────────────────────────────

    function test_rateIndependentOfCaller() public {
        oracle.setRate(NEW_RATE);

        assertEq(oracle.getHurdleRate(), NEW_RATE, "Rate must be returned regardless of caller");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. Multiple sequential rate updates
    // ─────────────────────────────────────────────────────────────────────

    function test_multipleUpdates() public {
        oracle.setRate(NEW_RATE);
        assertEq(oracle.getHurdleRate(), NEW_RATE);

        oracle.setRate(ANOTHER_RATE);
        assertEq(oracle.getHurdleRate(), ANOTHER_RATE);

        oracle.setRate(INITIAL_RATE);
        assertEq(oracle.getHurdleRate(), INITIAL_RATE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. precision
    // ─────────────────────────────────────────────────────────────────────

    function test_precision() public view {
        assertEq(oracle.precision(), 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. getHurdleRate does not modify storage
    // ─────────────────────────────────────────────────────────────────────

    function test_getHurdleRate_noSideEffects() public {
        oracle.setRate(NEW_RATE);
        uint256 rateBefore = oracle.rate();

        vm.recordLogs();
        oracle.getHurdleRate();

        assertEq(oracle.rate(), rateBefore, "getHurdleRate must not change storage");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "getHurdleRate must not emit events");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 12. Gas usage
    // ─────────────────────────────────────────────────────────────────────

    function test_gasUsage() public {
        oracle.setRate(NEW_RATE);

        uint256 g0 = gasleft();
        oracle.getHurdleRate();
        uint256 gasRate = g0 - gasleft();

        g0 = gasleft();
        oracle.setRate(NEW_RATE);
        uint256 gasSet = g0 - gasleft();

        console.log("  getHurdleRate gas:", gasRate);
        console.log("  setRate gas:", gasSet);

        assertLt(gasRate, 30_000, "getHurdleRate must stay under 30k gas");
        assertLt(gasSet, 40_000, "setRate must stay under 40k gas");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 13. getHurdleRate reverts when rate is stale
    // ─────────────────────────────────────────────────────────────────────

    function test_getHurdleRate_revertsWhenStale() public {
        uint256 shortStaleness = 1 hours;
        oracle.setMaxStaleness(shortStaleness);

        uint256 lastUpdate = oracle.lastUpdateTimestamp();

        vm.warp(lastUpdate + shortStaleness + 1);

        vm.expectRevert(abi.encodeWithSelector(OffchainHurdleRateOracle.StaleRate.selector, lastUpdate, shortStaleness));
        oracle.getHurdleRate();
    }

    // ─────────────────────────────────────────────────────────────────────
    // 14. setRate resets the staleness clock so getHurdleRate succeeds
    // ─────────────────────────────────────────────────────────────────────

    function test_setRate_resetsStaleness() public {
        uint256 shortStaleness = 1 hours;
        oracle.setMaxStaleness(shortStaleness);

        vm.warp(block.timestamp + shortStaleness + 1);

        vm.expectRevert();
        oracle.getHurdleRate();

        oracle.setRate(NEW_RATE);

        assertEq(oracle.getHurdleRate(), NEW_RATE, "Rate should be returned after fresh setRate");
        assertEq(oracle.lastUpdateTimestamp(), block.timestamp, "lastUpdateTimestamp should equal current block");
    }
}
