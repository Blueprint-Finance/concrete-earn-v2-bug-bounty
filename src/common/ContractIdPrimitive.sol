// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IContractId} from "../interface/IContractId.sol";

/// @title  ContractIdPrimitive
/// @notice Shared base that provides safe `IContractId.ID()` introspection via staticcall.
///         Returns `hasNoId = true` when the target does not implement `ID()` or returns
///         fewer than 32 bytes, instead of reverting.
abstract contract ContractIdPrimitive {
    /**
     * @dev Internal function to get the contract ID by calling the ID function.
     * @param contractAddress The contract address to query.
     * @return id      The contract ID, or 0 if unavailable.
     * @return hasNoId True if the ID function does not exist or returns insufficient data.
     */
    function _getIdOfContract(address contractAddress) internal view returns (uint64 id, bool hasNoId) {
        (bool success, bytes memory returnData) =
            contractAddress.staticcall(abi.encodeWithSelector(IContractId.ID.selector));

        if (success && returnData.length >= 32) {
            return (abi.decode(returnData, (uint64)), false);
        }
        return (0, true);
    }
}
