// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/// @title ILenderStaging
/// @notice Interface for staging collateral at the lender.
interface ILenderStaging {
    // stages collateral to be used for supply
    function stage(uint256 amount) external;

    // returns the amount of collateral that has been staged
    function staged() external view returns (uint256);

    // engages the staged collateral at the lender
    function engage(uint256 amount) external;

    // sends the staged collateral to either the vault or the admin.
    function send(uint256 amount) external;
}
