// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ITimelock} from "../../src/periphery/interface/ITimelock.sol";

/**
 * @title MockTimelock
 * @notice Minimal timelock for testing. Single flat delay for all actions.
 *         No tiers, no roles, no artifact registry.
 *
 *         Flow:
 *           1. Call {propose} with the target contract, selector, and args.
 *           2. Wait {DELAY} seconds (use vm.warp in tests).
 *           3. Call the gated function on the target — its {afterDelay} modifier
 *              calls {checkDelayExpired}, which validates and consumes the entry.
 */
contract MockTimelock is ITimelock {
    uint256 public constant DELAY = 1 days;

    /// @dev Whether the timelock is active. While false, {checkDelayExpired} is a no-op.
    bool public active;

    /// @dev actionId => readyAt timestamp (0 = not scheduled).
    mapping(bytes32 => uint256) public schedules;

    // ── Core functions ────────────────────────────────────────────────────────

    /// @notice Activates the timelock. After this, {checkDelayExpired} enforces delays.
    function activateTimelock() external override {
        active = true;
        emit TimelockActivated();
    }

    /**
     * @notice Schedules an action. Anyone can propose in this mock.
     * @dev actionId = keccak256(abi.encode(target, selector, args)) — symmetric
     *      with {checkDelayExpired} which uses msg.sender as target.
     */
    function propose(address target, bytes4 selector, bytes calldata args)
        external
        override
        returns (bytes32 actionId)
    {
        actionId = keccak256(abi.encode(target, selector, args));
        require(schedules[actionId] == 0, "MockTimelock: duplicate action");
        uint256 readyAt_ = block.timestamp + DELAY;
        schedules[actionId] = readyAt_;
        emit Proposed(actionId, target, bytes4(0), selector, bytes32(selector), args, bytes4(0), readyAt_);
    }

    /**
     * @notice Called by protected contracts via their {afterDelay} modifier.
     * @dev Recomputes actionId with msg.sender as target — must match {propose}.
     *      No-op while {active} is false.
     */
    function checkDelayExpired(bytes4 selector, bytes calldata args) external override {
        if (!active) return;
        bytes32 actionId = keccak256(abi.encode(msg.sender, selector, args));
        uint256 readyAt_ = schedules[actionId];
        require(readyAt_ != 0, "MockTimelock: unknown action");
        require(block.timestamp >= readyAt_, "MockTimelock: not ready");
        delete schedules[actionId];
        emit Consumed(actionId);
    }

    /// @notice Removes a scheduled action.
    function cancel(bytes32 actionId) external override {
        delete schedules[actionId];
        emit Canceled(actionId);
    }

    // ── Stubs (not needed for mock) ───────────────────────────────────────────

    function pruneStale(bytes32) external override {}
    function updateTierDelay(bytes4, uint256) external override {}
    function overrideTimelock(bytes32) external override {}
    function addArtifact(bytes4, bytes32, bytes4) external override {}
    function changeTier(bytes4, bytes32, bytes4) external override {}
    function bindContract(address, bytes4) external override {}
    function unbindContract(address) external override {}

    // ── Views ─────────────────────────────────────────────────────────────────

    function isActive() external view override returns (bool) {
        return active;
    }

    function readyAt(bytes32 actionId) external view override returns (uint256) {
        return schedules[actionId];
    }

    function tierDelay(bytes4) external pure override returns (uint256) {
        return DELAY;
    }

    function artifactDelayTier(bytes4, bytes32) external pure override returns (bytes4) {
        return bytes4(0);
    }

    function contractTypeOf(address) external pure override returns (bytes4) {
        return bytes4(0);
    }

    function computeActionId(address target, bytes4 selector, bytes calldata args)
        external
        pure
        override
        returns (bytes32)
    {
        return keccak256(abi.encode(target, selector, args));
    }
}
