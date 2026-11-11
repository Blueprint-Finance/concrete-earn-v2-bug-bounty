// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {HooksLibV2} from "../../../src/lib/Hooks.sol";
import {DepositLockHook} from "../../../src/periphery/hooks/DepositLockHook.sol";
import {DepositLockWithFeeHook} from "../../../src/periphery/hooks/DepositLockWithFeeHook.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";

contract DepositLockWithFeeHookTest is ConcreteStandardVaultImplBaseSetup {
    address alice;
    address feeReceiver;
    DepositLockWithFeeHook hook;

    uint64 constant LOCK_DURATION = 30 days;
    uint256 constant MAX_FEE = 500; // 5%
    uint64 constant MIN_LOCK_PERIOD = 1 days;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();
        alice = makeAddr("alice");
        feeReceiver = makeAddr("feeReceiver");
        asset.mint(alice, 1000 ether);

        hook = _deployHook(
            hookManager, address(concreteStandardVault), LOCK_DURATION, MAX_FEE, MIN_LOCK_PERIOD, feeReceiver
        );
        vm.prank(hookManager);
        hook.setEarlyUnlockEnabled(true);
    }

    /// @dev Deploys a locked implementation, clones it (ClonesWithImmutableArgs) and initializes the clone.
    function _deployHook(
        address owner_,
        address vault_,
        uint64 initialLockDuration_,
        uint256 maxFee_,
        uint64 minLockPeriod_,
        address feeRecipient_
    ) internal returns (DepositLockWithFeeHook h) {
        DepositLockWithFeeHook impl = new DepositLockWithFeeHook();
        // Immutable args mirror the factory layout: [factory (20)][vault (20)]. This test
        // contract acts as the factory authorized to initialize the clone.
        h = DepositLockWithFeeHook(
            ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), vault_))
        );
        h.initialize(owner_, initialLockDuration_, maxFee_, minLockPeriod_, feeRecipient_);
    }

    /// @dev Clones the implementation without initializing, for revert-path tests.
    function _cloneUninitialized() internal returns (DepositLockWithFeeHook h) {
        DepositLockWithFeeHook impl = new DepositLockWithFeeHook();
        h = DepositLockWithFeeHook(
            ClonesWithImmutableArgs.clone(
                address(impl), abi.encodePacked(address(this), address(concreteStandardVault))
            )
        );
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

    function _approveHook(address user) internal {
        vm.prank(user);
        concreteStandardVault.approve(address(hook), type(uint256).max);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────────────

    function test_init_setsInitialState() public {
        DepositLockWithFeeHook freshHook = _deployHook(
            hookManager, address(concreteStandardVault), LOCK_DURATION, MAX_FEE, MIN_LOCK_PERIOD, feeReceiver
        );
        assertEq(freshHook.maxEarlyUnlockFee(), MAX_FEE);
        assertEq(freshHook.minLockPeriod(), MIN_LOCK_PERIOD);
        assertEq(freshHook.feeRecipient(), feeReceiver);
        assertEq(freshHook.VAULT(), address(concreteStandardVault));
        assertEq(freshHook.depositLockDuration(), LOCK_DURATION);
        assertEq(freshHook.earlyUnlockEnabled(), false);
    }

    function test_init_revertsOnMaxFeeExceedsBasis() public {
        DepositLockWithFeeHook freshHook = _cloneUninitialized();
        vm.expectRevert(abi.encodeWithSelector(DepositLockWithFeeHook.MaxFeeExceedsBasis.selector, 10_001, 10_000));
        freshHook.initialize(hookManager, LOCK_DURATION, 10_001, 0, feeReceiver);
    }

    function test_init_baseOverloadReverts() public {
        DepositLockWithFeeHook freshHook = _cloneUninitialized();
        vm.expectRevert(DepositLockWithFeeHook.UseDerivedInitializer.selector);
        DepositLockHook(address(freshHook)).initialize(hookManager, LOCK_DURATION);
    }

    function test_init_baseOverloadDoesNotLockOutDerivedInitializer() public {
        DepositLockWithFeeHook freshHook = _cloneUninitialized();
        vm.expectRevert(DepositLockWithFeeHook.UseDerivedInitializer.selector);
        DepositLockHook(address(freshHook)).initialize(hookManager, LOCK_DURATION);

        // The reverting base overload must not consume the one-shot initializer.
        freshHook.initialize(hookManager, LOCK_DURATION, MAX_FEE, MIN_LOCK_PERIOD, feeReceiver);
        assertEq(freshHook.maxEarlyUnlockFee(), MAX_FEE);
        assertEq(freshHook.minLockPeriod(), MIN_LOCK_PERIOD);
        assertEq(freshHook.feeRecipient(), feeReceiver);
        assertEq(freshHook.depositLockDuration(), LOCK_DURATION);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setters — happy path
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setMaxEarlyUnlockFee_updatesAndEmits() public {
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockWithFeeHook.MaxEarlyUnlockFeeSet(MAX_FEE, 1000);
        hook.setMaxEarlyUnlockFee(1000);
        assertEq(hook.maxEarlyUnlockFee(), 1000);
    }

    function test_setMinLockPeriod_updatesAndEmits() public {
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockWithFeeHook.MinLockPeriodSet(MIN_LOCK_PERIOD, 7 days);
        hook.setMinLockPeriod(7 days);
        assertEq(hook.minLockPeriod(), 7 days);
    }

    function test_setFeeRecipient_updatesAndEmits() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockWithFeeHook.FeeRecipientSet(feeReceiver, newRecipient);
        hook.setFeeRecipient(newRecipient);
        assertEq(hook.feeRecipient(), newRecipient);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setters — onlyOwner revert
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setMaxEarlyUnlockFee_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setMaxEarlyUnlockFee(1000);
    }

    function test_setMinLockPeriod_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setMinLockPeriod(7 days);
    }

    function test_setFeeRecipient_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setFeeRecipient(makeAddr("someone"));
    }

    function test_setMaxEarlyUnlockFee_revertsOnExceedsBasis() public {
        vm.prank(hookManager);
        vm.expectRevert(abi.encodeWithSelector(DepositLockWithFeeHook.MaxFeeExceedsBasis.selector, 10_001, 10_000));
        hook.setMaxEarlyUnlockFee(10_001);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setters — minLockPeriod vs depositLockDuration invariant
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setMinLockPeriod_revertsWhenExceedsDuration() public {
        vm.prank(hookManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositLockWithFeeHook.MinLockPeriodExceedsDuration.selector, LOCK_DURATION, LOCK_DURATION
            )
        );
        hook.setMinLockPeriod(LOCK_DURATION);
    }

    function test_setDepositLockDuration_revertsWhenBelowMinLockPeriod() public {
        vm.prank(hookManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositLockWithFeeHook.MinLockPeriodExceedsDuration.selector, MIN_LOCK_PERIOD, MIN_LOCK_PERIOD
            )
        );
        hook.setDepositLockDuration(MIN_LOCK_PERIOD);
    }

    function test_setDepositLockDuration_allowsZeroRegardlessOfMinPeriod() public {
        vm.prank(hookManager);
        hook.setDepositLockDuration(0);
        assertEq(hook.depositLockDuration(), 0);
    }

    function test_setMinLockPeriod_allowsZeroRegardlessOfDuration() public {
        vm.prank(hookManager);
        hook.setMinLockPeriod(0);
        assertEq(hook.minLockPeriod(), 0);
    }

    function test_init_revertsWhenMinPeriodExceedsDuration() public {
        DepositLockWithFeeHook freshHook = _cloneUninitialized();
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockWithFeeHook.MinLockPeriodExceedsDuration.selector, 30 days, 1 days)
        );
        freshHook.initialize(hookManager, 1 days, MAX_FEE, 30 days, feeReceiver);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — basic fee calculation
    // ─────────────────────────────────────────────────────────────────────────────

    function test_deposit_emitsLockCreated() public {
        _setupHooks();

        vm.prank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);

        uint64 expectedUnlockTs = uint64(block.timestamp + LOCK_DURATION);
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.LockCreated(alice, 10 ether, expectedUnlockTs, LOCK_DURATION);

        vm.prank(alice);
        concreteStandardVault.deposit(10 ether, alice);
    }

    function test_earlyUnlock_emitsEarlyUnlock() public {
        _setupHooks();
        _depositAs(alice, 100 ether);
        _approveHook(alice);

        vm.warp(block.timestamp + LOCK_DURATION / 2);

        uint256 expectedFee = 2.5 ether;
        vm.expectEmit(true, true, true, true);
        emit DepositLockWithFeeHook.EarlyUnlock(alice, 100 ether, expectedFee);

        vm.prank(alice);
        hook.earlyUnlock(100 ether);
    }

    function test_earlyUnlock_fullLock_halfwayFee() public {
        _setupHooks();
        _depositAs(alice, 100 ether);
        _approveHook(alice);

        // Warp past minLockPeriod, to exactly halfway through the lock
        vm.warp(block.timestamp + LOCK_DURATION / 2);

        // fee = 100e18 * 500 * (15 days) / (30 days * 10000) = 100e18 * 0.025 = 2.5e18
        uint256 expectedFee = 2.5 ether;

        uint256 previewFee = hook.previewEarlyUnlock(alice, 100 ether);
        assertEq(previewFee, expectedFee, "preview fee mismatch");

        vm.prank(alice);
        uint256 actualFee = hook.earlyUnlock(100 ether);
        assertEq(actualFee, expectedFee, "actual fee mismatch");

        assertEq(hook.storedTotalLocked(alice), 0);
        assertEq(hook.storedLockCount(alice), 0);
        assertEq(concreteStandardVault.balanceOf(feeReceiver), expectedFee);
        assertEq(concreteStandardVault.balanceOf(alice), 100 ether - expectedFee);
    }

    function test_earlyUnlock_atCreation_maxFee() public {
        _setupHooks();
        _depositAs(alice, 100 ether);
        _approveHook(alice);

        // Warp to exactly minLockPeriod (earliest allowed)
        vm.warp(block.timestamp + MIN_LOCK_PERIOD);

        // timeRemaining = 30 days - 1 day = 29 days
        // fee = ⌈100e18 * 500 * 29 days / (30 days * 10000)⌉
        uint256 expectedFee = _ceilDiv(100 ether * 500 * 29 days, uint256(LOCK_DURATION) * 10_000);

        vm.prank(alice);
        uint256 actualFee = hook.earlyUnlock(100 ether);
        assertEq(actualFee, expectedFee);
    }

    function test_earlyUnlock_nearExpiry_minimalFee() public {
        _setupHooks();
        _depositAs(alice, 100 ether);
        _approveHook(alice);

        // Warp to 1 second before expiry
        vm.warp(block.timestamp + LOCK_DURATION - 1);

        // timeRemaining = 1 second
        // fee = ⌈100e18 * 500 * 1 / (30 days * 10000)⌉ ≈ very small
        uint256 expectedFee = _ceilDiv(100 ether * 500 * 1, uint256(LOCK_DURATION) * 10_000);

        vm.prank(alice);
        uint256 actualFee = hook.earlyUnlock(100 ether);
        assertEq(actualFee, expectedFee);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — partial consumption
    // ─────────────────────────────────────────────────────────────────────────────

    function test_earlyUnlock_partialLock() public {
        _setupHooks();
        _depositAs(alice, 100 ether);
        _approveHook(alice);

        vm.warp(block.timestamp + LOCK_DURATION / 2);

        // Unlock only 40 shares from a 100-share lock
        uint256 timeRemaining = LOCK_DURATION / 2;
        uint256 expectedFee = _ceilDiv(40 ether * 500 * timeRemaining, uint256(LOCK_DURATION) * 10_000);

        vm.prank(alice);
        uint256 actualFee = hook.earlyUnlock(40 ether);
        assertEq(actualFee, expectedFee);

        // Lock should still exist with 60 shares remaining
        assertEq(hook.storedLockCount(alice), 1);
        assertEq(hook.storedTotalLocked(alice), 60 ether);

        DepositLockHook.Lock memory remaining = hook.getStoredLock(alice, 0);
        assertEq(remaining.shares, 60 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — FIFO across multiple locks
    // ─────────────────────────────────────────────────────────────────────────────

    function test_earlyUnlock_consumesMultipleLocksFIFO() public {
        _setupHooks();

        // Two deposits 5 days apart
        _depositAs(alice, 50 ether);
        vm.warp(block.timestamp + 5 days);
        _depositAs(alice, 30 ether);
        _approveHook(alice);

        assertEq(hook.storedLockCount(alice), 2);

        // Warp to 20 days after first deposit (15 days after second)
        vm.warp(block.timestamp + 15 days);

        // Lock 0: created at t=0, duration=30d, unlockTs=t+30d. At t+20d: timeRemaining=10d
        // Lock 1: created at t=5d, duration=30d, unlockTs=t+35d. At t+20d: timeRemaining=15d
        // Unlock 70 ether = fully consume lock 0 (50) + partially consume lock 1 (20)

        uint256 fee0 = _ceilDiv(50 ether * 500 * 10 days, uint256(LOCK_DURATION) * 10_000);
        uint256 fee1 = _ceilDiv(20 ether * 500 * 15 days, uint256(LOCK_DURATION) * 10_000);
        uint256 expectedFee = fee0 + fee1;

        vm.prank(alice);
        uint256 actualFee = hook.earlyUnlock(70 ether);
        assertEq(actualFee, expectedFee);

        // Lock 0 fully consumed, lock 1 partially consumed (10 remaining)
        assertEq(hook.storedLockCount(alice), 1);
        assertEq(hook.storedTotalLocked(alice), 10 ether);

        DepositLockHook.Lock memory remaining = hook.getStoredLock(alice, 0);
        assertEq(remaining.shares, 10 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — expired locks cleaned before consumption
    // ─────────────────────────────────────────────────────────────────────────────

    function test_earlyUnlock_cleansExpiredBeforeConsuming() public {
        _setupHooks();

        _depositAs(alice, 20 ether);
        vm.warp(block.timestamp + LOCK_DURATION + 1);
        _depositAs(alice, 30 ether);
        _approveHook(alice);

        // Lock 0 was expired and cleaned during the second deposit's _appendLock.
        assertEq(hook.storedLockCount(alice), 1);
        assertEq(hook.effectiveLockCount(alice), 1);

        // Warp past minLockPeriod for lock 1
        vm.warp(block.timestamp + MIN_LOCK_PERIOD);

        // earlyUnlock should clean expired lock first, then consume lock 1
        vm.prank(alice);
        hook.earlyUnlock(30 ether);

        assertEq(hook.storedLockCount(alice), 0);
        assertEq(hook.storedTotalLocked(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — zero fee when maxFee is 0
    // ─────────────────────────────────────────────────────────────────────────────

    function test_earlyUnlock_freeWhenMaxFeeIsZero() public {
        _setupHooks();
        vm.prank(hookManager);
        hook.setMaxEarlyUnlockFee(0);

        _depositAs(alice, 50 ether);
        _approveHook(alice);

        vm.warp(block.timestamp + LOCK_DURATION / 2);

        vm.prank(alice);
        uint256 fee = hook.earlyUnlock(50 ether);
        assertEq(fee, 0);

        assertEq(concreteStandardVault.balanceOf(feeReceiver), 0);
        assertEq(concreteStandardVault.balanceOf(alice), 50 ether);
        assertEq(hook.storedTotalLocked(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — after unlock, shares are transferable and redeemable
    // ─────────────────────────────────────────────────────────────────────────────

    function test_earlyUnlock_sharesBecomeFreeAfterUnlock() public {
        _setupHooks();
        _depositAs(alice, 100 ether);
        _approveHook(alice);

        vm.warp(block.timestamp + LOCK_DURATION / 2);

        vm.prank(alice);
        uint256 fee = hook.earlyUnlock(100 ether);

        uint256 aliceBalance = concreteStandardVault.balanceOf(alice);
        assertEq(aliceBalance, 100 ether - fee);

        // Transfer should succeed (all shares unlocked)
        address bob = makeAddr("bob");
        vm.prank(alice);
        concreteStandardVault.transfer(bob, 10 ether);

        // Redeem should succeed
        vm.prank(alice);
        concreteStandardVault.redeem(aliceBalance - 10 ether, alice, alice);

        assertEq(concreteStandardVault.balanceOf(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — revert paths
    // ─────────────────────────────────────────────────────────────────────────────

    function test_earlyUnlock_revertsOnZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockWithFeeHook.ZeroSharesRequested.selector);
        hook.earlyUnlock(0);
    }

    function test_earlyUnlock_revertsOnNoFeeRecipient() public {
        vm.prank(hookManager);
        hook.setFeeRecipient(address(0));

        vm.prank(alice);
        vm.expectRevert(DepositLockWithFeeHook.NoFeeRecipient.selector);
        hook.earlyUnlock(1 ether);
    }

    function test_earlyUnlock_revertsOnInsufficientLockedShares() public {
        _setupHooks();
        _depositAs(alice, 50 ether);
        _approveHook(alice);

        vm.warp(block.timestamp + MIN_LOCK_PERIOD);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockWithFeeHook.InsufficientLockedShares.selector, alice, 100 ether, 50 ether)
        );
        hook.earlyUnlock(100 ether);
    }

    function test_earlyUnlock_revertsOnMinLockPeriod() public {
        _setupHooks();
        _depositAs(alice, 50 ether);
        _approveHook(alice);

        // No time has passed since deposit, so remaining = full MIN_LOCK_PERIOD
        uint256 remaining = MIN_LOCK_PERIOD;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockWithFeeHook.LockWithinMinPeriod.selector, alice, 0, remaining)
        );
        hook.earlyUnlock(50 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // earlyUnlock — toggle
    // ─────────────────────────────────────────────────────────────────────────────

    function test_earlyUnlock_revertsWhenDisabled() public {
        _setupHooks();
        _depositAs(alice, 50 ether);

        vm.prank(hookManager);
        hook.setEarlyUnlockEnabled(false);

        vm.warp(block.timestamp + LOCK_DURATION / 2);

        vm.prank(alice);
        vm.expectRevert(DepositLockWithFeeHook.EarlyUnlockDisabled.selector);
        hook.earlyUnlock(50 ether);
    }

    function test_previewEarlyUnlock_revertsWhenDisabled() public {
        _setupHooks();
        _depositAs(alice, 50 ether);

        vm.prank(hookManager);
        hook.setEarlyUnlockEnabled(false);

        vm.warp(block.timestamp + LOCK_DURATION / 2);

        vm.expectRevert(DepositLockWithFeeHook.EarlyUnlockDisabled.selector);
        hook.previewEarlyUnlock(alice, 50 ether);
    }

    function test_setEarlyUnlockEnabled_updatesAndEmits() public {
        vm.prank(hookManager);
        hook.setEarlyUnlockEnabled(false);
        assertEq(hook.earlyUnlockEnabled(), false);

        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockWithFeeHook.EarlyUnlockEnabledSet(true);
        hook.setEarlyUnlockEnabled(true);
        assertEq(hook.earlyUnlockEnabled(), true);
    }

    function test_setEarlyUnlockEnabled_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setEarlyUnlockEnabled(false);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // previewEarlyUnlock
    // ─────────────────────────────────────────────────────────────────────────────

    function test_previewEarlyUnlock_matchesActual() public {
        _setupHooks();
        _depositAs(alice, 100 ether);
        _approveHook(alice);

        vm.warp(block.timestamp + LOCK_DURATION / 2);

        uint256 preview = hook.previewEarlyUnlock(alice, 100 ether);

        vm.prank(alice);
        uint256 actual = hook.earlyUnlock(100 ether);

        assertEq(preview, actual, "preview should match actual");
    }

    function test_previewEarlyUnlock_revertsOnNoFeeRecipient() public {
        vm.prank(hookManager);
        hook.setFeeRecipient(address(0));

        vm.expectRevert(DepositLockWithFeeHook.NoFeeRecipient.selector);
        hook.previewEarlyUnlock(alice, 1 ether);
    }

    function test_previewEarlyUnlock_zeroReturnsZero() public view {
        uint256 fee = hook.previewEarlyUnlock(alice, 0);
        assertEq(fee, 0);
    }

    function test_previewEarlyUnlock_revertsOnInsufficient() public {
        _setupHooks();
        _depositAs(alice, 50 ether);

        vm.warp(block.timestamp + MIN_LOCK_PERIOD);

        vm.expectRevert(
            abi.encodeWithSelector(DepositLockWithFeeHook.InsufficientLockedShares.selector, alice, 100 ether, 50 ether)
        );
        hook.previewEarlyUnlock(alice, 100 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Inherited DepositLockHook behaviour still works
    // ─────────────────────────────────────────────────────────────────────────────

    function test_lockedSharesStillBlockTransfer() public {
        _setupHooks();
        _depositAs(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DepositLockHook.InsufficientUnlocked.selector, alice, 1 ether, 0));
        concreteStandardVault.transfer(makeAddr("bob"), 1 ether);
    }

    function test_naturalExpiryStillWorks() public {
        _setupHooks();
        _depositAs(alice, 10 ether);

        vm.warp(block.timestamp + LOCK_DURATION);

        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), 10 ether);
        assertEq(concreteStandardVault.balanceOf(makeAddr("bob")), 10 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Duration decrease: out-of-order timestamps with early unlock
    // ─────────────────────────────────────────────────────────────────────────────

    function test_durationDecrease_earlyUnlockWorksWithOutOfOrderLocks() public {
        _setupHooks();

        // Lock 1: 30 days, 50 ether
        _depositAs(alice, 50 ether);
        _approveHook(alice);

        // Reduce duration to 2 days
        vm.prank(hookManager);
        hook.setDepositLockDuration(2 days);

        vm.warp(block.timestamp + 1);

        // Lock 2: 2 days, 30 ether (unlockTs << lock 1's unlockTs)
        _depositAs(alice, 30 ether);

        assertEq(hook.storedLockCount(alice), 2);

        // Warp past lock 2 (2 days) + minLockPeriod, but well before lock 1 (30 days)
        vm.warp(block.timestamp + 3 days);

        // Lock 2 should have been cleaned as expired; lock 1 still active
        // earlyUnlock should only consume from lock 1
        uint256 preview = hook.previewEarlyUnlock(alice, 20 ether);

        vm.prank(alice);
        uint256 actualFee = hook.earlyUnlock(20 ether);
        assertEq(actualFee, preview, "preview should match actual");

        // 50 - 20 = 30 ether still locked from lock 1
        assertEq(hook.storedTotalLocked(alice), 30 ether);
        assertEq(hook.storedLockCount(alice), 1);

        // The 30 ether from expired lock 2 are now free
        uint256 balance = concreteStandardVault.balanceOf(alice);
        uint256 unlocked = balance - 30 ether;
        vm.prank(alice);
        concreteStandardVault.transfer(makeAddr("bob"), unlocked);
    }

    function test_durationDecrease_previewSkipsExpiredInline() public {
        _setupHooks();

        // Lock 1: 30 days, 40 ether
        _depositAs(alice, 40 ether);

        vm.startPrank(hookManager);
        hook.setMinLockPeriod(0);
        hook.setDepositLockDuration(1 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Lock 2: 1 hour, 20 ether
        _depositAs(alice, 20 ether);

        vm.warp(block.timestamp + 1);

        // Lock 3: 1 hour, 10 ether
        _depositAs(alice, 10 ether);

        // Warp well past locks 2,3 expiry (1 hour)
        vm.warp(block.timestamp + 2 hours);

        // previewEarlyUnlock should skip expired locks 2,3 and price from lock 1 only
        uint256 fee = hook.previewEarlyUnlock(alice, 10 ether);
        assertGt(fee, 0, "fee should be non-zero for active lock");

        // Verify it matches what earlyUnlock actually charges
        _approveHook(alice);
        vm.prank(alice);
        uint256 actual = hook.earlyUnlock(10 ether);
        assertEq(fee, actual);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────────────────────────────

    function testFuzz_earlyUnlock_feeNeverExceedsMaxPercentage(uint256 depositAmount, uint64 warpTime) public {
        depositAmount = bound(depositAmount, 1 ether, 500 ether);
        warpTime = uint64(bound(warpTime, MIN_LOCK_PERIOD, LOCK_DURATION - 1));

        _setupHooks();
        _depositAs(alice, depositAmount);
        _approveHook(alice);

        vm.warp(block.timestamp + warpTime);

        uint256 fee = hook.previewEarlyUnlock(alice, depositAmount);
        uint256 maxPossibleFee = (depositAmount * MAX_FEE) / 10_000;

        assertLe(fee, maxPossibleFee, "fee exceeds max percentage");
        assertGe(fee, 0, "fee is negative (impossible but sanity)");
    }

    function testFuzz_earlyUnlock_feeDecreasesOverTime(uint256 depositAmount, uint64 t1, uint64 t2) public {
        depositAmount = bound(depositAmount, 1 ether, 500 ether);
        t1 = uint64(bound(t1, MIN_LOCK_PERIOD, LOCK_DURATION / 2));
        t2 = uint64(bound(t2, uint256(t1) + 1, LOCK_DURATION - 1));

        _setupHooks();
        _depositAs(alice, depositAmount);

        vm.warp(block.timestamp + t1);
        uint256 fee1 = hook.previewEarlyUnlock(alice, depositAmount);

        vm.warp(block.timestamp + (t2 - t1));
        uint256 fee2 = hook.previewEarlyUnlock(alice, depositAmount);

        assertGe(fee1, fee2, "fee should decrease over time");
    }
}
