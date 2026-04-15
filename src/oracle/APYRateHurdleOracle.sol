// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {IHurdleRateOracle} from "../interface/IHurdleRateOracle.sol";
import {UD60x18, ud, wrap} from "@prb/math/src/UD60x18.sol";

/**
 * @title APYRateHurdleOracle
 * @notice On-chain hurdle rate oracle using the exp(ln(1+apy) * t) identity
 *         to track a configured APY rate.
 *
 *         rate(t) = hurdleFloor × exp( ln(1 + targetAPY) × Δt / SECONDS_PER_YEAR )
 *
 * @dev All rates use 18-decimal (UD60x18) precision. `targetAPY` is expressed
 *      as a fractional rate: 5% → 0.05e18.
 */
contract APYRateHurdleOracle is IHurdleRateOracle, Ownable {
    // ── Constants ─────────────────────────────────────────────────────────

    uint256 private constant SECONDS_PER_YEAR = 365.25 days;
    uint256 private constant _PRECISION = 1e18;

    // ── Storage ──────────────────────────────────────────────────────────

    uint256 public hurdleFloor;
    uint256 public targetAPY;
    uint40 public startTimestamp;
    UD60x18 internal cachedLnFactor;

    // ── Events ───────────────────────────────────────────────────────────

    event Configured(uint256 hurdleFloor, uint256 targetAPY, uint40 startTimestamp);

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
     * @param targetAPY_      Annualized compound rate in UD60x18 (e.g. 0.05e18 = 5%).
     * @param startTimestamp_  Unix timestamp from which compounding begins.
     */
    function configure(uint256 hurdleFloor_, uint256 targetAPY_, uint40 startTimestamp_) external onlyOwner {
        if (hurdleFloor_ == 0) revert ZeroHurdleFloor();
        if (hurdleFloor_ > MAX_HURDLE_FLOOR) revert HurdleFloorTooHigh(hurdleFloor_, MAX_HURDLE_FLOOR);
        if (targetAPY_ < MIN_TARGET_RATE || targetAPY_ > MAX_TARGET_RATE) {
            revert TargetRateOutOfRange(targetAPY_, MIN_TARGET_RATE, MAX_TARGET_RATE);
        }
        if (startTimestamp_ == 0) revert ZeroTimestamp();

        hurdleFloor = hurdleFloor_;
        targetAPY = targetAPY_;
        startTimestamp = startTimestamp_;
        cachedLnFactor = targetAPY_ > 0 ? ud(_PRECISION + targetAPY_).ln() : ud(0);

        emit Configured(hurdleFloor_, targetAPY_, startTimestamp_);
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
        if (targetAPY == 0) return base;

        uint256 elapsed = block.timestamp - ts;

        UD60x18 scaledExponent = cachedLnFactor * ud(elapsed * _PRECISION / SECONDS_PER_YEAR);
        UD60x18 growthFactor = scaledExponent.exp();

        return (ud(base) * growthFactor).unwrap();
    }
}
