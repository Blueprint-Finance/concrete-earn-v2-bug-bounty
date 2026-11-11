// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title ITimelockProtected
 * @notice Shared surface implemented by every contract that integrates with
 *         the central {Timelock} via `TimelockIntegrationLib`
 *
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 */
interface ITimelockProtected {
    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when the timelock address is configured via {setTimelock}.
    event TimelockSet(address indexed timelock);

    /// @notice Emitted when timelock enforcement is irreversibly activated via {activateTimelock}.
    event TimelockActivated(address indexed timelock);

    // ── Functions ────────────────────────────────────────────────────────────

    /**
     * @notice Sets the Timelock contract address.
     * @dev Access-controlled by the implementing contract (owner or a
     *      configuration role). After {activateTimelock} the timelock
     *      address is permanently locked.
     * @param timelock_ Address of the Timelock contract.
     */
    function setTimelock(address timelock_) external;

    /**
     * @notice Irreversibly activates timelock enforcement on all
     *         {afterDelay}-gated functions.
     * @dev Once called, enforcement cannot be disabled and the timelock
     *      address cannot be changed.
     */
    function activateTimelock() external;

    /**
     * @notice Returns the configured timelock address and whether
     *         enforcement is active.
     * @return timelock_ The configured timelock address (`address(0)` if
     *         unset).
     * @return active_   True if timelock enforcement has been activated.
     */
    function getTimelock() external view returns (address timelock_, bool active_);
}
