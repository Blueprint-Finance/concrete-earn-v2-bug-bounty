// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {IHurdleRateOracle} from "../interface/IHurdleRateOracle.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

/**
 * @title APRRateHurdleOracle
 * @notice On-chain hurdle rate oracle using continuous compounding at a
 *         nominal APR:
 *
 *         rate(t) = hurdleFloor × exp(targetAPR × Δt / SECONDS_PER_YEAR)
 *
 *         Unlike the APY-based oracles that target exactly X% after one
 *         year via `(1+r)^t`, this oracle compounds continuously: a 5%
 *         nominal APR yields `exp(0.05) ≈ 5.127%` effective annual growth.
 *
 * @dev All rates use 18-decimal (UD60x18) precision. `targetAPR` is
 *      expressed as a fractional nominal rate: 5% → 0.05e18.
 */
contract APRRateHurdleOracle is IHurdleRateOracle, Ownable {
    // ── Constants ─────────────────────────────────────────────────────────

    uint256 private constant SECONDS_PER_YEAR = 365.25 days;
    uint256 private constant _PRECISION = 1e18;

    // ── Storage ──────────────────────────────────────────────────────────

    uint256 public hurdleFloor;
    uint256 public targetAPR;
    uint40 public startTimestamp;

    // ── Events ───────────────────────────────────────────────────────────

    event Configured(uint256 hurdleFloor, uint256 targetAPR, uint40 startTimestamp);

    // ── Validation bounds ─────────────────────────────────────────────────

    uint256 private constant MAX_HURDLE_FLOOR = 100e18;
    uint256 private constant MIN_TARGET_RATE = 0.001e18; // 0.1%
    uint256 private constant MAX_TARGET_RATE = 0.25e18; // 25%

    // ── Errors ───────────────────────────────────────────────────────────

    error ZeroHurdleFloor();
    error HurdleFloorTooHigh(uint256 hurdleFloor, uint256 max);
    error TargetRateOutOfRange(uint256 targetRate, uint256 min, uint256 max);
    error ZeroTimestamp();

    // ── Constructor ──────────────────────────────────────────────────────

    constructor(address owner_) Ownable(owner_) {}

    // ── Admin ────────────────────────────────────────────────────────────

    /**
     * @notice Configure (or reconfigure) the hurdle rate parameters.
     * @param hurdleFloor_    Baseline exchange rate in UD60x18 (e.g. 1e18 = 1.0).
     * @param targetAPR_      Nominal annualized rate in UD60x18 (e.g. 0.05e18 = 5%).
     * @param startTimestamp_  Unix timestamp from which growth begins.
     */
    function configure(uint256 hurdleFloor_, uint256 targetAPR_, uint40 startTimestamp_) external onlyOwner {
        if (hurdleFloor_ == 0) revert ZeroHurdleFloor();
        if (hurdleFloor_ > MAX_HURDLE_FLOOR) revert HurdleFloorTooHigh(hurdleFloor_, MAX_HURDLE_FLOOR);
        if (targetAPR_ < MIN_TARGET_RATE || targetAPR_ > MAX_TARGET_RATE) {
            revert TargetRateOutOfRange(targetAPR_, MIN_TARGET_RATE, MAX_TARGET_RATE);
        }
        if (startTimestamp_ == 0) revert ZeroTimestamp();

        hurdleFloor = hurdleFloor_;
        targetAPR = targetAPR_;
        startTimestamp = startTimestamp_;

        emit Configured(hurdleFloor_, targetAPR_, startTimestamp_);
    }

    // ── IHurdleRateOracle ────────────────────────────────────────────────

    /// @inheritdoc IHurdleRateOracle
    function precision() external pure override returns (uint256) {
        return _PRECISION;
    }

    /// @inheritdoc IHurdleRateOracle
    function getHurdleRate() external view override returns (uint256) {
        uint40 ts = startTimestamp;
        if (ts == 0) return 0;

        uint256 base = hurdleFloor;
        if (block.timestamp <= ts) return base;
        if (targetAPR == 0) return base;

        uint256 elapsed = block.timestamp - ts;

        UD60x18 exponent = ud(targetAPR * elapsed / SECONDS_PER_YEAR);
        UD60x18 growthFactor = exponent.exp();

        return (ud(base) * growthFactor).unwrap();
    }
}
