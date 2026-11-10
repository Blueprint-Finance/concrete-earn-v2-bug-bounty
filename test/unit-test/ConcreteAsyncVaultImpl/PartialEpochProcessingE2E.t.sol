// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy,
    IConcreteAsyncVaultImpl,
    ConcreteAsyncVaultImpl,
    ConcreteAsyncVaultImplBaseSetup
} from "../../common/ConcreteAsyncVaultImplBaseSetup.t.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {console2 as console} from "forge-std/Test.sol";

contract PartialEpochProcessingE2E is ConcreteAsyncVaultImplBaseSetup {
    address public user1;
    address public user2;
    address public user3;
    uint256 public constant TOTAL_AMOUNT = 2_000_000e18;
    uint256 public constant DEPOSIT_AMOUNT = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        asset.mint(user1, TOTAL_AMOUNT);
        asset.mint(user2, TOTAL_AMOUNT);
        asset.mint(user3, TOTAL_AMOUNT);

        vm.startPrank(user1);
        asset.approve(address(concreteAsyncVault), TOTAL_AMOUNT);
        concreteAsyncVault.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(concreteAsyncVault), TOTAL_AMOUNT);
        concreteAsyncVault.deposit(DEPOSIT_AMOUNT, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        asset.approve(address(concreteAsyncVault), TOTAL_AMOUNT);
        concreteAsyncVault.deposit(DEPOSIT_AMOUNT, user3);
        vm.stopPrank();
    }

    /// @notice Scenario 1: Partially process a single user's request (via move + fulfill),
    ///         then batch-settle the remaining users via processEpoch.
    ///
    ///  Steps:
    ///   - user1 requests 100k, user2 requests 200k, user3 requests 150k  (epoch 1)
    ///   - close epoch 1
    ///   - move 40k of user1's request to active epoch 2  (defer)
    ///   - processPartialEpochRequest(user1, epoch1, type(uint256).max) → fulfils remaining 60k, immediate transfer
    ///   - processEpoch() → batch-settles user2 (200k) and user3 (150k)
    ///   - user2 and user3 claim
    function test_PartialProcessSingleRequest_ThenBatchRemainder() public {
        uint256 user1Withdraw = 100_000e18;
        uint256 user2Withdraw = 200_000e18;
        uint256 user3Withdraw = 150_000e18;
        uint256 user1Defer = 40_000e18;
        uint256 user1Fulfilled = user1Withdraw - user1Defer;

        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(user1Withdraw, user1, user1);
        vm.prank(user2);
        concreteAsyncVault.redeem(user2Withdraw, user2, user2);
        vm.prank(user3);
        concreteAsyncVault.redeem(user3Withdraw, user3, user3);

        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), user1Withdraw + user2Withdraw + user3Withdraw);

        uint256 totalAssetsBefore = concreteAsyncVault.totalAssets();
        uint256 totalSupplyBefore = concreteAsyncVault.totalSupply();

        // --- Close epoch 1 ---
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        uint256 epoch2 = concreteAsyncVault.latestEpochID();
        assertEq(epoch2, epoch1 + 1);

        // --- Move 40k of user1's request to epoch 2 ---
        concreteAsyncVault.moveRequestToNextEpoch(user1, epoch1, user1Defer);
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), user1Fulfilled);
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch2), user1Defer);
        assertEq(
            concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), user1Fulfilled + user2Withdraw + user3Withdraw
        );

        // --- processPartialEpochRequest for user1 (fulfils remaining 60k) ---
        uint256 user1AssetsBefore = asset.balanceOf(user1);

        vm.expectEmit(true, true, true, true);
        emit IConcreteAsyncVaultImpl.PartialEpochRequestProcessed(user1, epoch1, user1Fulfilled, user1Fulfilled);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);

        assertEq(asset.balanceOf(user1), user1AssetsBefore + user1Fulfilled, "user1 received assets immediately");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), 0, "user1 epoch1 request zeroed");
        assertEq(
            concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1),
            user2Withdraw + user3Withdraw,
            "epoch1 total reduced"
        );

        // Exchange rate should be preserved (1:1 in this setup)
        uint256 rateAfterPartial = concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply();
        uint256 rateBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;
        assertEq(rateAfterPartial, rateBefore, "exchange rate preserved after partial");

        // --- processEpoch → batch-settle user2 and user3 ---
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        assertTrue(concreteAsyncVault.getEpochPricePerShare(epoch1) > 0, "epoch1 marked processed");
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), user2Withdraw + user3Withdraw);

        // --- user2 claims ---
        uint256 user2AssetsBefore = asset.balanceOf(user2);
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = epoch1;
        vm.prank(user2);
        concreteAsyncVault.claimWithdrawal(epochIDs);
        assertEq(asset.balanceOf(user2), user2AssetsBefore + user2Withdraw, "user2 claimed");

        // --- user3 claims ---
        uint256 user3AssetsBefore = asset.balanceOf(user3);
        vm.prank(user3);
        concreteAsyncVault.claimWithdrawal(epochIDs);
        assertEq(asset.balanceOf(user3), user3AssetsBefore + user3Withdraw, "user3 claimed");

        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0, "all claims settled");

        // user1 still has 40k deferred in epoch 2
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch2), user1Defer);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch2), user1Defer);
    }

    /// @notice Scenario 2: Move some requests to the next epoch, process one individually
    ///         via processPartialEpochRequest, then batch the remaining via processEpoch.
    ///
    ///  Steps:
    ///   - user1 requests 100k, user2 requests 200k, user3 requests 150k  (epoch 1)
    ///   - close epoch 1
    ///   - move user3's entire request to epoch 2
    ///   - processPartialEpochRequest(user1, epoch1, type(uint256).max) → fulfils user1 immediately
    ///   - processEpoch() → batch-settles user2's remaining request
    ///   - user2 claims
    ///   - user3's request is now in epoch 2 for the next cycle
    function test_MoveRequests_ProcessOneIndividually_BatchRest() public {
        uint256 user1Withdraw = 100_000e18;
        uint256 user2Withdraw = 200_000e18;
        uint256 user3Withdraw = 150_000e18;

        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(user1Withdraw, user1, user1);
        vm.prank(user2);
        concreteAsyncVault.redeem(user2Withdraw, user2, user2);
        vm.prank(user3);
        concreteAsyncVault.redeem(user3Withdraw, user3, user3);

        uint256 totalAssetsBefore = concreteAsyncVault.totalAssets();
        uint256 totalSupplyBefore = concreteAsyncVault.totalSupply();

        // --- Close epoch 1 ---
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        uint256 epoch2 = concreteAsyncVault.latestEpochID();

        // --- Move user3's entire request to epoch 2 ---
        concreteAsyncVault.moveRequestToNextEpoch(user3, epoch1, type(uint256).max);
        assertEq(concreteAsyncVault.getUserEpochRequest(user3, epoch1), 0);
        assertEq(concreteAsyncVault.getUserEpochRequest(user3, epoch2), user3Withdraw);
        assertEq(
            concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1),
            user1Withdraw + user2Withdraw,
            "epoch1 total after move"
        );

        // --- processPartialEpochRequest for user1 ---
        uint256 user1AssetsBefore = asset.balanceOf(user1);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        assertEq(asset.balanceOf(user1), user1AssetsBefore + user1Withdraw, "user1 received immediately");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), 0);

        // Exchange rate preserved
        uint256 rateAfter = concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply();
        uint256 rateBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;
        assertEq(rateAfter, rateBefore, "exchange rate preserved");

        // --- processEpoch → batch-settle user2 ---
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        assertTrue(concreteAsyncVault.getEpochPricePerShare(epoch1) > 0, "epoch1 processed");
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), user2Withdraw);

        // --- user2 claims ---
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = epoch1;
        uint256 user2AssetsBefore = asset.balanceOf(user2);
        vm.prank(user2);
        concreteAsyncVault.claimWithdrawal(epochIDs);
        assertEq(asset.balanceOf(user2), user2AssetsBefore + user2Withdraw, "user2 claimed");

        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0);

        // user3's request lives in epoch 2 for the next cycle
        assertEq(concreteAsyncVault.getUserEpochRequest(user3, epoch2), user3Withdraw);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch2), user3Withdraw);
    }

    /// @notice Scenario 3: Process some requests via partial processing, move all remaining
    ///         to the next epoch, call processEpoch on the now-empty closed epoch to mark it
    ///         as processed and advance, close the new epoch, and process it.
    ///
    ///  Steps:
    ///   - user1 requests 100k, user2 requests 200k, user3 requests 150k  (epoch 1)
    ///   - close epoch 1
    ///   - processPartialEpochRequest(user1, epoch1, type(uint256).max) → fulfils user1 immediately
    ///   - move user2 and user3 to epoch 2
    ///   - processEpoch() on epoch 1 (now empty) → marks it processed
    ///   - closeEpoch() → closes epoch 2 (possible now that epoch 1 is processed)
    ///   - processEpoch() → batch-settles user2 and user3 from epoch 2
    ///   - user2 and user3 claim from epoch 2
    function test_PartialProcess_MoveRemaining_AdvanceEpoch_CloseThenProcess() public {
        uint256 epoch1 = concreteAsyncVault.latestEpochID();

        vm.prank(user1);
        concreteAsyncVault.redeem(100_000e18, user1, user1);
        vm.prank(user2);
        concreteAsyncVault.redeem(200_000e18, user2, user2);
        vm.prank(user3);
        concreteAsyncVault.redeem(150_000e18, user3, user3);

        uint256 rateBefore = concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply();

        // --- Close epoch 1 ---
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        uint256 epoch2 = concreteAsyncVault.latestEpochID();
        assertEq(epoch2, epoch1 + 1);

        // --- processPartialEpochRequest for user1 ---
        uint256 user1BalBefore = asset.balanceOf(user1);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        assertEq(asset.balanceOf(user1), user1BalBefore + 100_000e18, "user1 received immediately");
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch1), 0);

        // --- Move user2 and user3 to epoch 2 ---
        concreteAsyncVault.moveRequestToNextEpoch(user2, epoch1, type(uint256).max);
        concreteAsyncVault.moveRequestToNextEpoch(user3, epoch1, type(uint256).max);

        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), 0, "epoch1 fully drained");
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch2), 350_000e18, "epoch2 has moved requests");

        // --- processEpoch on empty epoch 1 → marks it as processed ---
        concreteAsyncVault.processEpoch();
        assertTrue(concreteAsyncVault.getEpochPricePerShare(epoch1) > 0, "epoch1 processed (empty)");
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0, "no unclaimed assets for empty epoch");

        assertEq(
            concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply(),
            rateBefore,
            "exchange rate preserved through epoch advance"
        );

        // --- Close epoch 2 (now possible since epoch 1 is processed) ---
        concreteAsyncVault.closeEpoch();
        assertEq(concreteAsyncVault.latestEpochID(), epoch2 + 1);

        // --- processEpoch → batch-settle user2 and user3 from epoch 2 ---
        concreteAsyncVault.processEpoch();
        vm.stopPrank();

        assertTrue(concreteAsyncVault.getEpochPricePerShare(epoch2) > 0, "epoch2 processed");
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 350_000e18);

        // --- user2 and user3 claim from epoch 2 ---
        _claimAndAssert(user2, epoch2, 200_000e18);
        _claimAndAssert(user3, epoch2, 150_000e18);

        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0, "all claims settled");
        assertEq(concreteAsyncVault.totalAssets(), 3 * DEPOSIT_AMOUNT - 450_000e18, "final totalAssets");
        assertEq(concreteAsyncVault.totalSupply(), 3 * DEPOSIT_AMOUNT - 450_000e18, "final totalSupply");
    }

    /// @notice Scenario 4: Steady-state 3-day open / 3-day closed epoch cadence.
    ///
    ///  The operational pattern is:
    ///   - An epoch collects requests for 3 days (open).
    ///   - The epoch is closed. For the next 3 days the withdrawal manager can
    ///     migrate requests to the new open epoch or use processPartialEpochRequest.
    ///   - At the end of the closed period, processEpoch() and closeEpoch() are
    ///     bundled in a single batch — finalising the old epoch and starting the
    ///     next closed window.
    ///
    ///  Timeline simulated below (3 full cycles):
    ///
    ///  Day 0       Epoch 1 open
    ///  Day 1       user1 requests 50k
    ///  Day 2       user2 requests 80k
    ///  Day 3       closeEpoch()  → epoch 1 closed, epoch 2 opens
    ///  Day 4       user3 requests 60k into epoch 2; migrate 30k of user2 from epoch 1 → 2
    ///  Day 5       processPartialEpochRequest(user1, epoch1, type(uint256).max)
    ///  Day 6       processEpoch(epoch1) + closeEpoch()  → epoch 2 closed, epoch 3 opens
    ///              user2 claims residual from epoch 1
    ///  Day 7       user1 requests 40k into epoch 3
    ///  Day 9       processPartialEpochRequest(user3, epoch2, type(uint256).max)
    ///              migrate user2's 30k from epoch 2 → epoch 3
    ///  Day 12      processEpoch(epoch2) + closeEpoch()  → epoch 3 closed, epoch 4 opens
    ///  Day 13      processPartialEpochRequest(user1, epoch3, type(uint256).max)
    ///  Day 15      processEpoch(epoch3) + closeEpoch()  → epoch 4 opens
    ///              user2 claims from epoch 3
    function test_SteadyState_ThreeDayCadence() public {
        uint256 epoch1 = concreteAsyncVault.latestEpochID();
        uint256 startTime = block.timestamp;

        // ═══════════════════════════════════════════════════════════════
        // CYCLE 1 — epoch 1 open (days 0-3), closed (days 3-6)
        // ═══════════════════════════════════════════════════════════════

        // Day 1: user1 requests 50k
        vm.warp(startTime + 1 days);
        vm.prank(user1);
        concreteAsyncVault.redeem(50_000e18, user1, user1);

        // Day 2: user2 requests 80k
        vm.warp(startTime + 2 days);
        vm.prank(user2);
        concreteAsyncVault.redeem(80_000e18, user2, user2);

        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), 130_000e18);

        // Day 3: closeEpoch — epoch 1 closed, epoch 2 opens
        vm.warp(startTime + 3 days);
        vm.prank(withdrawalManager);
        concreteAsyncVault.closeEpoch();
        uint256 epoch2 = concreteAsyncVault.latestEpochID();

        // Day 4: user3 submits 60k into epoch 2; migrate 30k of user2 from epoch 1 → 2
        vm.warp(startTime + 4 days);
        vm.prank(user3);
        concreteAsyncVault.redeem(60_000e18, user3, user3);

        vm.prank(withdrawalManager);
        concreteAsyncVault.moveRequestToNextEpoch(user2, epoch1, 30_000e18);

        assertEq(concreteAsyncVault.getUserEpochRequest(user2, epoch1), 50_000e18, "user2 remaining in epoch1");
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, epoch2), 30_000e18, "user2 migrated to epoch2");
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), 100_000e18);
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch2), 90_000e18);

        // Day 5: processPartialEpochRequest for user1 (50k) — immediate transfer
        vm.warp(startTime + 5 days);
        uint256 user1Bal = asset.balanceOf(user1);
        vm.prank(withdrawalManager);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch1, type(uint256).max);
        assertEq(asset.balanceOf(user1), user1Bal + 50_000e18, "cycle1: user1 partial fulfilled");
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch1), 50_000e18);

        // Day 6: BOUNDARY — processEpoch(epoch1) + closeEpoch() bundled
        vm.warp(startTime + 6 days);
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.processEpoch();
        concreteAsyncVault.closeEpoch();
        vm.stopPrank();

        uint256 epoch3 = concreteAsyncVault.latestEpochID();
        assertTrue(concreteAsyncVault.getEpochPricePerShare(epoch1) > 0, "epoch1 processed");

        // user2 claims residual 50k from epoch 1
        _claimAndAssert(user2, epoch1, 50_000e18);

        // ═══════════════════════════════════════════════════════════════
        // CYCLE 2 — epoch 2 closed (days 6-12), epoch 3 open (days 6-12)
        // ═══════════════════════════════════════════════════════════════

        // Day 7: user1 requests 40k into epoch 3
        vm.warp(startTime + 7 days);
        vm.prank(user1);
        concreteAsyncVault.redeem(40_000e18, user1, user1);
        assertEq(concreteAsyncVault.getUserEpochRequest(user1, epoch3), 40_000e18);

        // Day 9: processPartialEpochRequest for user3 (60k) from epoch 2
        //         migrate user2's 30k from epoch 2 → epoch 3
        vm.warp(startTime + 9 days);
        vm.startPrank(withdrawalManager);

        uint256 user3Bal = asset.balanceOf(user3);
        concreteAsyncVault.processPartialEpochRequest(user3, epoch2, type(uint256).max);
        assertEq(asset.balanceOf(user3), user3Bal + 60_000e18, "cycle2: user3 partial fulfilled");

        concreteAsyncVault.moveRequestToNextEpoch(user2, epoch2, type(uint256).max);
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, epoch2), 0);
        assertEq(concreteAsyncVault.getUserEpochRequest(user2, epoch3), 30_000e18, "user2 migrated to epoch3");
        vm.stopPrank();

        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch2), 0, "epoch2 fully drained");
        assertEq(concreteAsyncVault.totalRequestedSharesPerEpoch(epoch3), 70_000e18);

        // Day 12: BOUNDARY — processEpoch(epoch2) + closeEpoch() bundled
        vm.warp(startTime + 12 days);
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.processEpoch();
        concreteAsyncVault.closeEpoch();
        vm.stopPrank();

        uint256 epoch4 = concreteAsyncVault.latestEpochID();
        assertTrue(concreteAsyncVault.getEpochPricePerShare(epoch2) > 0, "epoch2 processed");
        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0, "epoch2 was empty after draining");

        // ═══════════════════════════════════════════════════════════════
        // CYCLE 3 — epoch 3 closed (days 12-15), epoch 4 open
        // ═══════════════════════════════════════════════════════════════

        // Day 13: processPartialEpochRequest for user1 (40k) from epoch 3
        vm.warp(startTime + 13 days);
        user1Bal = asset.balanceOf(user1);
        vm.prank(withdrawalManager);
        concreteAsyncVault.processPartialEpochRequest(user1, epoch3, type(uint256).max);
        assertEq(asset.balanceOf(user1), user1Bal + 40_000e18, "cycle3: user1 partial fulfilled");

        // Day 15: BOUNDARY — processEpoch(epoch3) + closeEpoch() bundled
        vm.warp(startTime + 15 days);
        vm.startPrank(withdrawalManager);
        concreteAsyncVault.processEpoch();
        concreteAsyncVault.closeEpoch();
        vm.stopPrank();

        assertTrue(concreteAsyncVault.getEpochPricePerShare(epoch3) > 0, "epoch3 processed");
        assertEq(concreteAsyncVault.latestEpochID(), epoch4 + 1, "advanced to epoch5");

        // user2 claims residual 30k from epoch 3
        _claimAndAssert(user2, epoch3, 30_000e18);

        assertEq(concreteAsyncVault.pastEpochsUnclaimedAssets(), 0, "all claims settled");

        // ═══════════════════════════════════════════════════════════════
        // Final accounting check
        // ═══════════════════════════════════════════════════════════════
        // user1: 50k (partial epoch1) + 40k (partial epoch3) = 90k
        // user2: 50k (claim epoch1)   + 30k (claim epoch3)   = 80k
        // user3: 60k (partial epoch2)                         = 60k
        uint256 totalWithdrawn = 230_000e18;
        assertEq(concreteAsyncVault.totalAssets(), 3 * DEPOSIT_AMOUNT - totalWithdrawn, "final totalAssets");
        assertEq(concreteAsyncVault.totalSupply(), 3 * DEPOSIT_AMOUNT - totalWithdrawn, "final totalSupply");

        // Exchange rate still 1:1
        assertEq(
            concreteAsyncVault.totalAssets() * 1e18 / concreteAsyncVault.totalSupply(), 1e18, "exchange rate 1:1 at end"
        );
    }

    function _claimAndAssert(address user, uint256 epochID, uint256 expectedAssets) internal {
        uint256[] memory epochIDs = new uint256[](1);
        epochIDs[0] = epochID;
        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        concreteAsyncVault.claimWithdrawal(epochIDs);
        assertEq(asset.balanceOf(user), balBefore + expectedAssets);
    }
}
