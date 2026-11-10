// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {APYRateHurdleOracle} from "../../../src/oracle/APYRateHurdleOracle.sol";
import {APRRateHurdleOracle} from "../../../src/oracle/APRRateHurdleOracle.sol";
import {UD60x18, ud, wrap} from "@prb/math/src/UD60x18.sol";
import {Strings} from "@openzeppelin-contracts/utils/Strings.sol";

contract APYRateHurdleOracleFuzzTest is Test {
    APYRateHurdleOracle public oracle;
    APRRateHurdleOracle public aprOracle;

    uint256 internal constant BASE_RATE = 1e18;
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365.25 days; // 31_557_600
    uint256 internal constant MIN_APY = 0.001e18; // 0.1%
    uint256 internal constant MAX_APY = 0.25e18; // 25%
    uint256 internal constant HUNDRED_YEARS = 100 * SECONDS_PER_YEAR;
    uint256 internal constant TEN_YEARS = 10 * SECONDS_PER_YEAR;

    uint256 internal constant REALISTIC_TS = 1_700_000_000; // Nov 2023

    function setUp() public {
        vm.warp(REALISTIC_TS);
        oracle = new APYRateHurdleOracle(address(this));
        aprOracle = new APRRateHurdleOracle(address(this));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Single-shot: oracle vs direct exp(ln()) math (same library,
    //    verifies integration & storage wiring)
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_singleShot_matchesDirectExpLn(uint256 apy, uint256 elapsed) public {
        apy = bound(apy, MIN_APY, MAX_APY);
        elapsed = bound(elapsed, 0, HUNDRED_YEARS);

        oracle.configure(BASE_RATE, apy, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 oracleRate = oracle.getHurdleRate();

        uint256 expected;
        if (elapsed == 0) {
            expected = BASE_RATE;
        } else {
            UD60x18 onePlusAPY = wrap(PRECISION + apy);
            UD60x18 lnFactor = onePlusAPY.ln();
            UD60x18 scaledExp = lnFactor * ud(elapsed * PRECISION / SECONDS_PER_YEAR);
            expected = (ud(BASE_RATE) * scaledExp.exp()).unwrap();
        }

        assertEq(oracleRate, expected, "Single-shot: oracle != direct exp(ln)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Single-shot: oracle vs Python Decimal reference (FFI)
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_singleShot_matchesPythonReference(uint256 apy, uint256 elapsed) public {
        apy = bound(apy, 0.001e18, MAX_APY);
        elapsed = bound(elapsed, 1, HUNDRED_YEARS);

        oracle.configure(BASE_RATE, apy, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 oracleRate = oracle.getHurdleRate();
        uint256 exact = _pythonCompoundRate(BASE_RATE, apy, elapsed);

        uint256 tolerance = exact / 100_000;
        if (tolerance == 0) tolerance = 1;

        assertApproxEqAbs(oracleRate, exact, tolerance, "Single-shot: oracle vs Python");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Monotonicity: rate never decreases as time advances
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_monotonicity(uint256 apy, uint256 elapsed1, uint256 elapsed2) public {
        apy = bound(apy, MIN_APY, MAX_APY);
        elapsed1 = bound(elapsed1, 0, 50 * SECONDS_PER_YEAR);
        elapsed2 = bound(elapsed2, 0, 50 * SECONDS_PER_YEAR);

        oracle.configure(BASE_RATE, apy, uint40(block.timestamp));

        vm.warp(block.timestamp + elapsed1);
        uint256 rate1 = oracle.getHurdleRate();

        vm.warp(block.timestamp + elapsed2);
        uint256 rate2 = oracle.getHurdleRate();

        assertGe(rate2, rate1, "Rate must not decrease over time");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Zero APY: configure reverts
    // ─────────────────────────────────────────────────────────────────────

    function test_zeroAPY_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(APYRateHurdleOracle.TargetRateOutOfRange.selector, 0, MIN_APY, MAX_APY));
        oracle.configure(BASE_RATE, 0, uint40(block.timestamp));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Rate at t=0 equals baseRate for any APY
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_rateAtT0_equalsBase(uint256 apy) public {
        apy = bound(apy, MIN_APY, MAX_APY);

        oracle.configure(BASE_RATE, apy, uint40(block.timestamp));
        assertEq(oracle.getHurdleRate(), BASE_RATE, "rate(0) must equal baseRate");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. Variable base rate: non-1.0 starting rate
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_variableBaseRate(uint256 base, uint256 apy, uint256 elapsed) public {
        base = bound(base, 0.5e18, 5e18);
        apy = bound(apy, 0.001e18, MAX_APY);
        elapsed = bound(elapsed, 1 days, HUNDRED_YEARS);

        oracle.configure(base, apy, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 oracleRate = oracle.getHurdleRate();
        uint256 exact = _pythonCompoundRate(base, apy, elapsed);

        uint256 tolerance = exact / 100_000;
        if (tolerance == 0) tolerance = 1;

        assertApproxEqAbs(oracleRate, exact, tolerance, "Variable base: oracle vs Python");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Gas usage measurement
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_gasUsage(uint256 apy, uint256 elapsed) public {
        apy = bound(apy, 0.001e18, MAX_APY);
        elapsed = bound(elapsed, 1 days, TEN_YEARS);

        oracle.configure(BASE_RATE, apy, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 g0 = gasleft();
        oracle.getHurdleRate();
        uint256 gasUsed = g0 - gasleft();

        console.log("APY (1e18):", apy, "| elapsed (s):", elapsed);
        console.log("  getHurdleRate gas:", gasUsed);

        assertLt(gasUsed, 70_000, "getHurdleRate must stay under 70k gas");
    }

    function testFuzz_gasUsage() public {
        uint256 apy = MAX_APY - 1;
        uint256 elapsed = TEN_YEARS;

        oracle.configure(BASE_RATE, apy, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 g0 = gasleft();
        oracle.getHurdleRate();
        uint256 gasUsed = g0 - gasleft();

        console.log("APY (1e18):", apy, "| elapsed (s):", elapsed);
        console.log("  getHurdleRate gas:", gasUsed);

        assertLt(gasUsed, 70_000, "getHurdleRate must stay under 70k gas");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7b. Gas growth over time
    //     Iterates in 1-day steps over 100 years at MAX_APY using the
    //     view function. Logs whenever a new peak gas usage is observed.
    // ─────────────────────────────────────────────────────────────────────

    // function test_gasGrowthOverTime() public {
    //     uint256 apy = MAX_APY;
    //     uint256 oneDay = 1 days;
    //     uint256 totalDays = 100 * 12 * 31;
    //
    //     oracle.configure(BASE_RATE, apy, uint40(block.timestamp));
    //
    //     uint256 peakGas;
    //     uint256 peakDay;
    //
    //     for (uint256 d = 1; d <= totalDays; d++) {
    //         vm.warp(REALISTIC_TS + d * oneDay);
    //
    //         uint256 g0 = gasleft();
    //         uint256 rate = oracle.getHurdleRate();
    //         uint256 gasUsed = g0 - gasleft();
    //
    //         if (gasUsed > peakGas) {
    //             peakGas = gasUsed;
    //             peakDay = d;
    //             console.log(
    //                 string.concat(
    //                     "NEW PEAK  day=", vm.toString(d),
    //                     " (", vm.toString(d / 365), "y", vm.toString(d % 365), "d)",
    //                     "  gas=", vm.toString(gasUsed),
    //                     "  rate=", vm.toString(rate)
    //                 )
    //             );
    //         }
    //     }
    //
    //     uint256 finalRate = oracle.getHurdleRate();
    //     console.log("---");
    //     console.log(
    //         string.concat(
    //             "FINAL PEAK  day=", vm.toString(peakDay),
    //             " (", vm.toString(peakDay / 365), "y", vm.toString(peakDay % 365), "d)",
    //             "  gas=", vm.toString(peakGas),
    //             "  finalRate=", vm.toString(finalRate)
    //         )
    //     );
    // }

    // ─────────────────────────────────────────────────────────────────────
    // 8. Cross-validation: APY exp(ln(1+r)*t) vs APR exp(r*t)
    //    For the same nominal rate, exp(r*t) >= (1+r)^t since exp(r) >= 1+r.
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_apyLeAPR(uint256 rate_, uint256 elapsed) public {
        rate_ = bound(rate_, 0.001e18, MAX_APY);
        elapsed = bound(elapsed, 1 days, HUNDRED_YEARS);

        oracle.configure(BASE_RATE, rate_, uint40(block.timestamp));
        aprOracle.configure(BASE_RATE, rate_, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 apyRate = oracle.getHurdleRate();
        uint256 aprRate = aprOracle.getHurdleRate();

        assertLe(apyRate, aprRate, "APY (1+r)^t must be <= APR exp(r*t) for same r");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. Human-readable rate printout
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_printRate() public {
        uint256 apy = 24e18 / 100;
        uint256 elapsed = 365.25 days * 100;
        oracle.configure(BASE_RATE, apy, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 rate = oracle.getHurdleRate();

        uint256 apyPctWhole = (apy * 100) / 1e18;
        uint256 apyPctFrac = ((apy * 100) % 1e18) / 1e14; // 4 decimals
        uint256 elapsedDays = elapsed / 1 days;
        uint256 elapsedYears = elapsedDays / 365;
        uint256 remainDays = elapsedDays % 365;
        uint256 rateWhole = rate / 1e18;
        uint256 rateFrac = (rate % 1e18) / 1e12; // 6 decimals

        console.log(
            string.concat(
                "APY: ",
                vm.toString(apyPctWhole),
                ".",
                _padLeft(vm.toString(apyPctFrac), 4),
                "%",
                " | elapsed: ",
                vm.toString(elapsedYears),
                "y ",
                vm.toString(remainDays),
                "d",
                " | rate: ",
                vm.toString(rateWhole),
                ".",
                _padLeft(vm.toString(rateFrac), 6)
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _padLeft(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory padded = new bytes(width);
        uint256 offset = width - b.length;
        for (uint256 i; i < width; ++i) {
            padded[i] = i < offset ? bytes1("0") : b[i - offset];
        }
        return string(padded);
    }

    function _pythonCompoundRate(uint256 base, uint256 apy, uint256 elapsed) internal returns (uint256) {
        string[] memory inputs = new string[](5);
        inputs[0] = "python3";
        inputs[1] = "test/scripts/compound_rate.py";
        inputs[2] = vm.toString(base);
        inputs[3] = vm.toString(apy);
        inputs[4] = vm.toString(elapsed);

        bytes memory result = vm.ffi(inputs);
        return abi.decode(result, (uint256));
    }
}
