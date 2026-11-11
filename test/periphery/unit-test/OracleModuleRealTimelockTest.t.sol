// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";

import {TimelockRealBaseSetup} from "../../common/TimelockRealBaseSetup.t.sol";
import {OracleModule} from "../../../src/periphery/oracle/OracleModule.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {ITimelockProtected} from "../../../src/interface/ITimelockProtected.sol";
import {TimelockIntegrationLib} from "../../../src/lib/TimelockIntegrationLib.sol";
import {TimelockContractTypesLib as CT} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";
import {ChainlinkOracleMock} from "../../mock/ChainlinkOracleMock.sol";
import {ERC20DecimalsMock} from "../../mock/ERC20DecimalsMock.sol";

/**
 * @dev {OracleModule} behind a real {Timelock}: feed configuration and ownership transfers must
 *      flow through `propose → mature → execute`, while the restrictive {OracleModule-removeOracle}
 *      stays immediate.
 */
contract OracleModuleRealTimelockTest is TimelockRealBaseSetup {
    OracleModule public oracleModule;
    address public moduleOwner;

    ERC20DecimalsMock public token;
    ChainlinkOracleMock public feed;

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant ONE_USD = 10 ** uint256(FEED_DECIMALS);

    function setUp() public {
        moduleOwner = makeAddr("moduleOwner");

        oracleModule = new OracleModule(moduleOwner, FEED_DECIMALS);
        token = new ERC20DecimalsMock(18);
        feed = new ChainlinkOracleMock(FEED_DECIMALS, int256(ONE_USD));

        _deployTimelock();

        // Bootstrap: set the address, bind + activate the timelock, then activate enforcement on
        // the module itself (every `afterDelay` call is a no-op until the last step).
        vm.prank(moduleOwner);
        oracleModule.setTimelock(address(timelock));

        _bindAndActivate(address(oracleModule), CT.CT_ORACLE_MODULE);

        vm.prank(moduleOwner);
        oracleModule.activateTimelock();
    }

    // ── Artifact registry ─────────────────────────────────────────────────────

    function testArtifactsRegistered() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_ORACLE_MODULE, bytes32(OracleModule.setOracle.selector)),
            Config.TIER_2,
            "setOracle tier mismatch"
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_ORACLE_MODULE, bytes32(OracleModule.setSequencerOracle.selector)),
            Config.TIER_2,
            "setSequencerOracle tier mismatch"
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_ORACLE_MODULE, bytes32(OracleModule.transferOwnership.selector)),
            Config.TIER_2,
            "transferOwnership tier mismatch"
        );
        assertEq(
            timelock.artifactDelayTier(CT.CT_ORACLE_MODULE, bytes32(ITimelockProtected.setTimelock.selector)),
            Config.TIER_1,
            "setTimelock tier mismatch"
        );
    }

    function testRemoveOracleUnregistered() public view {
        // Restrictive correction: intentionally never routed through the timelock.
        assertEq(
            timelock.artifactDelayTier(CT.CT_ORACLE_MODULE, bytes32(OracleModule.removeOracle.selector)),
            bytes4(0),
            "removeOracle must be unregistered"
        );
    }

    function testBootstrapWiring() public view {
        (address tl, bool active) = oracleModule.getTimelock();
        assertEq(tl, address(timelock), "timelock address not stored");
        assertTrue(active, "enforcement not activated");
        assertEq(timelock.contractTypeOf(address(oracleModule)), CT.CT_ORACLE_MODULE, "module not bound as oracle type");
    }

    // ── TIER_2 — setOracle (24 h) ─────────────────────────────────────────────

    function testTier2_setOracle_afterDelay() public {
        _proposeAndWarp(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs(), TIER_2_DELAY);

        vm.prank(moduleOwner);
        _setOracle();

        (address storedFeed,,,,,) = oracleModule.oracleConfigs(address(token));
        assertEq(storedFeed, address(feed), "feed not configured");
        assertEq(oracleModule.getPrice(address(token)), ONE_USD, "price not readable after configuration");
    }

    function testSetOracle_revertsWithoutProposal() public {
        bytes32 actionId =
            timelock.computeActionId(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs());

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        _setOracle();
    }

    function testSetOracle_revertsBeforeDelayMatured() public {
        vm.prank(timelockAdmin);
        bytes32 actionId = timelock.propose(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs());

        // Warp only to TIER_3 — not enough for a TIER_2 artifact.
        vm.warp(block.timestamp + TIER_3_DELAY + 1);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        _setOracle();
    }

    function testSetOracle_revertsWhenArgsDifferFromProposal() public {
        // The schedule entry is bound to the exact calldata: swapping the feed for a different one
        // resolves to a different actionId, so the matured proposal cannot be reused.
        _proposeAndWarp(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs(), TIER_2_DELAY);

        ChainlinkOracleMock otherFeed = new ChainlinkOracleMock(FEED_DECIMALS, int256(2 * ONE_USD));
        bytes memory tamperedArgs =
            abi.encode(address(token), address(otherFeed), uint64(0), uint64(0), uint64(7 days), false, true);
        bytes32 actionId =
            timelock.computeActionId(address(oracleModule), OracleModule.setOracle.selector, tamperedArgs);

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        oracleModule.setOracle(address(token), address(otherFeed), 0, 0, 7 days, false, true);
    }

    function testSetOracle_proposalIsSingleUse() public {
        _proposeAndWarp(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs(), TIER_2_DELAY);

        vm.prank(moduleOwner);
        _setOracle();

        bytes32 actionId =
            timelock.computeActionId(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs());

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        _setOracle();
    }

    function testSetOracle_revertsForNonOwner() public {
        // Ownership is checked before the timelock, so a matured proposal does not help a stranger.
        _proposeAndWarp(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs(), TIER_2_DELAY);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        _setOracle();
    }

    // ── removeOracle — immediate, no proposal ─────────────────────────────────

    function testRemoveOracle_immediate() public {
        _proposeAndWarp(address(oracleModule), OracleModule.setOracle.selector, _setOracleArgs(), TIER_2_DELAY);
        vm.prank(moduleOwner);
        _setOracle();

        vm.prank(moduleOwner);
        oracleModule.removeOracle(address(token));

        (address storedFeed,,,,,) = oracleModule.oracleConfigs(address(token));
        assertEq(storedFeed, address(0), "feed not cleared");
        // With the feed gone the module fails closed rather than serving a price.
        vm.expectRevert(OracleModule.InvalidOracle.selector);
        oracleModule.getPrice(address(token));
    }

    // ── TIER_2 — setSequencerOracle (24 h) ────────────────────────────────────

    function testTier2_setSequencerOracle_afterDelay() public {
        address sequencerFeed = address(new ChainlinkOracleMock(0, 0));
        bytes memory args = abi.encode(sequencerFeed, uint64(1 hours));
        _proposeAndWarp(address(oracleModule), OracleModule.setSequencerOracle.selector, args, TIER_2_DELAY);

        vm.prank(moduleOwner);
        oracleModule.setSequencerOracle(sequencerFeed, 1 hours);

        assertEq(oracleModule.sequencerOracle(), sequencerFeed, "sequencer feed not installed");
        assertEq(oracleModule.sequencerGracePeriod(), 1 hours, "grace period not stored");
    }

    function testSetSequencerOracle_revertsWithoutProposal() public {
        address sequencerFeed = address(new ChainlinkOracleMock(0, 0));
        bytes memory args = abi.encode(sequencerFeed, uint64(1 hours));
        bytes32 actionId =
            timelock.computeActionId(address(oracleModule), OracleModule.setSequencerOracle.selector, args);

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        oracleModule.setSequencerOracle(sequencerFeed, 1 hours);
    }

    function testClearingSequencerOracle_alsoRequiresProposal() public {
        // Removing the uptime gate widens what `getPrice` serves, so it is delayed like installing.
        bytes memory args = abi.encode(address(0), uint64(0));
        bytes32 actionId =
            timelock.computeActionId(address(oracleModule), OracleModule.setSequencerOracle.selector, args);

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        oracleModule.setSequencerOracle(address(0), 0);
    }

    // ── TIER_2 — transferOwnership (24 h) ─────────────────────────────────────

    function testTier2_transferOwnership_afterDelay() public {
        address newOwner = makeAddr("newOwner");
        _proposeAndWarp(
            address(oracleModule), OracleModule.transferOwnership.selector, abi.encode(newOwner), TIER_2_DELAY
        );

        vm.prank(moduleOwner);
        oracleModule.transferOwnership(newOwner);

        // Two-step: the matured proposal only nominates. Ownership has not moved yet.
        assertEq(oracleModule.pendingOwner(), newOwner, "pending owner not recorded");
        assertEq(oracleModule.owner(), moduleOwner, "ownership must not move before acceptance");
    }

    function testTier2_transferOwnership_completesOnlyOnAccept() public {
        address newOwner = makeAddr("newOwner");
        address unreachable = makeAddr("unreachable");

        // A mistyped nomination matures and executes, but strands nothing: the incumbent keeps the
        // owner-gated surface because `unreachable` never accepts.
        _proposeAndWarp(
            address(oracleModule), OracleModule.transferOwnership.selector, abi.encode(unreachable), TIER_2_DELAY
        );
        vm.prank(moduleOwner);
        oracleModule.transferOwnership(unreachable);

        vm.prank(moduleOwner);
        oracleModule.removeOracle(address(token)); // owner-gated, still callable

        // Nobody but the pending owner may accept.
        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moduleOwner));
        oracleModule.acceptOwnership();

        // Re-proposing supersedes the bad nomination; step three is the accept itself, untimelocked.
        _proposeAndWarp(
            address(oracleModule), OracleModule.transferOwnership.selector, abi.encode(newOwner), TIER_2_DELAY
        );
        vm.prank(moduleOwner);
        oracleModule.transferOwnership(newOwner);
        assertEq(oracleModule.pendingOwner(), newOwner, "nomination not superseded");

        vm.prank(newOwner);
        oracleModule.acceptOwnership();

        assertEq(oracleModule.owner(), newOwner, "ownership not transferred on accept");
        assertEq(oracleModule.pendingOwner(), address(0), "pending owner not cleared");
    }

    function testTransferOwnership_revertsWithoutProposal() public {
        address newOwner = makeAddr("newOwner");
        bytes32 actionId = timelock.computeActionId(
            address(oracleModule), OracleModule.transferOwnership.selector, abi.encode(newOwner)
        );

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        oracleModule.transferOwnership(newOwner);
    }

    function testTransferOwnership_revertsBeforeDelayMatured() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(timelockAdmin);
        bytes32 actionId =
            timelock.propose(address(oracleModule), OracleModule.transferOwnership.selector, abi.encode(newOwner));

        vm.warp(block.timestamp + TIER_3_DELAY + 1);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        oracleModule.transferOwnership(newOwner);
    }

    // ── renounceOwnership — permanently disabled ──────────────────────────────

    function testRenounceOwnership_alwaysRevertsForOwner() public {
        vm.prank(moduleOwner);
        vm.expectRevert(OracleModule.RenounceOwnershipDisabled.selector);
        oracleModule.renounceOwnership();
    }

    function testRenounceOwnership_revertsForNonOwner() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        oracleModule.renounceOwnership();
    }

    function testRenounceOwnership_notBypassableViaTimelock() public {
        // Even a matured proposal cannot enable it: the revert is unconditional.
        vm.prank(timelockAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITimelock.ArtifactNotRegistered.selector,
                CT.CT_ORACLE_MODULE,
                bytes32(OracleModule.renounceOwnership.selector)
            )
        );
        timelock.propose(address(oracleModule), OracleModule.renounceOwnership.selector, "");
    }

    // ── TIER_1 — setTimelock ──────────────────────────────────────────────────

    function testSetTimelock_revertsWithoutProposal() public {
        address otherTimelock = makeAddr("otherTimelock");
        bytes32 actionId = timelock.computeActionId(
            address(oracleModule), ITimelockProtected.setTimelock.selector, abi.encode(otherTimelock)
        );

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        oracleModule.setTimelock(otherTimelock);
    }

    function testTier1_setTimelock_requiresTier1Delay() public {
        // A TIER_2-length wait is not enough for the TIER_1 setTimelock artifact.
        address otherTimelock = makeAddr("otherTimelock");
        vm.prank(timelockAdmin);
        bytes32 actionId =
            timelock.propose(address(oracleModule), ITimelockProtected.setTimelock.selector, abi.encode(otherTimelock));

        vm.warp(block.timestamp + TIER_2_DELAY + 1);
        uint256 readyAt_ = timelock.readyAt(actionId);

        vm.prank(moduleOwner);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        oracleModule.setTimelock(otherTimelock);

        // NOTE: `TimelockIntegrationLib` has no `active` guard on `setTimelock`, so once the
        // TIER_1 delay matures the owner CAN repoint the module at another timelock. This mirrors
        // every other {ITimelockProtected} implementation in the repo.
        vm.warp(block.timestamp + TIER_1_DELAY);
        vm.prank(moduleOwner);
        oracleModule.setTimelock(otherTimelock);

        (address tl,) = oracleModule.getTimelock();
        assertEq(tl, otherTimelock, "timelock not repointed after the TIER_1 delay");
    }

    function testActivateTimelock_revertsWhenAlreadyActive() public {
        vm.prank(moduleOwner);
        vm.expectRevert(TimelockIntegrationLib.TimelockAlreadyActive.selector);
        oracleModule.activateTimelock();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Calldata tail of the canonical {OracleModule-setOracle} call under test.
    function _setOracleArgs() internal view returns (bytes memory) {
        return abi.encode(address(token), address(feed), uint64(0), uint64(0), uint64(7 days), false, true);
    }

    function _setOracle() internal {
        oracleModule.setOracle(address(token), address(feed), 0, 0, 7 days, false, true);
    }
}
