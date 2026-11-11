// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ConcreteV2ConversionLib as ConversionLib} from "../lib/Conversion.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20_OZ_5_2_0_Lib} from "../lib/ERC20Lib.sol";
import {ERC4626_OZ_5_2_0_Lib} from "../lib/ERC4626Lib.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ConcreteAsyncVaultImplStorageLib} from "../lib/storage/ConcreteAsyncVaultImplStorageLib.sol";
import {IConcreteAsyncVaultImpl} from "../interface/IConcreteAsyncVaultImpl.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "../lib/storage/ConcreteCachedVaultStateStorageLib.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "../lib/storage/ConcreteStandardVaultImplStorageLib.sol";
import {StandardVaultHelperLib} from "../lib/StandardVaultHelperLib.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {IAsyncAccounting} from "../interface/IAsyncAccounting.sol";

struct ClaimWithdrawalParams {
    uint256 epochID;
    uint256 latestEpochID;
    uint256 epochPrice;
    bool isProcessed;
    uint256 totalAssetsSum;
}

library AsyncVaultHelperLib {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @dev Basis points constant (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10000;

    // ─────────────────────────────────────────────────────────────────────────────
    // Epoch Lifecycle Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function closeEpoch() public {
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();

        uint256 currentEpoch = $.latestEpochID;

        // Check if previous epoch is processed or if this is the first epoch
        require(
            currentEpoch == 1 || _epochProcessed(currentEpoch - 1),
            IConcreteAsyncVaultImpl.PreviousEpochNotProcessed(currentEpoch - 1)
        );

        // Increment to next epoch (safe to use unchecked as overflow is unrealistic)
        $.latestEpochID = currentEpoch + 1;

        emit IConcreteAsyncVaultImpl.EpochClosed(currentEpoch);
    }

    function processEpoch(uint256 lockedAssets_, uint8 decimals_) public {
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();
        CachedVaultStateLib.ConcreteCachedVaultStateStorage storage $c = CachedVaultStateLib.fetch();

        uint256 availableAssets = StandardVaultHelperLib.floatingAmount(lockedAssets_);
        uint256 sharePrice = ConversionLib.calcConvertToAssets(
            10 ** decimals_, ERC20_OZ_5_2_0_Lib.totalSupply(), $c.cachedTotalAssets, Math.Rounding.Floor, false
        );

        uint256 previousEpochID = $.latestEpochID - 1;
        // previous epoch should be not be processed
        require(
            !_epochProcessed(previousEpochID), IConcreteAsyncVaultImpl.PreviousEpochAlreadyProcessed(previousEpochID)
        );
        uint256 requestingShares = $.totalRequestedSharesPerEpoch[previousEpochID];
        uint256 assetsNeeded = 0;
        // add 1 to indicate that the epoch is processed (price cannot be 0)
        $.epochPricePerSharePlusOne[previousEpochID] = sharePrice + 1;

        if (requestingShares == 0) {
            require(availableAssets >= lockedAssets_, IConcreteStandardVaultImpl.InsufficientBalance());
        } else {
            assetsNeeded = requestingShares.mulDiv(sharePrice, 10 ** decimals_, Math.Rounding.Floor);

            require(availableAssets >= lockedAssets_ + assetsNeeded, IConcreteStandardVaultImpl.InsufficientBalance());
            ERC20_OZ_5_2_0_Lib._burn(address(this), requestingShares);

            // Update accounting
            $.pastEpochsUnclaimedAssets += assetsNeeded;
            CachedVaultStateLib.fetch().cachedTotalAssets -= assetsNeeded;
        }

        emit IConcreteAsyncVaultImpl.EpochProcessed(previousEpochID, requestingShares, assetsNeeded, sharePrice);
    }

    function claimWithdrawal(address user, uint256[] calldata epochIDs, uint8 decimals) public {
        require(user != address(0), IConcreteAsyncVaultImpl.ZeroAddress());
        require(epochIDs.length > 0, IConcreteAsyncVaultImpl.EmptyEpochIDs());
        claimWithdrawalTo(user, epochIDs, decimals, user);
    }

    function claimWithdrawalTo(address user, uint256[] calldata epochIDs, uint8 decimals, address recipient) public {
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();

        ClaimWithdrawalParams memory wwl;
        wwl.latestEpochID = $.latestEpochID;

        uint256 len = epochIDs.length;
        for (uint256 i = 0; i < len; i++) {
            wwl.epochID = epochIDs[i];
            (wwl.epochPrice, wwl.isProcessed) = _epochPriceAndProcessedFlag(wwl.epochID);
            if (!wwl.isProcessed) revert IConcreteAsyncVaultImpl.EpochNotProcessed(wwl.epochID);
            wwl.totalAssetsSum += getUserEpochRequestInAssets(
                user, wwl.epochID, wwl.latestEpochID, wwl.epochPrice, decimals
            );
            $.userEpochRequests[user][wwl.epochID] = 0;
        }

        require(wwl.totalAssetsSum > 0, IConcreteAsyncVaultImpl.NoClaimableRequest());

        // Update accounting
        $.pastEpochsUnclaimedAssets -= wwl.totalAssetsSum;

        require(recipient != address(0), IConcreteAsyncVaultImpl.ZeroAddress());

        // Transfer all assets at once
        IERC20(ERC4626_OZ_5_2_0_Lib.asset()).safeTransfer(recipient, wwl.totalAssetsSum);

        emit IConcreteAsyncVaultImpl.RequestClaimed(user, wwl.totalAssetsSum, epochIDs);
    }

    function claimUsersBatch(address[] calldata users, uint256 epochID, uint8 decimals) public {
        require(users.length > 0, IConcreteAsyncVaultImpl.EmptyUsers());
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();

        ClaimWithdrawalParams memory wwl;
        wwl.latestEpochID = $.latestEpochID;
        wwl.epochID = epochID;

        (wwl.epochPrice, wwl.isProcessed) = _epochPriceAndProcessedFlag(wwl.epochID);
        if (!wwl.isProcessed) revert IConcreteAsyncVaultImpl.EpochNotProcessed(wwl.epochID);

        wwl.latestEpochID = $.latestEpochID;
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = epochID;
        address user;
        uint256 assets;

        for (uint256 i = 0; i < users.length; i++) {
            user = users[i];
            assets = getUserEpochRequestInAssets(user, wwl.epochID, wwl.latestEpochID, wwl.epochPrice, decimals);
            if (assets == 0) continue;
            // accounting
            $.userEpochRequests[user][epochID] = 0;
            wwl.totalAssetsSum += assets;
            IERC20(ERC4626_OZ_5_2_0_Lib.asset()).safeTransfer(user, assets);

            emit IConcreteAsyncVaultImpl.RequestClaimed(user, assets, epochIDs);
        }

        require(wwl.totalAssetsSum > 0, IConcreteAsyncVaultImpl.NoClaimableRequest());

        // Update accounting
        $.pastEpochsUnclaimedAssets -= wwl.totalAssetsSum;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Lifecycle Interaction Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function moveRequestToNextEpoch(address user, uint256 fromEpochID, uint256 amount) public {
        require(user != address(0), IConcreteAsyncVaultImpl.ZeroAddress());
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();

        uint256 latestEpoch = $.latestEpochID;
        uint256 closedEpochID = latestEpoch - 1; // closed epoch is the previous epoch
        require(fromEpochID == closedEpochID, IConcreteAsyncVaultImpl.EpochMismatch(fromEpochID, closedEpochID));
        require(!_epochProcessed(closedEpochID), IConcreteAsyncVaultImpl.EpochAlreadyProcessed(closedEpochID));

        uint256 userBalance = $.userEpochRequests[user][closedEpochID];
        require(userBalance > 0, IConcreteAsyncVaultImpl.NoRequestingShares());

        uint256 sharesToMove = amount == type(uint256).max ? userBalance : amount;
        require(sharesToMove > 0, IConcreteAsyncVaultImpl.ZeroShares());
        require(sharesToMove <= userBalance, IConcreteStandardVaultImpl.InsufficientShares());

        $.userEpochRequests[user][closedEpochID] -= sharesToMove;
        $.userEpochRequests[user][latestEpoch] += sharesToMove;
        $.totalRequestedSharesPerEpoch[closedEpochID] -= sharesToMove;
        $.totalRequestedSharesPerEpoch[latestEpoch] += sharesToMove;

        emit IConcreteAsyncVaultImpl.RequestMovedToNextEpoch(user, sharesToMove, closedEpochID, latestEpoch);
    }

    function cancelRequest(address user, uint256 epochID) public {
        require(user != address(0), IConcreteAsyncVaultImpl.ZeroAddress());
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();

        require(!$.cancellationDisabled, IConcreteAsyncVaultImpl.CancellationDisabled());

        require(_epochIsOpen(epochID), IConcreteAsyncVaultImpl.EpochAlreadyClosed(epochID));

        uint256 requestingShares = $.userEpochRequests[user][epochID];
        require(requestingShares > 0, IConcreteAsyncVaultImpl.NoRequestingShares());

        // Clear the request
        $.userEpochRequests[user][epochID] = 0;
        $.totalRequestedSharesPerEpoch[epochID] -= requestingShares;

        // Return shares to user
        ERC20_OZ_5_2_0_Lib._transfer(address(this), user, requestingShares);

        emit IConcreteAsyncVaultImpl.RequestCancelled(user, requestingShares, epochID);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function getUserEpochRequestInAssets(
        address user,
        uint256 epochID,
        uint256 latestEpochID,
        uint256 epochPrice,
        uint8 decimals
    ) internal view returns (uint256 assets) {
        // Check if epoch is processed (has a price set)
        if (epochPrice == 0 || epochID >= latestEpochID) return 0;

        uint256 shares = ConcreteAsyncVaultImplStorageLib.fetch().userEpochRequests[user][epochID];
        if (shares == 0) return 0;

        assets = shares.mulDiv(epochPrice, 10 ** decimals, Math.Rounding.Floor);
    }

    function getEpochState(uint256 epochID) public view returns (IConcreteAsyncVaultImpl.EpochState) {
        uint256 latestEpochID = ConcreteAsyncVaultImplStorageLib.fetch().latestEpochID;
        if (epochID > latestEpochID) return IConcreteAsyncVaultImpl.EpochState.Inactive;
        if (epochID == latestEpochID) return IConcreteAsyncVaultImpl.EpochState.Active;
        bool isProcessed = _epochProcessed(epochID);
        if (isProcessed) return IConcreteAsyncVaultImpl.EpochState.Processed;
        return IConcreteAsyncVaultImpl.EpochState.Processing;
    }

    function totalRequestedSharesForCurrentEpochs()
        public
        view
        returns (uint256 activeShares, uint256 processingShares, uint256 processedShares)
    {
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();
        uint256 activeEpochID = $.latestEpochID;
        activeShares = $.totalRequestedSharesPerEpoch[activeEpochID];
        uint256 previousEpochID = activeEpochID - 1;
        uint256 sharesInPreviousEpoch = $.totalRequestedSharesPerEpoch[previousEpochID];
        if (_epochProcessed(previousEpochID)) {
            processedShares = sharesInPreviousEpoch;
        } else {
            processingShares = sharesInPreviousEpoch;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Auxiliary Functions
    // ─────────────────────────────────────────────────────────────────────────────

    function _epochProcessed(uint256 epochID) private view returns (bool isProcessed) {
        (, isProcessed) = _epochPriceAndProcessedFlag(epochID);
    }

    function _epochPriceAndProcessedFlag(uint256 epochID) private view returns (uint256 epochPrice, bool isProcessed) {
        uint256 epochPricePlusOne = ConcreteAsyncVaultImplStorageLib.fetch().epochPricePerSharePlusOne[epochID];
        isProcessed = epochPricePlusOne > 0;
        epochPrice = isProcessed ? epochPricePlusOne - 1 : 0;
    }

    function _epochIsOpen(uint256 epochID) private view returns (bool) {
        return epochID >= ConcreteAsyncVaultImplStorageLib.fetch().latestEpochID;
    }

    function _requireStrategyRegisteredAndActive(address strategy) private view {
        SVLib.ConcreteStandardVaultImplStorage storage $std = SVLib.fetch();
        require(EnumerableSet.contains($std.strategies, strategy), IConcreteStandardVaultImpl.StrategyDoesNotExist());
        require(
            $std.strategyData[strategy].status == IConcreteStandardVaultImpl.StrategyStatus.Active,
            IConcreteStandardVaultImpl.StrategyIsHalted()
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Vault-facing wrapper Functions (read vault state internally via DELEGATECALL)
    // ─────────────────────────────────────────────────────────────────────────────

    function processPartialEpochRequest(
        uint256 lockedAssets_,
        address user,
        uint256 epochID,
        uint256 amount,
        uint8 decimals_
    ) public {
        require(amount > 0, IConcreteAsyncVaultImpl.ZeroShares());
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();
        CachedVaultStateLib.ConcreteCachedVaultStateStorage storage $c = CachedVaultStateLib.fetch();
        uint256 availableAssets = StandardVaultHelperLib.floatingAmount(lockedAssets_);
        uint256 sharePrice = ConversionLib.calcConvertToAssets(
            10 ** decimals_, ERC20_OZ_5_2_0_Lib.totalSupply(), $c.cachedTotalAssets, Math.Rounding.Floor, false
        );

        uint256 closedEpochID = $.latestEpochID - 1; // closed epoch is the previous epoch
        require(epochID == closedEpochID, IConcreteAsyncVaultImpl.EpochMismatch(epochID, closedEpochID));
        require(!_epochProcessed(closedEpochID), IConcreteAsyncVaultImpl.EpochAlreadyProcessed(closedEpochID));
        require(user != address(0), IConcreteAsyncVaultImpl.ZeroAddress());

        uint256 userRequestedShares = $.userEpochRequests[user][epochID];
        require(userRequestedShares > 0, IConcreteAsyncVaultImpl.NoRequestingShares());

        uint256 shares = amount == type(uint256).max ? userRequestedShares : amount;
        require(shares <= userRequestedShares, IConcreteStandardVaultImpl.InsufficientShares());

        uint256 assets = shares.mulDiv(sharePrice, 10 ** decimals_, Math.Rounding.Floor);
        require(assets > 0, IConcreteStandardVaultImpl.InsufficientAssets());

        require(availableAssets >= lockedAssets_ + assets, IConcreteStandardVaultImpl.InsufficientBalance());

        $.userEpochRequests[user][epochID] -= shares;
        $.totalRequestedSharesPerEpoch[epochID] -= shares;

        $c.cachedTotalAssets -= assets;

        ERC20_OZ_5_2_0_Lib._burn(address(this), shares);

        IERC20(ERC4626_OZ_5_2_0_Lib.asset()).safeTransfer(user, assets);

        emit IConcreteAsyncVaultImpl.PartialEpochRequestProcessed(user, epochID, shares, assets);
    }

    function getUserEpochRequestInAssetsView(address user, uint256 epochID, uint8 decimals_)
        public
        view
        returns (uint256 assets)
    {
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();
        uint256 epochPricePlusOne = $.epochPricePerSharePlusOne[epochID];
        uint256 epochPrice = epochPricePlusOne == 0 ? 0 : epochPricePlusOne - 1;
        assets = getUserEpochRequestInAssets(user, epochID, $.latestEpochID, epochPrice, decimals_);
    }

    function toggleQueueActive() public {
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();
        bool newState = !$.isQueueActive;
        $.isQueueActive = newState;
        emit IConcreteAsyncVaultImpl.QueueActiveToggled(newState);
    }

    function executeQueuedWithdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        public
        returns (uint256)
    {
        require(shares > 0, IConcreteAsyncVaultImpl.ZeroShares());

        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();

        if (caller != owner) ERC20_OZ_5_2_0_Lib._spendAllowance(owner, caller, shares);

        // Bypass transfer hooks — this is an internal vault accounting operation, not a user transfer.
        ERC20_OZ_5_2_0_Lib._transfer(owner, address(this), shares);

        uint256 currentEpochID = $.latestEpochID;
        $.userEpochRequests[receiver][currentEpochID] += shares;
        $.totalRequestedSharesPerEpoch[currentEpochID] += shares;

        emit IConcreteAsyncVaultImpl.QueuedWithdrawal(caller, receiver, owner, assets, shares, currentEpochID);

        return assets;
    }

    function claimPriorityWithdrawal(
        address user,
        uint256 sharesToFulfil,
        uint256 unwindCost,
        uint256 lockedAssets,
        address strategy
    ) public {
        ConcreteAsyncVaultImplStorageLib.ConcreteAsyncVaultImplStorage storage $ =
            ConcreteAsyncVaultImplStorageLib.fetch();
        CachedVaultStateLib.ConcreteCachedVaultStateStorage storage $cached = CachedVaultStateLib.fetch();

        require(sharesToFulfil > 0, IConcreteAsyncVaultImpl.ZeroShares());
        require(user != address(0), IConcreteAsyncVaultImpl.ZeroAddress());
        require(
            sharesToFulfil <= $.userEpochRequests[user][$.latestEpochID],
            IConcreteStandardVaultImpl.InsufficientShares()
        );
        require(strategy != address(0), IConcreteAsyncVaultImpl.ZeroAddress());
        _requireStrategyRegisteredAndActive(strategy);

        // Calculate gross assets based on shares to fulfil and current exchange rate
        uint256 grossAssets = ConversionLib.calcConvertToAssets(
            sharesToFulfil, ERC20_OZ_5_2_0_Lib.totalSupply(), $cached.cachedTotalAssets, Math.Rounding.Floor, true
        );

        // Calculate maximum allowed unwind cost based on unwind cost cap
        uint256 maxUnwindCost = grossAssets.mulDiv($.unwindCostCapBP, BASIS_POINTS, Math.Rounding.Floor);
        require(unwindCost <= maxUnwindCost && unwindCost < grossAssets, IConcreteAsyncVaultImpl.UnwindCostTooHigh());

        uint256 netAssets = grossAssets - unwindCost;

        uint256 floatingFunds = StandardVaultHelperLib.floatingAmount(lockedAssets);
        uint256 availableAssets = floatingFunds > lockedAssets ? floatingFunds - lockedAssets : 0;
        require(availableAssets >= netAssets, IConcreteStandardVaultImpl.InsufficientBalance());

        // Update storage
        $.userEpochRequests[user][$.latestEpochID] -= sharesToFulfil;
        $.totalRequestedSharesPerEpoch[$.latestEpochID] -= sharesToFulfil;

        // Update cached total assets (subtract net assets sent out to user)
        $cached.cachedTotalAssets -= netAssets;

        // Burn the shares that are being fulfilled
        ERC20_OZ_5_2_0_Lib._burn(address(this), sharesToFulfil);

        // Adjust the strategy's reported allocation so the next yield accrual
        // reconciles the unwind cost without double-counting.
        // This also bumps the strategy's accounting nonce to prevent race
        // conditions with other accounting sources (e.g. operator adjustments).
        if (unwindCost > 0) {
            IAsyncAccounting(strategy).adjustTotalAssets(-int256(unwindCost));
        }

        // Transfer net assets to user
        IERC20(ERC4626_OZ_5_2_0_Lib.asset()).safeTransfer(user, netAssets);

        emit IConcreteAsyncVaultImpl.PriorityWithdrawalClaimed(
            user, sharesToFulfil, grossAssets, unwindCost, netAssets, $.latestEpochID
        );
    }
}
