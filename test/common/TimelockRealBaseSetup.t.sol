// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Timelock} from "../../src/periphery/timelock/Timelock.sol";
import {ITimelock} from "../../src/periphery/interface/ITimelock.sol";
import {TimelockContractTypesLib as CT} from "../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../src/periphery/lib/TimelockConfigurationLib.sol";

/**
 * @title TimelockRealBaseSetup
 * @notice Shared base for real-Timelock integration tests.
 *
 *         Deploys a real Timelock (UUPS proxy) and exposes helpers for the
 *         bootstrap sequence and the propose-warp pattern.
 *
 *         Bootstrap order (all no-ops re: delay until {timelock.activateTimelock}):
 *           1. protected contract sets the timelock address
 *           2. timelockAdmin binds the contract via {bindContract}
 *           3. protected contract activates enforcement
 *           4. timelockAdmin calls {timelock.activateTimelock}
 *
 *         After step 4 every {afterDelay}-gated call on a bound contract
 *         requires a matured {propose} entry.
 */
abstract contract TimelockRealBaseSetup is Test {
    Timelock public timelock;
    address public timelockAdmin;

    // ── Tier delay shorthands (mirrors TimelockConfigurationLib defaults) ─────

    uint256 internal constant TIER_1_DELAY = Config.TIER_1_DEFAULT; // 48 hours
    uint256 internal constant TIER_2_DELAY = Config.TIER_2_DEFAULT; // 24 hours
    uint256 internal constant TIER_3_DELAY = Config.TIER_3_DEFAULT; // 12 hours

    function _deployTimelock() internal {
        timelockAdmin = makeAddr("timelockAdmin");
        address impl = address(new Timelock());
        timelock = Timelock(address(new ERC1967Proxy(impl, abi.encodeCall(Timelock.initialize, (timelockAdmin)))));
    }

    /// @dev Bind a target contract to its type and flip both activation switches.
    ///      Must be called after the target already has the timelock address set.
    function _bindAndActivate(address target, bytes4 contractType) internal {
        vm.prank(timelockAdmin); // CONFIG_ROLE
        timelock.bindContract(target, contractType);
        vm.prank(timelockAdmin); // DEFAULT_ADMIN_ROLE
        timelock.activateTimelock();
    }

    /// @dev Propose an action as timelockAdmin (holds PROPOSER_ROLE) then warp past `delay`.
    function _proposeAndWarp(address target, bytes4 selector, bytes memory args, uint256 delay) internal {
        vm.prank(timelockAdmin);
        timelock.propose(target, selector, args);
        vm.warp(block.timestamp + delay + 1);
    }
}
