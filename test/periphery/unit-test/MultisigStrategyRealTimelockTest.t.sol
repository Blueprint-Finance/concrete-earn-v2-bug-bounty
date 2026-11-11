// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TimelockRealBaseSetup} from "../../common/TimelockRealBaseSetup.t.sol";
import {MultisigStrategy} from "../../../src/periphery/strategies/MultisigStrategy.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {IAsyncAccounting} from "../../../src/interface/IAsyncAccounting.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {TimelockContractTypesLib as CT} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";
import {ERC20Mock} from "../../mock/ERC20Mock.sol";

// ── Minimal vault mock ────────────────────────────────────────────────────────

contract MockVault2 {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

// ── MultisigStrategyRealTimelockTest ──────────────────────────────────────────

contract MultisigStrategyRealTimelockTest is TimelockRealBaseSetup {
    MultisigStrategy public strategy;
    address public admin;
    address public multisig;

    function setUp() public {
        admin = makeAddr("admin");
        multisig = makeAddr("multisig");

        ERC20Mock asset = new ERC20Mock();
        MockVault2 vault = new MockVault2(address(asset));

        // Deploy strategy (no timelock yet)
        address impl = address(new MultisigStrategy());
        strategy = MultisigStrategy(
            address(
                new ERC1967Proxy(
                    impl,
                    abi.encodeCall(
                        MultisigStrategy.initialize,
                        (
                            admin,
                            address(vault),
                            multisig,
                            uint64(1000), // maxAccountingChangeThreshold (10%)
                            uint64(86400), // accountingValidityPeriod (1 day)
                            uint64(3600), // cooldownPeriod (1 hour)
                            address(0) // no timelock at deploy time
                        )
                    )
                )
            )
        );

        // Deploy real Timelock
        _deployTimelock();

        // Bootstrap sequence
        vm.prank(admin); // STRATEGY_ADMIN
        strategy.setTimelock(address(timelock));

        _bindAndActivate(address(strategy), CT.CT_STRATEGY);

        vm.prank(admin); // STRATEGY_ADMIN
        strategy.activateTimelock();
    }

    // ── Artifact registry ─────────────────────────────────────────────────────

    function testArtifactsRegistered() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_STRATEGY, bytes32(MultisigStrategy.setMultiSig.selector)), Config.TIER_1
        );
        assertEq(
            timelock.artifactDelayTier(
                CT.CT_STRATEGY, bytes32(IAsyncAccounting.setMaxAccountingChangeThreshold.selector)
            ),
            Config.TIER_2
        );
    }

    // ── TIER_1 — setMultiSig (48 h) ───────────────────────────────────────────

    function testTier1_setMultiSig_afterDelay() public {
        address newMultisig = makeAddr("newMultisig");
        _proposeAndWarp(address(strategy), MultisigStrategy.setMultiSig.selector, abi.encode(newMultisig), TIER_1_DELAY);

        // Step 1: timelocked propose only records the pending multi-sig
        vm.prank(admin);
        strategy.setMultiSig(newMultisig);
        assertEq(strategy.getPendingMultiSig(), newMultisig);

        // Step 2: pending multi-sig accepts (no timelock on acceptance)
        vm.prank(newMultisig);
        strategy.acceptMultiSig();

        assertEq(strategy.getMultiSig(), newMultisig);
    }

    function testTier1_setMultiSig_revertsBeforeDelay() public {
        address newMultisig = makeAddr("newMultisig");
        vm.prank(timelockAdmin);
        bytes32 actionId =
            timelock.propose(address(strategy), MultisigStrategy.setMultiSig.selector, abi.encode(newMultisig));

        // Warp to only TIER_2 delay — not enough for TIER_1
        vm.warp(block.timestamp + TIER_2_DELAY + 1);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        strategy.setMultiSig(newMultisig);
    }

    // ── TIER_2 — setMaxAccountingChangeThreshold (24 h) ──────────────────────

    function testTier2_setMaxAccountingChangeThreshold_afterDelay() public {
        uint64 newThreshold = 500; // 5%
        _proposeAndWarp(
            address(strategy),
            IAsyncAccounting.setMaxAccountingChangeThreshold.selector,
            abi.encode(newThreshold),
            TIER_2_DELAY
        );

        vm.prank(admin);
        strategy.setMaxAccountingChangeThreshold(newThreshold);

        assertEq(strategy.getMaxAccountingChangeThreshold(), newThreshold);
    }

    function testTier2_revertsWithoutProposal() public {
        bytes32 actionId = timelock.computeActionId(
            address(strategy), IAsyncAccounting.setMaxAccountingChangeThreshold.selector, abi.encode(uint64(500))
        );

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        strategy.setMaxAccountingChangeThreshold(500);
    }
}
