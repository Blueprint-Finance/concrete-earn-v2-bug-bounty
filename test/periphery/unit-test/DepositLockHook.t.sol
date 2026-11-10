// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {HooksLibV2} from "../../../src/lib/Hooks.sol";
import {BaseHook} from "../../../src/periphery/hooks/BaseHook.sol";
import {DepositLockHook} from "../../../src/periphery/hooks/DepositLockHook.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";

contract DepositLockHookTest is ConcreteStandardVaultImplBaseSetup {
    address alice;
    DepositLockHook hook;
    uint64 constant INITIAL_DURATION = 1 days;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();
        alice = makeAddr("alice");
        asset.mint(alice, 100 ether);
        hook = _deployHook(hookManager, address(concreteStandardVault), INITIAL_DURATION);
    }

    /// @dev Deploys a locked implementation, clones it (ClonesWithImmutableArgs) and initializes the clone.
    function _deployHook(address owner_, address vault_, uint64 initialLockDuration_)
        internal
        returns (DepositLockHook h)
    {
        DepositLockHook impl = new DepositLockHook();
        // Immutable args mirror the factory layout: [factory (20)][vault (20)]. This test
        // contract acts as the factory authorized to initialize the clone.
        h = DepositLockHook(ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), vault_)));
        h.initialize(owner_, initialLockDuration_);
    }

    function _flagsDepositLock() internal pure returns (uint96) {
        return uint96(
            (1 << HooksLibV2.POST_DEPOSIT) | (1 << HooksLibV2.POST_MINT) | (1 << HooksLibV2.PRE_TRANSFER)
                | (1 << HooksLibV2.PRE_WITHDRAW) | (1 << HooksLibV2.PRE_REDEEM)
        );
    }

    function _setupHooks() internal {
        vm.prank(hookManager);
        concreteStandardVault.setHooks(Hooks({target: address(hook), flags: _flagsDepositLock()}));
    }

    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        concreteStandardVault.deposit(amount, user);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Core lock behaviour
    // ─────────────────────────────────────────────────────────────────────────────

    function test_deposit_emitsLockCreated() public {
        _setupHooks();

        vm.prank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);

        uint64 expectedUnlockTs = uint64(block.timestamp + INITIAL_DURATION);
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.LockCreated(alice, 10 ether, expectedUnlockTs, INITIAL_DURATION);

        vm.prank(alice);
        concreteStandardVault.deposit(10 ether, alice);
    }

    function test_lock_blocksTransfer_untilExpiry() public {
        _setupHooks();
        _depositAs(alice, 10 ether);

        assertEq(hook.storedTotalLocked(alice), 10 ether);
        assertEq(hook.effectiveTotalLocked(alice), 10 ether);
        assertEq(hook.getUnlockedShares(alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DepositLockHook.InsufficientUnlocked.selector, alice, 1 ether, 0));
        concreteStandardVault.transfer(makeAddr("bob"), 1 ether);

        vm.warp(block.timestamp + INITIAL_DURATION);

        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), 1 ether);
    }

    function test_redeemUsesPreviewWithdrawConsistency() public {
        _setupHooks();
        _depositAs(alice, 10 ether);

        uint256 assetsOut = 1 ether;
        uint256 sharesNeeded = concreteStandardVault.previewWithdraw(assetsOut);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DepositLockHook.InsufficientUnlocked.selector, alice, sharesNeeded, 0));
        concreteStandardVault.withdraw(assetsOut, alice, alice);
    }

    function test_newDuration_appliesOnlyToSubsequentLocks() public {
        _setupHooks();
        _depositAs(alice, 5 ether);

        uint64 firstUnlock = hook.getStoredLock(alice, 0).unlockTimestamp;

        vm.prank(hookManager);
        hook.setDepositLockDuration(7 days);

        vm.startPrank(alice);
        concreteStandardVault.deposit(5 ether, alice);
        vm.stopPrank();

        uint64 secondUnlock = hook.getStoredLock(alice, 1).unlockTimestamp;
        assertEq(secondUnlock - firstUnlock, 6 days);
        assertEq(hook.getStoredLock(alice, 1).duration, 7 days);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Duration decrease: out-of-order timestamps handled correctly
    // ─────────────────────────────────────────────────────────────────────────────

    function test_durationDecrease_shortLockExpiresBeforeLongLock() public {
        _setupHooks();

        // Lock 1: duration=1 day, 5 ether → unlockTs = T + 1 day
        _depositAs(alice, 5 ether);
        uint64 lock1Unlock = hook.getStoredLock(alice, 0).unlockTimestamp;

        // Reduce duration drastically
        vm.prank(hookManager);
        hook.setDepositLockDuration(1 hours);

        vm.warp(block.timestamp + 1);

        // Lock 2: duration=1 hour, 3 ether → unlockTs = T + 1s + 1h (earlier than lock 1)
        // Sorted insertion places lock 2 at index 0 (earlier unlockTimestamp).
        _depositAs(alice, 3 ether);
        uint64 lock2Unlock = hook.getStoredLock(alice, 0).unlockTimestamp;
        assertLt(lock2Unlock, lock1Unlock, "lock2 should expire before lock1");

        // Warp past lock 2 but before lock 1
        vm.warp(uint256(lock2Unlock) + 1);

        // Lock 2 (3 ether) expired, lock 1 (5 ether) still active
        assertEq(hook.effectiveTotalLocked(alice), 5 ether, "only lock1 should remain locked");
        assertEq(hook.effectiveLockCount(alice), 1);
        assertEq(hook.getUnlockedShares(alice), 3 ether, "lock2 shares should be unlocked");

        // Can transfer the 3 unlocked ether
        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), 3 ether);

        // After cleanup, only lock 1 remains
        assertEq(hook.storedLockCount(alice), 1);
        assertEq(hook.storedTotalLocked(alice), 5 ether);

        // Cannot transfer lock 1's shares yet
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DepositLockHook.InsufficientUnlocked.selector, alice, 1 ether, 0));
        concreteStandardVault.transfer(makeAddr("bob"), 1 ether);

        // Warp past lock 1
        vm.warp(uint256(lock1Unlock) + 1);
        assertEq(hook.effectiveTotalLocked(alice), 0);

        uint256 aliceShares = concreteStandardVault.balanceOf(alice);
        vm.prank(alice);
        concreteStandardVault.redeem(aliceShares, alice, alice);
    }

    function test_durationDecrease_multipleOutOfOrderLocks() public {
        _setupHooks();

        // Lock 1: 1 day duration, 5 ether
        _depositAs(alice, 5 ether);

        vm.warp(block.timestamp + 2 hours);

        // Lock 2: 1 day duration, 3 ether (2h later)
        _depositAs(alice, 3 ether);

        // Reduce to 10 seconds
        vm.prank(hookManager);
        hook.setDepositLockDuration(10 seconds);

        vm.warp(block.timestamp + 1);

        // Lock 3: 10s duration, 4 ether
        _depositAs(alice, 4 ether);

        vm.warp(block.timestamp + 1);

        // Lock 4: 10s duration, 2 ether
        _depositAs(alice, 2 ether);

        // Reduce to 0
        vm.prank(hookManager);
        hook.setDepositLockDuration(0);

        vm.warp(block.timestamp + 1);

        // duration=0 → no lock created, shares immediately free
        _depositAs(alice, 1 ether);

        assertEq(hook.storedLockCount(alice), 4);
        assertEq(hook.storedTotalLocked(alice), 14 ether);

        // Warp 15 seconds — locks 3, 4 expire; locks 1, 2 still active (lock 5 was never created)
        vm.warp(block.timestamp + 15 seconds);

        assertEq(hook.effectiveTotalLocked(alice), 8 ether, "locks 1+2 still active");
        assertEq(hook.effectiveLockCount(alice), 2);
        assertEq(hook.getUnlockedShares(alice), 7 ether, "locks 3+4 expired + 1 ether never locked");

        // Trigger cleanup via transfer of unlocked shares
        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), 7 ether);

        assertEq(hook.storedLockCount(alice), 2, "only 2 locks remain post-compact");
        assertEq(hook.storedTotalLocked(alice), 8 ether);

        // Warp past all locks
        vm.warp(block.timestamp + INITIAL_DURATION);
        assertEq(hook.effectiveTotalLocked(alice), 0);

        uint256 aliceRemaining = concreteStandardVault.balanceOf(alice);
        vm.prank(alice);
        concreteStandardVault.redeem(aliceRemaining, alice, alice);
    }

    function testFuzz_durationDecrease_compactionPreservesInvariant(
        uint64 longDuration,
        uint64 shortDuration,
        uint8 depositsBeforeChange,
        uint8 depositsAfterChange,
        uint64 warpAfter
    ) public {
        longDuration = uint64(bound(longDuration, 1 hours, 30 days));
        shortDuration = uint64(bound(shortDuration, 1, longDuration - 1));
        depositsBeforeChange = uint8(bound(depositsBeforeChange, 1, 10));
        depositsAfterChange = uint8(bound(depositsAfterChange, 1, 10));
        warpAfter = uint64(bound(warpAfter, 0, 60 days));

        vm.startPrank(hookManager);
        hook.setDepositLockDuration(longDuration);
        hook.setMaxLocksPerUser(25);
        vm.stopPrank();
        _setupHooks();

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        for (uint256 i; i < depositsBeforeChange; i++) {
            if (asset.balanceOf(alice) < 1 ether) break;
            concreteStandardVault.deposit(1 ether, alice);
            vm.warp(block.timestamp + 1);
        }
        vm.stopPrank();

        vm.prank(hookManager);
        hook.setDepositLockDuration(shortDuration);

        vm.startPrank(alice);
        for (uint256 i; i < depositsAfterChange; i++) {
            if (asset.balanceOf(alice) < 1 ether) break;
            concreteStandardVault.deposit(1 ether, alice);
            vm.warp(block.timestamp + 1);
        }
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfter);

        uint256 effectiveLocked = hook.effectiveTotalLocked(alice);
        uint256 effectiveCount = hook.effectiveLockCount(alice);

        // Trigger cleanup with a new deposit (restore a non-zero duration so a lock is created)
        vm.prank(hookManager);
        hook.setDepositLockDuration(longDuration);

        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        concreteStandardVault.deposit(1 ether, alice);
        vm.stopPrank();

        assertEq(hook.storedTotalLocked(alice), effectiveLocked + 1 ether, "totalLocked mismatch");
        assertEq(hook.storedLockCount(alice), effectiveCount + 1, "lockCount mismatch");
        assertLe(hook.storedTotalLocked(alice), concreteStandardVault.balanceOf(alice), "locked > balance");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario 1: received shares via transfer are fully movable
    // ─────────────────────────────────────────────────────────────────────────────

    function test_receivedSharesAreUnlocked() public {
        address charlie = makeAddr("charlie");
        asset.mint(charlie, 10 ether);

        _setupHooks();
        _depositAs(charlie, 10 ether);

        vm.warp(block.timestamp + INITIAL_DURATION);
        _depositAs(alice, 10 ether);

        vm.prank(charlie);
        concreteStandardVault.transfer(alice, 10 ether);

        assertEq(hook.getUnlockedShares(alice), 10 ether);
    }

    function test_receivedShares_canTransferAndRedeem() public {
        address charlie = makeAddr("charlie");
        address dave = makeAddr("dave");
        asset.mint(charlie, 20 ether);

        _setupHooks();
        _depositAs(charlie, 20 ether);

        vm.warp(block.timestamp + INITIAL_DURATION);

        vm.prank(charlie);
        concreteStandardVault.transfer(alice, 20 ether);

        assertEq(hook.storedTotalLocked(alice), 0);
        assertEq(hook.getUnlockedShares(alice), 20 ether);

        vm.prank(alice);
        concreteStandardVault.transfer(dave, 5 ether);
        assertEq(concreteStandardVault.balanceOf(dave), 5 ether);

        vm.prank(alice);
        concreteStandardVault.redeem(10 ether, alice, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 5 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario 2: multiple expired locks are cleaned, user can transfer and redeem
    // ─────────────────────────────────────────────────────────────────────────────

    function test_multipleExpiredLocks_canTransferAndRedeem() public {
        _setupHooks();
        _depositAs(alice, 10 ether);

        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(alice);
        concreteStandardVault.deposit(15 ether, alice);
        vm.stopPrank();

        assertEq(hook.storedLockCount(alice), 2);
        assertEq(hook.storedTotalLocked(alice), 25 ether);
        assertEq(hook.effectiveTotalLocked(alice), 25 ether);

        vm.warp(block.timestamp + INITIAL_DURATION);
        assertEq(hook.getUnlockedShares(alice), 25 ether);
        assertEq(hook.effectiveTotalLocked(alice), 0);
        assertEq(hook.effectiveLockCount(alice), 0);

        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), 10 ether);

        assertEq(hook.storedLockCount(alice), 0);
        assertEq(hook.storedTotalLocked(alice), 0);

        vm.prank(alice);
        concreteStandardVault.redeem(15 ether, alice, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario 3: totalLocked never exceeds balanceOf
    // ─────────────────────────────────────────────────────────────────────────────

    function test_invariant_totalLockedNeverExceedsBalance() public {
        address bob = makeAddr("bob");
        asset.mint(bob, 50 ether);

        _setupHooks();

        _depositAs(alice, 30 ether);
        _assertLockedLeBalance(alice);

        _depositAs(bob, 50 ether);
        _assertLockedLeBalance(bob);

        vm.warp(block.timestamp + INITIAL_DURATION);

        vm.prank(bob);
        concreteStandardVault.transfer(alice, 20 ether);
        _assertLockedLeBalance(alice);
        _assertLockedLeBalance(bob);

        vm.prank(alice);
        concreteStandardVault.redeem(20 ether, alice, alice);
        _assertLockedLeBalance(alice);

        vm.warp(block.timestamp + INITIAL_DURATION);

        uint256 aliceShares = concreteStandardVault.balanceOf(alice);
        vm.prank(alice);
        concreteStandardVault.redeem(aliceShares, alice, alice);
        _assertLockedLeBalance(alice);
        assertEq(concreteStandardVault.balanceOf(alice), 0);
        assertEq(hook.storedTotalLocked(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Compaction: array length stays bounded with overlapping locks
    // ─────────────────────────────────────────────────────────────────────────────

    function test_compaction_arrayLengthBoundedWithOverlappingLocks() public {
        _setupHooks();

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        concreteStandardVault.deposit(10 ether, alice);
        vm.warp(block.timestamp + 6 hours);
        concreteStandardVault.deposit(10 ether, alice);
        vm.warp(block.timestamp + 6 hours);
        concreteStandardVault.deposit(10 ether, alice);
        vm.stopPrank();

        assertEq(hook.storedLockCount(alice), 3);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(alice);
        concreteStandardVault.deposit(10 ether, alice);

        assertEq(hook.storedLockCount(alice), 3);
        assertEq(hook.effectiveLockCount(alice), 3);
        assertEq(hook.storedTotalLocked(alice), 30 ether);

        vm.warp(block.timestamp + INITIAL_DURATION);

        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), 1 ether);
        assertEq(hook.storedLockCount(alice), 0);
        assertEq(hook.storedTotalLocked(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fuzz: compaction preserves totalLocked and active count
    // ─────────────────────────────────────────────────────────────────────────────

    function testFuzz_compaction_preservesInvariant(uint8 depositCount, uint64 timeBetween, uint64 warpAfter) public {
        depositCount = uint8(bound(depositCount, 1, 20));
        timeBetween = uint64(bound(timeBetween, 0, 2 days));
        warpAfter = uint64(bound(warpAfter, 0, 3 days));

        _setupHooks();
        vm.prank(hookManager);
        hook.setMaxLocksPerUser(25);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);

        uint256 depositAmount = 1 ether;
        for (uint256 i = 0; i < depositCount; i++) {
            if (asset.balanceOf(alice) < depositAmount) break;
            concreteStandardVault.deposit(depositAmount, alice);
            if (timeBetween > 0) vm.warp(block.timestamp + timeBetween);
        }
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfter);

        uint256 effectiveLockedBefore = _viewEffectiveLocked(alice);
        uint256 effectiveCountBefore = hook.effectiveLockCount(alice);

        // Trigger cleanup via a new deposit (1 ether). This runs _cleanupExpired then appends one lock.
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        concreteStandardVault.deposit(1 ether, alice);
        vm.stopPrank();

        uint256 storedAfter = hook.storedLockCount(alice);
        uint256 lockedAfter = hook.storedTotalLocked(alice);

        assertEq(lockedAfter, effectiveLockedBefore + 1 ether, "totalLocked mismatch after compaction");
        assertEq(storedAfter, effectiveCountBefore + 1, "storedLockCount mismatch after compaction");
        assertLe(lockedAfter, concreteStandardVault.balanceOf(alice), "locked > balance");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────────────

    function test_init_VAULT_readsImmutableArg() public {
        address specificVault = makeAddr("specificVault");
        DepositLockHook newHook = _deployHook(hookManager, specificVault, INITIAL_DURATION);
        assertEq(address(newHook.VAULT()), specificVault);
    }

    function test_init_setsInitialState() public {
        assertEq(address(hook.VAULT()), address(concreteStandardVault));
        assertEq(hook.depositLockDuration(), INITIAL_DURATION);
        assertEq(hook.owner(), hookManager);
        assertEq(hook.maxLocksPerUser(), 10);
        assertEq(hook.hookContainer(), address(0));
    }

    function test_init_revertsWhenCallerNotFactory() public {
        DepositLockHook impl = new DepositLockHook();
        // Embed a factory other than this test contract; a non-factory caller must not be able
        // to initialize the clone (clone-init front-running protection).
        DepositLockHook newHook = DepositLockHook(
            ClonesWithImmutableArgs.clone(
                address(impl), abi.encodePacked(makeAddr("otherFactory"), address(concreteStandardVault))
            )
        );
        vm.expectRevert(BaseHook.NotFactory.selector);
        newHook.initialize(hookManager, INITIAL_DURATION);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setters — happy path
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setDepositLockDuration_updatesAndEmits() public {
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.DepositLockDurationSet(INITIAL_DURATION, 7 days);
        hook.setDepositLockDuration(7 days);
        assertEq(hook.depositLockDuration(), 7 days);
    }

    function test_setMaxLocksPerUser_updatesAndEmits() public {
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.MaxLocksPerUserSet(10, 10);
        hook.setMaxLocksPerUser(10);
        assertEq(hook.maxLocksPerUser(), 10);
    }

    function test_setHookContainer_updatesAndEmits() public {
        address container = makeAddr("container");
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.HookContainerSet(address(0), container);
        hook.setHookContainer(container);
        assertEq(hook.hookContainer(), container);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setters — onlyOwner revert
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setDepositLockDuration_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setDepositLockDuration(7 days);
    }

    function test_setMaxLocksPerUser_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setMaxLocksPerUser(10);
    }

    function test_setMaxLocksPerUser_revertsForZero() public {
        uint256 previous = hook.maxLocksPerUser();
        vm.prank(hookManager);
        vm.expectRevert(DepositLockHook.ZeroMaxLocks.selector);
        hook.setMaxLocksPerUser(0);
        assertEq(hook.maxLocksPerUser(), previous);
    }

    function test_setMaxLocksPerUser_acceptsAtCeiling() public {
        uint256 ceiling = hook.MAX_LOCKS_PER_USER_CEILING();
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.MaxLocksPerUserSet(10, ceiling);
        hook.setMaxLocksPerUser(ceiling);
        assertEq(hook.maxLocksPerUser(), ceiling);
    }

    function test_setMaxLocksPerUser_revertsAboveCeiling() public {
        uint256 previous = hook.maxLocksPerUser();
        uint256 ceiling = hook.MAX_LOCKS_PER_USER_CEILING();
        uint256 above = ceiling + 1;
        vm.prank(hookManager);
        vm.expectRevert(abi.encodeWithSelector(DepositLockHook.MaxLocksPerUserAboveCeiling.selector, above, ceiling));
        hook.setMaxLocksPerUser(above);
        assertEq(hook.maxLocksPerUser(), previous);
    }

    function test_setHookContainer_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setHookContainer(makeAddr("container"));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Revert paths — access control
    // ─────────────────────────────────────────────────────────────────────────────

    function test_postDeposit_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.postDeposit(address(0), 0, 1 ether, alice, 0);
    }

    function test_postMint_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.postMint(address(0), 0, 1 ether, alice, 0);
    }

    function test_preTransfer_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.preTransfer(address(0), alice, makeAddr("bob"), 1 ether);
    }

    function test_preWithdraw_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.preWithdraw(address(0), 1 ether, 0, address(0), alice, 0);
    }

    function test_preRedeem_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.preRedeem(address(0), 0, 1 ether, address(0), alice, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Revert paths — lock limits & overflow
    // ─────────────────────────────────────────────────────────────────────────────

    function test_maxLocksExceeded_reverts() public {
        _setupHooks();
        vm.prank(hookManager);
        hook.setMaxLocksPerUser(2);

        _depositAs(alice, 5 ether);
        _depositAs(alice, 5 ether);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(DepositLockHook.MaxLocksExceeded.selector, alice, 2, 2));
        concreteStandardVault.deposit(5 ether, alice);
        vm.stopPrank();
    }

    function test_sharesOverflow_reverts() public {
        address container = makeAddr("container");
        vm.prank(hookManager);
        hook.setHookContainer(container);

        vm.prank(container);
        vm.expectRevert(DepositLockHook.SharesOverflow.selector);
        hook.postDeposit(address(0), 0, uint256(type(uint128).max) + 1, alice, 0);
    }

    function test_unlockTimestampOverflow_reverts() public {
        vm.startPrank(hookManager);
        hook.setDepositLockDuration(type(uint64).max);
        address container = makeAddr("container");
        hook.setHookContainer(container);
        vm.stopPrank();

        vm.prank(container);
        vm.expectRevert(DepositLockHook.UnlockTimestampOverflow.selector);
        hook.postDeposit(address(0), 0, 1 ether, alice, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Edge cases — hookContainer & zero shares
    // ─────────────────────────────────────────────────────────────────────────────

    function test_hookContainer_canCallHookFunctions() public {
        address container = makeAddr("container");
        vm.prank(hookManager);
        hook.setHookContainer(container);

        vm.prank(container);
        hook.postDeposit(address(0), 0, 1 ether, alice, 0);
        assertEq(hook.storedTotalLocked(alice), 1 ether);
        assertEq(hook.storedLockCount(alice), 1);
    }

    function test_zeroSharesDeposit_createsNoLock() public {
        address container = makeAddr("container");
        vm.prank(hookManager);
        hook.setHookContainer(container);

        vm.prank(container);
        hook.postDeposit(address(0), 0, 0, alice, 0);
        assertEq(hook.storedLockCount(alice), 0);
        assertEq(hook.storedTotalLocked(alice), 0);
    }

    function test_zeroSharesTransfer_doesNotRevert() public {
        _setupHooks();
        _depositAs(alice, 10 ether);

        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _assertLockedLeBalance(address user) internal view {
        uint256 balance = concreteStandardVault.balanceOf(user);
        uint256 locked = hook.storedTotalLocked(user);
        assertLe(locked, balance, "storedTotalLocked > balanceOf");
    }

    function _viewEffectiveLocked(address user) internal view returns (uint256) {
        uint256 balance = concreteStandardVault.balanceOf(user);
        uint256 unlocked = hook.getUnlockedShares(user);
        return balance > unlocked ? balance - unlocked : 0;
    }
}
