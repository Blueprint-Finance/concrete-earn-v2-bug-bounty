// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {APRRateHurdleOracle} from "../../../src/oracle/APRRateHurdleOracle.sol";
import {APYRateHurdleOracle} from "../../../src/oracle/APYRateHurdleOracle.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {Strings} from "@openzeppelin-contracts/utils/Strings.sol";

contract APRRateHurdleOracleFuzzTest is Test {
    APRRateHurdleOracle public oracle;
    APYRateHurdleOracle public apyOracle;

    uint256 internal constant BASE_RATE = 1e18;
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365.25 days; // 31_557_600
    uint256 internal constant MIN_APR = 0.001e18; // 0.1%
    uint256 internal constant MAX_APR = 0.25e18; // 25%
    uint256 internal constant HUNDRED_YEARS = 100 * SECONDS_PER_YEAR;
    uint256 internal constant TEN_YEARS = 10 * SECONDS_PER_YEAR;

    uint256 internal constant REALISTIC_TS = 1_700_000_000;

    function setUp() public {
        vm.warp(REALISTIC_TS);
        oracle = new APRRateHurdleOracle(address(this));
        apyOracle = new APYRateHurdleOracle(address(this));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Single-shot: oracle vs direct exp() (same library, verifies
    //    integration & storage wiring)
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_singleShot_matchesDirectExp(uint256 apr, uint256 elapsed) public {
        apr = bound(apr, MIN_APR, MAX_APR);
        elapsed = bound(elapsed, 0, HUNDRED_YEARS);

        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 oracleRate = oracle.getHurdleRate();

        uint256 expected;
        if (elapsed == 0) {
            expected = BASE_RATE;
        } else {
            UD60x18 exponent = ud(apr * elapsed / SECONDS_PER_YEAR);
            expected = (ud(BASE_RATE) * exponent.exp()).unwrap();
        }

        assertEq(oracleRate, expected, "Single-shot: oracle != direct exp()");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Single-shot: oracle vs Python Decimal reference (FFI)
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_singleShot_matchesPythonReference(uint256 apr, uint256 elapsed) public {
        apr = bound(apr, 0.001e18, MAX_APR);
        elapsed = bound(elapsed, 1, HUNDRED_YEARS);

        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 oracleRate = oracle.getHurdleRate();
        uint256 exact = _pythonContinuousRate(BASE_RATE, apr, elapsed);

        uint256 tolerance = exact / 100_000;
        if (tolerance == 0) tolerance = 1;

        assertApproxEqAbs(oracleRate, exact, tolerance, "Single-shot: oracle vs Python");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Multi-step time warp vs Python reference (FFI)
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_multiStep_vsPython(uint256 apr, uint256 dt1, uint256 dt2, uint256 dt3) public {
        apr = bound(apr, 0.001e18, MAX_APR);
        dt1 = bound(dt1, 1 days, TEN_YEARS);
        dt2 = bound(dt2, 1 days, TEN_YEARS);
        dt3 = bound(dt3, 1 days, TEN_YEARS);

        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));

        vm.warp(block.timestamp + dt1);
        oracle.getHurdleRate();

        vm.warp(block.timestamp + dt2);
        oracle.getHurdleRate();

        vm.warp(block.timestamp + dt3);
        uint256 rate = oracle.getHurdleRate();

        uint256 totalElapsed = dt1 + dt2 + dt3;
        uint256 exact = _pythonContinuousRate(BASE_RATE, apr, totalElapsed);

        uint256 tolerance = exact / 10_000;
        if (tolerance == 0) tolerance = 1;

        assertApproxEqAbs(rate, exact, tolerance, "Multi-step vs Python");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Monotonicity: rate never decreases as time advances
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_monotonicity(uint256 apr, uint256 elapsed1, uint256 elapsed2) public {
        apr = bound(apr, MIN_APR, MAX_APR);
        elapsed1 = bound(elapsed1, 0, 50 * SECONDS_PER_YEAR);
        elapsed2 = bound(elapsed2, 0, 50 * SECONDS_PER_YEAR);

        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));

        vm.warp(block.timestamp + elapsed1);
        uint256 rate1 = oracle.getHurdleRate();

        vm.warp(block.timestamp + elapsed2);
        uint256 rate2 = oracle.getHurdleRate();

        assertGe(rate2, rate1, "Rate must not decrease over time");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Zero APR: configure reverts
    // ─────────────────────────────────────────────────────────────────────

    function test_zeroAPR_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(APRRateHurdleOracle.TargetRateOutOfRange.selector, 0, MIN_APR, MAX_APR));
        oracle.configure(BASE_RATE, 0, uint40(block.timestamp));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. Rate at t=0 equals baseRate for any APR
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_rateAtT0_equalsBase(uint256 apr) public {
        apr = bound(apr, MIN_APR, MAX_APR);

        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));
        assertEq(oracle.getHurdleRate(), BASE_RATE, "rate(0) must equal baseRate");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Variable base rate
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_variableBaseRate(uint256 base, uint256 apr, uint256 elapsed) public {
        base = bound(base, 0.5e18, 5e18);
        apr = bound(apr, 0.001e18, MAX_APR);
        elapsed = bound(elapsed, 1 days, HUNDRED_YEARS);

        oracle.configure(base, apr, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 oracleRate = oracle.getHurdleRate();
        uint256 exact = _pythonContinuousRate(base, apr, elapsed);

        uint256 tolerance = exact / 100_000;
        if (tolerance == 0) tolerance = 1;

        assertApproxEqAbs(oracleRate, exact, tolerance, "Variable base: oracle vs Python");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. exp(r) > (1+r) for r>0: continuous compounding always exceeds
    //    discrete APY for the same nominal rate
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_continuousGeAPY(uint256 rate_, uint256 elapsed) public {
        rate_ = bound(rate_, 0.001e18, MAX_APR);
        elapsed = bound(elapsed, 1 days, HUNDRED_YEARS);

        oracle.configure(BASE_RATE, rate_, uint40(block.timestamp));
        apyOracle.configure(BASE_RATE, rate_, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 continuousRate = oracle.getHurdleRate();
        uint256 apyRate = apyOracle.getHurdleRate();

        assertGe(continuousRate, apyRate, "exp(r*t) must be >= (1+r)^t for same r");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. Gas usage
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_gasUsage(uint256 apr, uint256 elapsed) public {
        apr = bound(apr, 0.001e18, MAX_APR);
        elapsed = bound(elapsed, 1 days, TEN_YEARS);

        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 g0 = gasleft();
        oracle.getHurdleRate();
        uint256 gasUsed = g0 - gasleft();

        console.log("APR (1e18):", apr, "| elapsed (s):", elapsed);
        console.log("  getHurdleRate gas:", gasUsed);

        assertLt(gasUsed, 70_000, "getHurdleRate must stay under 70k gas");
    }

    function testFuzz_gasUsage() public {
        uint256 apr = MAX_APR;
        uint256 elapsed = TEN_YEARS * 5;

        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 g0 = gasleft();
        uint256 hurdleRate = oracle.getHurdleRate();
        uint256 gasUsed = g0 - gasleft();

        console.log("hurdleRate (1e18):", hurdleRate);
        console.log("APR (1e18):", apr, "| elapsed (s):", elapsed);
        console.log("  getHurdleRate gas:", gasUsed);

        assertLt(gasUsed, 70_000, "getHurdleRate must stay under 70k gas");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. Gas growth over time
    // ─────────────────────────────────────────────────────────────────────

    //     function test_gasGrowthOverTime() public {
    //         uint256 apr = MAX_APR;
    //         uint256 oneMonth = 31 days;
    //         uint256 totalMonths = 12 * 100;
    //
    //         vm.warp(REALISTIC_TS);
    //         oracle.configure(BASE_RATE, apr, uint40(REALISTIC_TS));
    //
    //         uint256 peakGas;
    //         uint256 peakMonth;
    //
    //         for (uint256 m = 1; m <= totalMonths; m++) {
    //             vm.warp(REALISTIC_TS + m * oneMonth);
    //
    //             uint256 g0 = gasleft();
    //             uint256 rate = oracle.getHurdleRate();
    //             uint256 gasUsed = g0 - gasleft();
    //
    //             if (gasUsed > peakGas) {
    //                 peakGas = gasUsed;
    //                 peakMonth = m;
    //                 console.log(
    //                     string.concat(
    //                         "NEW PEAK  month=", vm.toString(m),
    //                         " (", vm.toString(m / 12), "y", vm.toString(m % 12), "m)",
    //                         "  gas=", vm.toString(gasUsed),
    //                         "  rate=", vm.toString(rate)
    //                     )
    //                 );
    //             }
    //         }
    //
    //         uint256 finalRate = oracle.getHurdleRate();
    //         console.log("---");
    //         console.log(
    //             string.concat(
    //                 "FINAL PEAK  month=", vm.toString(peakMonth),
    //                 " (", vm.toString(peakMonth / 12), "y", vm.toString(peakMonth % 12), "m)",
    //                 "  gas=", vm.toString(peakGas),
    //                 "  finalRate=", vm.toString(finalRate)
    //             )
    //         );
    //     }

    // ─────────────────────────────────────────────────────────────────────
    // 11. Human-readable rate printout
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_printRate() public {
        uint256 apr = 24e18 / 100;
        uint256 elapsed = 365.25 days * 100;
        oracle.configure(BASE_RATE, apr, uint40(block.timestamp));
        vm.warp(block.timestamp + elapsed);

        uint256 rate = oracle.getHurdleRate();

        uint256 aprPctWhole = (apr * 100) / 1e18;
        uint256 aprPctFrac = ((apr * 100) % 1e18) / 1e14;
        uint256 elapsedDays = elapsed / 1 days;
        uint256 elapsedYears = elapsedDays / 365;
        uint256 remainDays = elapsedDays % 365;
        uint256 rateWhole = rate / 1e18;
        uint256 rateFrac = (rate % 1e18) / 1e12;

        console.log(
            string.concat(
                "APR: ",
                vm.toString(aprPctWhole),
                ".",
                _padLeft(vm.toString(aprPctFrac), 4),
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

    function _pythonContinuousRate(uint256 base, uint256 apr, uint256 elapsed) internal returns (uint256) {
        string[] memory inputs = new string[](5);
        inputs[0] = "python3";
        inputs[1] = "test/scripts/continuous_rate.py";
        inputs[2] = vm.toString(base);
        inputs[3] = vm.toString(apr);
        inputs[4] = vm.toString(elapsed);

        bytes memory result = vm.ffi(inputs);
        return abi.decode(result, (uint256));
    }
}
