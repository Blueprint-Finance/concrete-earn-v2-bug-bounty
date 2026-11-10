// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

import {OracleModule} from "../../../src/periphery/oracle/OracleModule.sol";
import {ChainlinkOracleMock} from "../../mock/ChainlinkOracleMock.sol";
import {ERC20DecimalsMock} from "../../mock/ERC20DecimalsMock.sol";

/**
 * @dev {OracleModule} L2 sequencer uptime gate. The feed is optional: with none configured the
 *      module behaves exactly as before (the L1 case). Once configured, {OracleModule-getPrice}
 *      refuses to serve a price while the sequencer is down or still inside the grace period.
 *      {OracleModule-setSequencerOracle} probes a non-zero feed via `latestRoundData` and accepts
 *      `address(0)` to clear the gate.
 *
 *      The uptime feed is modelled with {ChainlinkOracleMock}, whose `latestRoundData` returns the
 *      settable timestamp as `startedAt`: answer 0 means up, 1 means down.
 */
contract OracleModuleSequencerTest is Test {
    OracleModule internal oracleModule;

    ERC20DecimalsMock internal token;
    ChainlinkOracleMock internal priceFeed;
    ChainlinkOracleMock internal sequencerFeed;

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant ONE_USD = 10 ** uint256(FEED_DECIMALS);
    uint64 internal constant GRACE_PERIOD = 1 hours;

    int256 internal constant SEQUENCER_UP = 0;
    int256 internal constant SEQUENCER_DOWN = 1;

    function setUp() public {
        // No timelock configured, so `afterDelay` is a no-op and the setters run immediately.
        oracleModule = new OracleModule(address(this), FEED_DECIMALS);

        token = new ERC20DecimalsMock(18);
        priceFeed = new ChainlinkOracleMock(FEED_DECIMALS, int256(ONE_USD));
        oracleModule.setOracle(address(token), address(priceFeed), 0, 0, 7 days, false, true);

        // Uptime feeds carry 0 decimals; the module never reads them for the sequencer.
        sequencerFeed = new ChainlinkOracleMock(0, SEQUENCER_UP);
    }

    // ── Optional by default ───────────────────────────────────────────────────

    function testNoSequencerConfiguredByDefault() public view {
        assertEq(oracleModule.sequencerOracle(), address(0), "sequencer feed should be unset");
        assertEq(oracleModule.sequencerGracePeriod(), 0, "grace period should be unset");
        assertEq(oracleModule.getPrice(address(token)), ONE_USD, "price unavailable without a sequencer feed");
    }

    function testDownSequencerIsIgnoredWhileUnconfigured() public {
        sequencerFeed.setAnswer(SEQUENCER_DOWN);
        // Never installed on the module, so it has no effect.
        assertEq(oracleModule.getPrice(address(token)), ONE_USD, "unconfigured feed still gated prices");
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    function testGetPriceWhenSequencerUpAndGracePeriodElapsed() public {
        _installSequencer();
        skip(GRACE_PERIOD + 1);

        assertEq(oracleModule.getPrice(address(token)), ONE_USD, "price gated while the sequencer is healthy");
    }

    // ── Sequencer down ────────────────────────────────────────────────────────

    function testGetPriceRevertsWhenSequencerDown() public {
        _installSequencer();
        skip(GRACE_PERIOD + 1);

        sequencerFeed.setAnswer(SEQUENCER_DOWN);

        vm.expectRevert(OracleModule.SequencerDown.selector);
        oracleModule.getPrice(address(token));
    }

    // ── Grace period ──────────────────────────────────────────────────────────

    function testGetPriceRevertsImmediatelyAfterRecovery() public {
        _installSequencer();
        skip(GRACE_PERIOD + 1);

        // Down, then back up: `startedAt` is re-stamped to now, restarting the grace period.
        sequencerFeed.setAnswer(SEQUENCER_DOWN);
        skip(10 minutes);
        sequencerFeed.setAnswer(SEQUENCER_UP);

        vm.expectRevert(OracleModule.SequencerGracePeriodNotOver.selector);
        oracleModule.getPrice(address(token));
    }

    function testGracePeriodBoundaryMustBeStrictlyExceeded() public {
        _installSequencer();
        uint256 startedAt = block.timestamp;

        // Exactly `GRACE_PERIOD` elapsed is still too early.
        vm.warp(startedAt + GRACE_PERIOD);
        vm.expectRevert(OracleModule.SequencerGracePeriodNotOver.selector);
        oracleModule.getPrice(address(token));

        // One second past it opens the gate.
        vm.warp(startedAt + GRACE_PERIOD + 1);
        assertEq(oracleModule.getPrice(address(token)), ONE_USD, "gate did not open one second past the grace period");
    }

    function testZeroGracePeriodStillRequiresOneSecond() public {
        oracleModule.setSequencerOracle(address(sequencerFeed), 0);

        // `startedAt == block.timestamp` means zero elapsed time, which does not exceed a zero
        // grace period.
        vm.expectRevert(OracleModule.SequencerGracePeriodNotOver.selector);
        oracleModule.getPrice(address(token));

        skip(1);
        assertEq(oracleModule.getPrice(address(token)), ONE_USD, "zero grace period should clear after one second");
    }

    // ── Malformed rounds ──────────────────────────────────────────────────────

    function testGetPriceRevertsOnUninitialisedRound() public {
        _installSequencer();
        skip(GRACE_PERIOD + 1);

        sequencerFeed.setUpdatedAt(0);

        vm.expectRevert(OracleModule.InvalidSequencerRound.selector);
        oracleModule.getPrice(address(token));
    }

    function testGetPriceRevertsOnFutureRound() public {
        _installSequencer();
        skip(GRACE_PERIOD + 1);

        sequencerFeed.setUpdatedAt(block.timestamp + 1);

        vm.expectRevert(OracleModule.InvalidSequencerRound.selector);
        oracleModule.getPrice(address(token));
    }

    // ── Setter validation ─────────────────────────────────────────────────────

    function testSetSequencerOracleClearsFeed() public {
        _installSequencer();
        skip(GRACE_PERIOD + 1);

        sequencerFeed.setAnswer(SEQUENCER_DOWN);
        vm.expectRevert(OracleModule.SequencerDown.selector);
        oracleModule.getPrice(address(token));

        oracleModule.setSequencerOracle(address(0), 0);

        assertEq(oracleModule.sequencerOracle(), address(0), "feed not cleared");
        assertEq(oracleModule.sequencerGracePeriod(), 0, "grace period not cleared");
        assertEq(oracleModule.getPrice(address(token)), ONE_USD, "cleared feed still gated prices");
    }

    function testSetSequencerOracleRevertsOnBrokenFeed() public {
        vm.expectRevert();
        oracleModule.setSequencerOracle(makeAddr("eoa"), GRACE_PERIOD);
    }

    function testSetSequencerOracleRevertsOnPriceFeed() public {
        vm.expectRevert(OracleModule.InvalidOracle.selector);
        oracleModule.setSequencerOracle(address(priceFeed), GRACE_PERIOD);
    }

    function testSetSequencerOracleRevertsOnUninitialisedRound() public {
        sequencerFeed.setUpdatedAt(0);

        vm.expectRevert(OracleModule.InvalidSequencerRound.selector);
        oracleModule.setSequencerOracle(address(sequencerFeed), GRACE_PERIOD);
    }

    function testSetSequencerOracleAllowsDownFeed() public {
        sequencerFeed.setAnswer(SEQUENCER_DOWN);

        oracleModule.setSequencerOracle(address(sequencerFeed), GRACE_PERIOD);

        assertEq(oracleModule.sequencerOracle(), address(sequencerFeed), "down feed should still be installable");
        vm.expectRevert(OracleModule.SequencerDown.selector);
        oracleModule.getPrice(address(token));
    }

    // ── Interaction with the rest of the module ───────────────────────────────

    function testSetOracleUnaffectedByDownSequencer() public {
        _installSequencer();
        sequencerFeed.setAnswer(SEQUENCER_DOWN);

        // Configuration reads the feed directly, not through `getPrice`, so it stays available.
        ERC20DecimalsMock otherToken = new ERC20DecimalsMock(6);
        oracleModule.setOracle(address(otherToken), address(priceFeed), 0, 0, 7 days, false, true);

        (address storedFeed,,,,,) = oracleModule.oracleConfigs(address(otherToken));
        assertEq(storedFeed, address(priceFeed), "a down sequencer blocked feed configuration");
    }

    function testZeroAssetIsRejectedBeforeSequencerCheck() public {
        _installSequencer();
        sequencerFeed.setAnswer(SEQUENCER_DOWN);

        vm.expectRevert(OracleModule.InvalidAsset.selector);
        oracleModule.getPrice(address(0));
    }

    // ── Setter ────────────────────────────────────────────────────────────────

    function testSetSequencerOracleStoresBothFields() public {
        oracleModule.setSequencerOracle(address(sequencerFeed), GRACE_PERIOD);

        assertEq(oracleModule.sequencerOracle(), address(sequencerFeed), "feed not stored");
        assertEq(oracleModule.sequencerGracePeriod(), GRACE_PERIOD, "grace period not stored");
    }

    function testSetSequencerOracleEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(oracleModule));
        emit OracleModule.SequencerOracleSet(address(sequencerFeed), GRACE_PERIOD);

        oracleModule.setSequencerOracle(address(sequencerFeed), GRACE_PERIOD);
    }

    function testSetSequencerOracleRevertsForNonOwner() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        oracleModule.setSequencerOracle(address(sequencerFeed), GRACE_PERIOD);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _installSequencer() internal {
        oracleModule.setSequencerOracle(address(sequencerFeed), GRACE_PERIOD);
    }
}
