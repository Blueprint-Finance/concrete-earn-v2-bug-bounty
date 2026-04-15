// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @title IDefaultEnforcedVaultConfiguration
/// @notice Interface defining the default configuration enforced by the protocol
interface IDefaultEnforcedVaultConfiguration {
    struct DefaultEnforcedVaultConfiguration {
        /// @dev Default Management fee recipient enforced by the protocol
        address defaultManagementFeeRecipient;
        /// @dev Default Performance fee recipient enforced by the protocol
        address defaultPerformanceFeeRecipient;
    }
}

