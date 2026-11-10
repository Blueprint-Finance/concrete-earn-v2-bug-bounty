// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {IHurdleRateOracle} from "../interface/IHurdleRateOracle.sol";

/**
 * @title OffchainHurdleRateOracle
 * @notice Minimal hurdle rate oracle whose rate is set by a privileged
 *         off-chain backend via `setRate`. `getHurdleRate` simply returns
 *         the stored value — no on-chain compounding is performed.
 *
 * @dev All rates use 18-decimal precision (UD60x18 compatible).
 *      The owner is expected to periodically push updated rates that
 *      reflect the desired hurdle (e.g. compound growth computed
 *      off-chain with arbitrary precision).
 */
contract OffchainHurdleRateOracle is IHurdleRateOracle, Ownable {
    // ── Constants ─────────────────────────────────────────────────────────

    uint256 private constant _PRECISION = 1e18;

    /// For most default deployments check is effectivly ignored by setting a large maxStaleness (100 years)
    /// Needs to be configured with a reasonable value for the specific deployment.
    uint256 public constant DEFAULT_MAX_STALENESS = 365.25 days * 100;

    // ── Storage ──────────────────────────────────────────────────────────

    uint256 public rate;
    uint256 public lastUpdateTimestamp;
    uint256 public maxStaleness;

    // ── Events ───────────────────────────────────────────────────────────

    event RateUpdated(uint256 oldRate, uint256 newRate);
    event MaxStalenessUpdated(uint256 oldMaxStaleness, uint256 newMaxStaleness);

    // ── Validation bounds ─────────────────────────────────────────────────

    uint256 private constant MAX_RATE = 100e18;

    // ── Errors ───────────────────────────────────────────────────────────

    error ZeroRate();
    error RateTooHigh(uint256 rate, uint256 max);
    error StaleRate(uint256 lastUpdate, uint256 maxStaleness);
    error MaxStalenessTooHigh(uint256 value, uint256 max);

    // ── Constructor ──────────────────────────────────────────────────────

    constructor(address owner_, uint256 initialRate_) Ownable(owner_) {
        if (initialRate_ == 0) revert ZeroRate();
        if (initialRate_ > MAX_RATE) revert RateTooHigh(initialRate_, MAX_RATE);
        rate = initialRate_;
        lastUpdateTimestamp = block.timestamp;
        maxStaleness = DEFAULT_MAX_STALENESS;
    }

    // ── Admin ────────────────────────────────────────────────────────────

    /**
     * @notice Set a new hurdle rate. Only callable by the owner.
     * @param newRate_ The new hurdle exchange rate in UD60x18
     *                 (e.g. 1.05e18 = 1.05 assets per share).
     */
    function setRate(uint256 newRate_) external onlyOwner {
        if (newRate_ == 0) revert ZeroRate();
        if (newRate_ > MAX_RATE) revert RateTooHigh(newRate_, MAX_RATE);
        uint256 oldRate = rate;
        rate = newRate_;
        lastUpdateTimestamp = block.timestamp;
        emit RateUpdated(oldRate, newRate_);
    }

    /**
     * @notice Update the staleness threshold. Only callable by the owner.
     * @param newMaxStaleness_ The new maximum age (in seconds) before
     *                         `getHurdleRate` reverts.
     */
    function setMaxStaleness(uint256 newMaxStaleness_) external onlyOwner {
        if (newMaxStaleness_ > DEFAULT_MAX_STALENESS) {
            revert MaxStalenessTooHigh(newMaxStaleness_, DEFAULT_MAX_STALENESS);
        }
        uint256 oldMaxStaleness = maxStaleness;
        maxStaleness = newMaxStaleness_;
        emit MaxStalenessUpdated(oldMaxStaleness, newMaxStaleness_);
    }

    // ── IHurdleRateOracle ────────────────────────────────────────────────

    /// @inheritdoc IHurdleRateOracle
    function precision() external pure override returns (uint256) {
        return _PRECISION;
    }

    /// @inheritdoc IHurdleRateOracle
    function getHurdleRate() external view override returns (uint256) {
        if (block.timestamp > lastUpdateTimestamp + maxStaleness) {
            revert StaleRate(lastUpdateTimestamp, maxStaleness);
        }
        return rate;
    }
}
