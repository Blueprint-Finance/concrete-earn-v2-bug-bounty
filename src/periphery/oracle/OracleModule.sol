// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ITimelockProtected} from "../../interface/ITimelockProtected.sol";
import {TimelockIntegrationLib} from "../../lib/TimelockIntegrationLib.sol";

/**
 * @title IChainlinkOracle
 * @notice Interface for Chainlink price feed oracles
 * @dev Standard interface that all Chainlink price feeds implement
 */
interface IChainlinkOracle {
    /**
     * @notice Gets the latest round data from the price feed
     * @return roundId The round ID
     * @return answer The price answer
     * @return startedAt When the round started
     * @return updatedAt When the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @notice Gets the number of decimals used to get its user representation
     * @return The number of decimals
     */
    function decimals() external view returns (uint8);
}

/**
 * @title OracleModule
 * @notice A module for managing price oracles with validation capabilities
 * @dev This contract allows setting up Chainlink price feeds with configurable validation rules
 *      for price bounds and staleness checks. Every feed on one module must share both {decimals}
 *      (enforced) and the same quote currency (USD, ETH, … — operator invariant, not enforced).
 *      {OracleAssetPricer} divides two legs so that shared quote unit cancels; mixing quotes
 *      (e.g. USD-quoted and BTC-quoted) makes the ratio wrong by the missing FX rate.
 * @dev Integrates with the central {Timelock} via {TimelockIntegrationLib}:
 */
contract OracleModule is Ownable2Step, ITimelockProtected {
    /**
     * @notice Number of decimals expected for all oracle feeds on this module.
     * @dev Constructor-set and immutable. Typical Chainlink USD feeds use 8; do not mix 8- and
     *      18-decimal feeds on the same module.
     */
    uint8 public immutable decimals;

    /**
     * @notice Configuration structure for oracle settings
     * @param feed The address of the Chainlink price feed
     * @param minPrice Minimum valid price threshold (raw feed units)
     * @param maxPrice Maximum valid price threshold (raw feed units)
     * @param maxDelay Feed heartbeat plus inclusion buffer, in seconds
     * @param validateCaps Whether to validate price bounds
     * @param validateStaleness Whether to validate price staleness. Production configs should
     *        leave this true; false is allowed and skips the `maxDelay` check
     */
    struct OracleConfig {
        address feed;
        uint64 minPrice;
        uint64 maxPrice;
        uint64 maxDelay; // seconds
        bool validateCaps;
        bool validateStaleness;
    }

    /**
     * @notice Mapping from asset addresses to their oracle configurations
     */
    mapping(address => OracleConfig) public oracleConfigs;

    /**
     * @notice Optional L2 sequencer uptime feed. Zero address disables the check entirely,
     *         which is the correct configuration on L1.
     */
    address public sequencerOracle;

    /**
     * @notice Seconds that must elapse after the sequencer comes back up before {getPrice} serves
     *         a price again, giving feeds time to catch up on the backlog.
     * @dev Chainlink's documented value is 3600. Unused while {sequencerOracle} is zero. A zero
     *      grace period with a live feed is valid; {getPrice} still requires one second of elapsed
     *      uptime so `startedAt == block.timestamp` cannot sneak through.
     */
    uint64 public sequencerGracePeriod;

    /**
     * @notice Event emitted when an oracle is set for an asset
     * @param asset The asset address
     * @param feed The price feed address
     * @param minPrice Minimum price threshold
     * @param maxPrice Maximum price threshold
     * @param maxDelay Maximum delay allowed
     * @param validateCaps Whether `minPrice`/`maxPrice` are actually enforced on every {getPrice}
     * @param validateStaleness Whether `maxDelay` is actually enforced on every {getPrice}
     * @dev The two booleans are part of the event because the numeric fields are not zeroed when a
     *      check is disabled: without them, a config with the bound and staleness checks switched
     *      off is indistinguishable from a fully enforced one to an event-driven monitor.
     */
    event OracleSet(
        address indexed asset,
        address indexed feed,
        uint64 minPrice,
        uint64 maxPrice,
        uint64 maxDelay,
        bool validateCaps,
        bool validateStaleness
    );

    /**
     * @notice Event emitted when an oracle is removed for an asset
     * @param asset The asset address
     */
    event OracleRemoved(address indexed asset);

    /**
     * @notice Event emitted when the sequencer uptime feed is configured or cleared
     * @param sequencerOracle The uptime feed address (zero disables the check)
     * @param gracePeriod Seconds to wait after the sequencer recovers
     */
    event SequencerOracleSet(address indexed sequencerOracle, uint64 gracePeriod);

    error InvalidOracle();
    error InvalidAsset();
    error PriceOutOfBounds();
    error StalePrice();
    error InvalidPriceRange();
    error InvalidDelay();
    error InvalidDecimals();
    /// @notice Thrown by {renounceOwnership}, which is permanently disabled.
    error RenounceOwnershipDisabled();
    /// @notice Thrown by {getPrice} while the L2 sequencer uptime feed reports down.
    error SequencerDown();
    /// @notice Thrown by {getPrice} until {sequencerGracePeriod} has elapsed since the sequencer
    ///         came back up.
    error SequencerGracePeriodNotOver();
    /// @notice Thrown by {getPrice} and {setSequencerOracle} when the uptime feed reports a round
    ///         that cannot be interpreted (`startedAt == 0` or in the future).
    error InvalidSequencerRound();

    /// @dev Applied to privileged functions that require a prior {ITimelock.propose}
    ///      followed by the matured tier delay before they can execute.
    modifier afterDelay() {
        _enforceDelay();
        _;
    }

    /// @dev Validates and consumes the matured timelock schedule entry for the
    ///      calling function. No-op while timelock enforcement is not yet active.
    function _enforceDelay() internal {
        TimelockIntegrationLib.enforceDelay(msg.sig, msg.data[4:]);
    }

    /**
     * @notice Constructor for OracleModule
     * @param initialOwner_ The address that will be the owner of this contract
     * @param decimals_ The number of decimals expected for all oracle feeds on this module
     */
    constructor(address initialOwner_, uint8 decimals_) Ownable(initialOwner_) {
        decimals = decimals_;
    }

    /**
     * @notice Validates an oracle feed and returns the current price data
     * @dev Private function to avoid code duplication
     * @param feed_ The address of the Chainlink price feed
     * @param minPrice_ Minimum valid price threshold (optional, 0 to skip validation)
     * @param maxPrice_ Maximum valid price threshold (optional, 0 to skip validation)
     * @param maxDelay_ Maximum allowed delay in seconds (optional, 0 to skip validation)
     * @param validateCaps_ Whether to validate price bounds
     * @param validateStaleness_ Whether to validate price staleness
     * @return price The current price from the feed
     */
    function _validateOracleFeed(
        address feed_,
        uint64 minPrice_,
        uint64 maxPrice_,
        uint64 maxDelay_,
        bool validateCaps_,
        bool validateStaleness_
    ) private view returns (uint256 price) {
        if (feed_ == address(0)) revert InvalidOracle();

        IChainlinkOracle oracle = IChainlinkOracle(feed_);

        // Validate that the oracle has the expected number of decimals
        if (oracle.decimals() != decimals) revert InvalidDecimals();

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();

        if (answer <= 0 || updatedAt == 0) revert InvalidOracle();

        price = uint256(answer);

        // Validate that current price is within the specified range if enabled
        if (validateCaps_) {
            if (price < minPrice_ || price > maxPrice_) {
                revert PriceOutOfBounds();
            }
        }

        // Validate staleness if enabled
        if (validateStaleness_) {
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxDelay_) revert StalePrice();
        }
    }

    /**
     * @notice Sets up an oracle configuration for a specific asset
     * @dev Only callable by the contract owner, timelocked. Validates the live price
     *      against the new params at execution. Overwrites any existing config for `asset_`;
     *      {getPrice} keeps serving the previous config until this call executes.
     * @dev `feed_` must share this module's {decimals} (enforced) and the same quote currency as
     *      every other feed on the module (USD, ETH, …). The quote is not checked on-chain:
     *      mixing quotes makes {OracleAssetPricer} ratios wrong. Use the Chainlink proxy, not
     *      the underlying aggregator.
     *
     * @param asset_ The address of the asset to configure
     * @param feed_ The address of the Chainlink price-feed proxy
     * @param minPrice_ Minimum valid price in raw feed units. Together with `maxPrice_` this is
     *        the per-asset circuit breaker (Chainlink no longer uses aggregator minAnswer/maxAnswer)
     * @param maxPrice_ Maximum valid price in raw feed units
     * @param maxDelay_ Feed heartbeat plus a buffer for on-chain inclusion delay, looked up per
     *        feed per chain. Must be non-zero when `validateStaleness_` is true
     * @param validateCaps_ Whether to enforce `minPrice_`/`maxPrice_` on every {getPrice}
     * @param validateStaleness_ Whether to enforce `maxDelay_`. Defaults to true in production
     *        configs; passing false accepts a frozen feed until governance acts
     */
    function setOracle(
        address asset_,
        address feed_,
        uint64 minPrice_,
        uint64 maxPrice_,
        uint64 maxDelay_,
        bool validateCaps_,
        bool validateStaleness_
    ) external onlyOwner afterDelay {
        // Validate that asset is not zero address
        if (asset_ == address(0)) revert InvalidAsset();

        // Validate price range configuration if validation is enabled
        if (validateCaps_ && (maxPrice_ == 0 || minPrice_ >= maxPrice_)) revert InvalidPriceRange();

        // Validate delay configuration if staleness validation is enabled
        if (validateStaleness_ && maxDelay_ == 0) revert InvalidDelay();

        // Validate the oracle feed and get current price with range validation
        _validateOracleFeed(feed_, minPrice_, maxPrice_, maxDelay_, validateCaps_, validateStaleness_);

        oracleConfigs[asset_] = OracleConfig({
            feed: feed_,
            minPrice: minPrice_,
            maxPrice: maxPrice_,
            maxDelay: maxDelay_,
            validateCaps: validateCaps_,
            validateStaleness: validateStaleness_
        });

        emit OracleSet(asset_, feed_, minPrice_, maxPrice_, maxDelay_, validateCaps_, validateStaleness_);
    }

    /**
     * @notice Gets the current price for an asset with validation
     * @dev Validates price bounds and staleness if configured
     *
     * @param asset_ The address of the asset
     * @return price The current price of the asset
     */
    function getPrice(address asset_) external view returns (uint256 price) {
        // Validate that asset is not zero address
        if (asset_ == address(0)) revert InvalidAsset();

        // A down sequencer makes every feed on this chain untrustworthy, so fail before reading it
        if (sequencerOracle != address(0)) _checkSequencerUp();

        OracleConfig memory config = oracleConfigs[asset_];

        // Validate the oracle feed and get current price with all validations
        price = _validateOracleFeed(
            config.feed,
            config.minPrice,
            config.maxPrice,
            config.maxDelay,
            config.validateCaps,
            config.validateStaleness
        );
    }

    /**
     * @notice Removes oracle configuration for an asset
     * @dev Only callable by the contract owner. Intentionally NOT timelocked: dropping a feed is a
     *      restrictive correction that makes {getPrice} revert, so it must stay available as an
     *      immediate response to a compromised or misbehaving feed.
     *
     * @param asset_ The address of the asset to remove oracle for
     */
    function removeOracle(address asset_) external onlyOwner {
        delete oracleConfigs[asset_];
        emit OracleRemoved(asset_);
    }

    // ── Sequencer uptime feed ────────────────────────────────────────────────

    /**
     * @notice Configures the optional L2 sequencer uptime feed consulted by {getPrice}
     * @dev Only callable by the contract owner, timelocked. L1 leaves this unset
     *      (constructor default `address(0)`). Passing `address(0)` clears the feed and disables
     *      the check; that widens what {getPrice} will serve, so it uses the same delay as
     *      installing one. A non-zero address is probed via {IChainlinkOracle-latestRoundData} so
     *      a broken contract or a price feed (answer not in `{0, 1}`) cannot be installed. The
     *      sequencer is not required to be up, so a dead feed can still be replaced during an
     *      outage.
     *
     * @param sequencerOracle_ The uptime feed proxy, or `address(0)` to disable the check
     * @param gracePeriod_ Seconds to wait after the sequencer recovers before serving prices.
     *        Chainlink's documented value is 3600
     */
    function setSequencerOracle(address sequencerOracle_, uint64 gracePeriod_) external onlyOwner afterDelay {
        if (sequencerOracle_ != address(0)) _validateSequencerFeed(sequencerOracle_);

        sequencerOracle = sequencerOracle_;
        sequencerGracePeriod = gracePeriod_;

        emit SequencerOracleSet(sequencerOracle_, gracePeriod_);
    }

    /**
     * @dev Pings `sequencerOracle_` so a broken or non-uptime aggregator cannot be installed.
     *      Uptime feeds answer 0 (up) or 1 (down); anything else is a price feed or garbage.
     *      `startedAt` checks match {_checkSequencerUp}. Does not require the sequencer to be up
     *      and does not enforce {sequencerGracePeriod}.
     */
    function _validateSequencerFeed(address sequencerOracle_) private view {
        (, int256 answer, uint256 startedAt,,) = IChainlinkOracle(sequencerOracle_).latestRoundData();

        if (answer != 0 && answer != 1) revert InvalidOracle();
        if (startedAt == 0 || startedAt > block.timestamp) revert InvalidSequencerRound();
    }

    /**
     * @dev Reverts unless the sequencer is up and has been up for longer than
     *      {sequencerGracePeriod}. Uptime feeds answer 0 while the sequencer is up and 1 while it
     *      is down, and `startedAt` marks when that status last changed.
     */
    function _checkSequencerUp() private view {
        (, int256 answer, uint256 startedAt,,) = IChainlinkOracle(sequencerOracle).latestRoundData();

        if (answer != 0) revert SequencerDown();

        // `startedAt == 0` marks a round that has not been initialised; a future timestamp would
        // underflow the elapsed-time check below.
        if (startedAt == 0 || startedAt > block.timestamp) revert InvalidSequencerRound();

        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriodNotOver();
    }

    // ── Ownership ────────────────────────────────────────────────────────────

    /// @notice Gates ownership transfers behind the timelock, then hands off to the two-step flow.
    /// @dev Three gates in total: the transfer must be proposed on the {ITimelock} and mature
    ///      (`afterDelay`), executing it only records `newOwner` as {Ownable2Step-pendingOwner},
    ///      and ownership moves only once that address calls {Ownable2Step-acceptOwnership}. A
    ///      mistyped or unreachable `newOwner` therefore cannot strand {removeOracle} and the other
    ///      owner-gated functions — the incumbent stays owner until an accept lands.
    function transferOwnership(address newOwner) public override onlyOwner afterDelay {
        super.transferOwnership(newOwner);
    }

    /// @notice Permanently disabled — renouncing ownership is not permitted.
    /// @dev An ownerless module could never repoint or drop a compromised feed.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // ── Timelock admin ───────────────────────────────────────────────────────

    /// @inheritdoc ITimelockProtected
    /// @dev Only callable by the owner. Free during the bootstrap window (before
    ///      {activateTimelock}); afterwards it is gated behind the timelock, matching the
    ///      other {ITimelockProtected} implementations in this repo.
    function setTimelock(address timelock_) external onlyOwner afterDelay {
        TimelockIntegrationLib.setTimelock(timelock_);
        emit TimelockSet(timelock_);
    }

    /// @inheritdoc ITimelockProtected
    function activateTimelock() external onlyOwner {
        address tl = TimelockIntegrationLib.activateTimelock();
        emit TimelockActivated(tl);
    }

    /// @inheritdoc ITimelockProtected
    function getTimelock() external view returns (address timelock_, bool active_) {
        return TimelockIntegrationLib.state();
    }
}
