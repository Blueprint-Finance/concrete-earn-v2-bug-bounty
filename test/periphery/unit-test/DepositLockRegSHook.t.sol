// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {HooksLibV2} from "../../../src/lib/Hooks.sol";
import {DepositLockHook} from "../../../src/periphery/hooks/DepositLockHook.sol";
import {DepositLockRegSHook} from "../../../src/periphery/hooks/DepositLockRegSHook.sol";
import {IDepositLockRegSHook} from "../../../src/periphery/hooks/IDepositLockRegSHook.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {stdError} from "forge-std/StdError.sol";
import {Vm} from "forge-std/Vm.sol";
import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";

contract DepositLockRegSHookTest is ConcreteStandardVaultImplBaseSetup {
    address alice;
    address bob;
    DepositLockRegSHook hook;

    uint64 constant HARD_LOCK_DURATION = 28 days;
    uint64 constant REG_S_EXTENSION = 12 days;
    uint64 constant TOTAL_DURATION = HARD_LOCK_DURATION + REG_S_EXTENSION;

    function setUp() public override {
        ConcreteStandardVaultImplBaseSetup.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        asset.mint(alice, 100 ether);
        asset.mint(bob, 100 ether);
        hook = _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Deploys a locked implementation, clones it (ClonesWithImmutableArgs) and initializes the clone.
    function _deployHook(address owner_, address vault_, uint64 hardLock_, uint64 regSExt_, address legacy_)
        internal
        returns (DepositLockRegSHook h)
    {
        DepositLockRegSHook impl = new DepositLockRegSHook();
        // Immutable args mirror the factory layout: [factory (20)][vault (20)]. This test
        // contract acts as the factory authorized to initialize the clone.
        h = DepositLockRegSHook(ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), vault_)));
        h.initialize(owner_, hardLock_, regSExt_, legacy_);
    }

    /// @dev Clones the implementation without initializing, for revert-path tests.
    function _cloneUninitialized() internal returns (DepositLockRegSHook h) {
        DepositLockRegSHook impl = new DepositLockRegSHook();
        h = DepositLockRegSHook(
            ClonesWithImmutableArgs.clone(
                address(impl), abi.encodePacked(address(this), address(concreteStandardVault))
            )
        );
    }

    function _flagsRegSLock() internal pure returns (uint96) {
        return uint96(
            (1 << HooksLibV2.POST_DEPOSIT) | (1 << HooksLibV2.POST_MINT) | (1 << HooksLibV2.PRE_TRANSFER)
                | (1 << HooksLibV2.PRE_WITHDRAW) | (1 << HooksLibV2.PRE_REDEEM)
        );
    }

    function _wireHook(DepositLockRegSHook h) internal {
        vm.prank(hookManager);
        concreteStandardVault.setHooks(Hooks({target: address(h), flags: _flagsRegSLock()}));
    }

    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        concreteStandardVault.deposit(amount, user);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    function test_constructor_setsInitialState() public view {
        assertEq(hook.VAULT(), address(concreteStandardVault));
        assertEq(hook.hardLockDuration(), HARD_LOCK_DURATION);
        assertEq(hook.REG_S_EXTENSION(), REG_S_EXTENSION);
        assertEq(hook.owner(), hookManager);
        assertEq(hook.maxLocksPerUser(), 10);
        assertEq(hook.hookContainer(), address(0));
        assertEq(hook.successorHook(), address(0));
        assertEq(address(hook.legacyHook()), address(0));
    }

    function test_init_VAULT_readsImmutableArg() public {
        DepositLockRegSHook h = _cloneUninitialized();
        h.initialize(hookManager, HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
        assertEq(h.VAULT(), address(concreteStandardVault));
    }

    function test_init_revertsOnZeroHardLockDuration() public {
        DepositLockRegSHook h = _cloneUninitialized();
        vm.expectRevert(DepositLockRegSHook.ZeroHardLockDuration.selector);
        h.initialize(hookManager, 0, REG_S_EXTENSION, address(0));
    }

    function test_init_acceptsZeroRegSExtension() public {
        DepositLockRegSHook h =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, 0, address(0));
        assertEq(h.REG_S_EXTENSION(), 0);
    }

    function test_init_acceptsValidLegacyHook() public {
        DepositLockRegSHook legacy =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
        DepositLockRegSHook v2 = _deployHook(
            hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(legacy)
        );
        assertEq(address(v2.legacyHook()), address(legacy));
    }

    function test_init_revertsOnLegacyHookVaultMismatch() public {
        address otherVault = makeAddr("otherVault");
        // The hook's initialize guard reads cancellationEnabled() from its vault; stub the
        // EOA stand-in vault so the mismatch scenario is what's under test.
        vm.mockCall(otherVault, abi.encodeWithSignature("cancellationEnabled()"), abi.encode(false));
        DepositLockRegSHook badLegacy =
            _deployHook(hookManager, otherVault, HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));

        DepositLockRegSHook v2 = _cloneUninitialized();
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositLockRegSHook.LegacyHookVaultMismatch.selector,
                address(badLegacy),
                otherVault,
                address(concreteStandardVault)
            )
        );
        v2.initialize(hookManager, HARD_LOCK_DURATION, REG_S_EXTENSION, address(badLegacy));
    }

    function test_init_baseOverloadReverts() public {
        DepositLockRegSHook h = _cloneUninitialized();
        vm.expectRevert(DepositLockRegSHook.UseDerivedInitializer.selector);
        DepositLockHook(address(h)).initialize(hookManager, HARD_LOCK_DURATION);
    }

    function test_init_baseOverloadDoesNotLockOutDerivedInitializer() public {
        DepositLockRegSHook h = _cloneUninitialized();
        vm.expectRevert(DepositLockRegSHook.UseDerivedInitializer.selector);
        DepositLockHook(address(h)).initialize(hookManager, HARD_LOCK_DURATION);

        // The reverting base overload must not consume the one-shot initializer.
        h.initialize(hookManager, HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
        assertEq(h.REG_S_EXTENSION(), REG_S_EXTENSION);
        assertEq(h.hardLockDuration(), HARD_LOCK_DURATION);
        assertEq(h.owner(), hookManager);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setters
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setHardLockDuration_updatesAndEmits() public {
        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.DepositLockDurationSet(TOTAL_DURATION, 7 days + REG_S_EXTENSION);
        vm.expectEmit(true, true, true, true);
        emit DepositLockRegSHook.HardLockDurationSet(HARD_LOCK_DURATION, 7 days);
        hook.setHardLockDuration(7 days);
        assertEq(hook.hardLockDuration(), 7 days);
        assertEq(hook.depositLockDuration(), 7 days + REG_S_EXTENSION);
    }

    function test_setHardLockDuration_revertsOnZero() public {
        vm.prank(hookManager);
        vm.expectRevert(DepositLockRegSHook.ZeroHardLockDuration.selector);
        hook.setHardLockDuration(0);
    }

    function test_setHardLockDuration_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setHardLockDuration(7 days);
    }

    function test_setMaxLocksPerUser_atCeilingAndAboveReverts() public {
        uint256 ceiling = hook.MAX_LOCKS_PER_USER_CEILING();

        vm.prank(hookManager);
        hook.setMaxLocksPerUser(ceiling);
        assertEq(hook.maxLocksPerUser(), ceiling);

        vm.prank(hookManager);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockHook.MaxLocksPerUserAboveCeiling.selector, ceiling + 1, ceiling)
        );
        hook.setMaxLocksPerUser(ceiling + 1);
    }

    function test_setMaxLocksPerUser_revertsOnZero() public {
        vm.prank(hookManager);
        vm.expectRevert(DepositLockHook.ZeroMaxLocks.selector);
        hook.setMaxLocksPerUser(0);
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
    // Inherited setter is closed by the Reg-S derivative
    // ─────────────────────────────────────────────────────────────────────────────

    function test_setDepositLockDuration_alwaysReverts() public {
        // Even when called by the owner, the base setter is closed and routes Reg-S
        // configuration through {setHardLockDuration} to preserve the
        // `depositLockDuration == hardLockDuration + REG_S_EXTENSION` invariant.
        vm.prank(hookManager);
        vm.expectRevert(DepositLockRegSHook.UseSetHardLockDuration.selector);
        hook.setDepositLockDuration(7 days);

        vm.prank(alice);
        vm.expectRevert(DepositLockRegSHook.UseSetHardLockDuration.selector);
        hook.setDepositLockDuration(7 days);
    }

    function test_setSuccessorHook_acceptsSameVault() public {
        DepositLockRegSHook successor =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));

        vm.prank(hookManager);
        vm.expectEmit(true, true, true, true);
        emit DepositLockRegSHook.SuccessorHookSet(address(0), address(successor));
        hook.setSuccessorHook(address(successor));
        assertEq(hook.successorHook(), address(successor));
    }

    function test_setSuccessorHook_acceptsZeroToClear() public {
        DepositLockRegSHook successor =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
        vm.startPrank(hookManager);
        hook.setSuccessorHook(address(successor));
        hook.setSuccessorHook(address(0));
        vm.stopPrank();
        assertEq(hook.successorHook(), address(0));
    }

    function test_setSuccessorHook_revertsOnVaultMismatch() public {
        address otherVault = makeAddr("otherVault");
        // The hook's initialize guard reads cancellationEnabled() from its vault; stub the
        // EOA stand-in vault so the mismatch scenario is what's under test.
        vm.mockCall(otherVault, abi.encodeWithSignature("cancellationEnabled()"), abi.encode(false));
        DepositLockRegSHook bad = _deployHook(hookManager, otherVault, HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));

        vm.prank(hookManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositLockRegSHook.LegacyHookVaultMismatch.selector,
                address(bad),
                otherVault,
                address(concreteStandardVault)
            )
        );
        hook.setSuccessorHook(address(bad));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // disconnectLegacyHook — downgrade-only mutability of `legacyHook`
    // ─────────────────────────────────────────────────────────────────────────────

    // Happy path: a v2 deployed against a real v1 legacy can be disconnected by the
    // owner. The slot moves to address(0) and LegacyHookDisconnected is emitted with the
    // previous address.
    function test_disconnectLegacyHook_clearsSlotAndEmits() public {
        DepositLockRegSHook legacy = hook;
        DepositLockRegSHook v2 = _deployHook(
            hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(legacy)
        );
        assertEq(address(v2.legacyHook()), address(legacy));

        vm.expectEmit(true, true, true, true);
        emit DepositLockRegSHook.LegacyHookDisconnected(address(legacy));

        vm.prank(hookManager);
        v2.disconnectLegacyHook();

        assertEq(address(v2.legacyHook()), address(0));
    }

    // The slot is monotonically downgradeable: a deployment that was constructed with
    // address(0) (no legacy) has nothing to disconnect, and the call reverts with
    // NoLegacyToDisconnect instead of silently emitting.
    function test_disconnectLegacyHook_revertsWhenNoLegacyConfigured() public {
        vm.prank(hookManager);
        vm.expectRevert(DepositLockRegSHook.NoLegacyToDisconnect.selector);
        hook.disconnectLegacyHook();
    }

    // Once disconnected, a second call cannot move the slot anywhere — including back
    // to its original value. The contract has no re-population path.
    function test_disconnectLegacyHook_revertsOnSecondCall() public {
        DepositLockRegSHook legacy = hook;
        DepositLockRegSHook v2 = _deployHook(
            hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(legacy)
        );

        vm.prank(hookManager);
        v2.disconnectLegacyHook();

        vm.prank(hookManager);
        vm.expectRevert(DepositLockRegSHook.NoLegacyToDisconnect.selector);
        v2.disconnectLegacyHook();
    }

    function test_disconnectLegacyHook_revertsForNonOwner() public {
        DepositLockRegSHook legacy = hook;
        DepositLockRegSHook v2 = _deployHook(
            hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(legacy)
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        v2.disconnectLegacyHook();
    }

    // Regression: after disconnect, enforcement / view paths must skip the legacy
    // contribution entirely. We assert this by depositing on v1 so it has real
    // transfer-locked balance for alice, swapping enforcement to v2, disconnecting the
    // legacy, and verifying that v2 then allows transfers / reads legacyContribution ==
    // (0, 0) even though v1's locks are still active. This is the explicit operational
    // trade-off documented on disconnectLegacyHook (premature disconnect frees v1's
    // residual locks for transfer/redeem on v2) and not a vulnerability of the contract.
    function test_disconnectLegacyHook_enforcementSkipsLegacyAfterDisconnect() public {
        DepositLockRegSHook v1 = hook;
        _wireHook(v1);
        _depositAs(alice, 10 ether);
        assertEq(v1.storedTransferLocked(alice), 10 ether);

        DepositLockRegSHook v2 =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(v1));
        vm.prank(hookManager);
        v1.setSuccessorHook(address(v2));
        _wireHook(v2);

        // Sanity: with legacy still connected, v2 blocks the transfer.
        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.transfer(bob, 1 ether);

        // Owner disconnects v2's legacy reference.
        vm.prank(hookManager);
        v2.disconnectLegacyHook();

        // legacyContribution now reads (0, 0).
        (uint256 legacyT, uint256 legacyR) = v2.legacyContribution(alice);
        assertEq(legacyT, 0);
        assertEq(legacyR, 0);

        // Transfer succeeds and emits no {LegacyHookDrained} event (no external call).
        vm.recordLogs();
        vm.prank(alice);
        concreteStandardVault.transfer(bob, 1 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 1 ether);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 drainedSig = keccak256("LegacyHookDrained(address,uint256,uint256)");
        for (uint256 i; i < entries.length; ++i) {
            assertTrue(
                entries[i].topics.length == 0 || entries[i].topics[0] != drainedSig,
                "no LegacyHookDrained after disconnect"
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Lock creation
    // ─────────────────────────────────────────────────────────────────────────────

    function test_deposit_createsLockAndEmits() public {
        _wireHook(hook);
        vm.prank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);

        uint64 expectedRedeemTs = uint64(block.timestamp + HARD_LOCK_DURATION);
        uint64 expectedTransferTs = expectedRedeemTs + REG_S_EXTENSION;
        // The inherited LockCreated event signature is (user, shares, unlockTimestamp, duration).
        // In Reg-S terms, unlockTimestamp is the transfer-unlock instant and duration is the
        // total (hard + Reg S extension).
        vm.expectEmit(true, true, true, true);
        emit DepositLockHook.LockCreated(alice, 10 ether, expectedTransferTs, TOTAL_DURATION);

        vm.prank(alice);
        concreteStandardVault.deposit(10 ether, alice);

        assertEq(hook.storedTransferLocked(alice), 10 ether);
        assertEq(hook.effectiveRedeemLocked(alice), 10 ether);
        assertEq(hook.storedLockCount(alice), 1);

        DepositLockHook.Lock memory lk = hook.getStoredLock(alice, 0);
        assertEq(uint256(lk.shares), 10 ether);
        assertEq(lk.unlockTimestamp, expectedTransferTs);
        assertEq(lk.duration, TOTAL_DURATION);
        // Redeem timestamp is derived, not stored.
        assertEq(hook.getStoredLockRedeemUnlockTimestamp(alice, 0), expectedRedeemTs);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // State machine: HARD_LOCKED → REDEEM_UNLOCKED → FULLY_UNLOCKED
    // ─────────────────────────────────────────────────────────────────────────────

    function test_hardLocked_blocksTransferAndRedeem() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockRegSHook.InsufficientTransferUnlocked.selector, alice, 1 ether, 0)
        );
        concreteStandardVault.transfer(bob, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockRegSHook.InsufficientRedeemUnlocked.selector, alice, 1 ether, 0)
        );
        concreteStandardVault.redeem(1 ether, alice, alice);
    }

    function test_regSWindow_allowsRedeemBlocksTransfer() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        // Transfer still blocked
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockRegSHook.InsufficientTransferUnlocked.selector, alice, 1 ether, 0)
        );
        concreteStandardVault.transfer(bob, 1 ether);

        // Redeem allowed
        vm.prank(alice);
        concreteStandardVault.redeem(5 ether, alice, alice);
        assertEq(concreteStandardVault.balanceOf(alice), 5 ether);
    }

    function test_fullyUnlocked_allowsBoth() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        vm.warp(block.timestamp + TOTAL_DURATION);

        vm.prank(alice);
        concreteStandardVault.transfer(bob, 3 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 3 ether);

        vm.prank(alice);
        concreteStandardVault.redeem(4 ether, alice, alice);

        // After both operations, lock fully expired & cleaned
        assertEq(hook.storedLockCount(alice), 0);
        assertEq(hook.storedTransferLocked(alice), 0);
        assertEq(hook.effectiveRedeemLocked(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Cancellation guard — the hook refuses to initialize or operate while the bound
    // vault still allows cancelling pending withdrawal requests (request-then-cancel
    // would otherwise recover Reg-S-locked shares free of the transfer restriction).
    // ─────────────────────────────────────────────────────────────────────────────

    function _mockVaultCancellationEnabled(bool enabled) internal {
        vm.mockCall(
            address(concreteStandardVault), abi.encodeWithSignature("cancellationEnabled()"), abi.encode(enabled)
        );
    }

    function test_cancellationGuard_initRevertsWhenVaultCancellationEnabled() public {
        _mockVaultCancellationEnabled(true);
        DepositLockRegSHook h = _cloneUninitialized();
        vm.expectRevert(DepositLockRegSHook.CancellationEnabled.selector);
        h.initialize(hookManager, HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
    }

    function test_cancellationGuard_initSucceedsWhenCancellationDisabled() public {
        // Default (base vault) reports cancellation disabled → initialize succeeds.
        DepositLockRegSHook h =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
        assertEq(h.VAULT(), address(concreteStandardVault));
    }

    function test_cancellationGuard_transferRevertsWhenCancellationEnabled() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);
        // Fully unlocked: a transfer would normally pass, isolating the guard as the blocker.
        vm.warp(block.timestamp + TOTAL_DURATION);

        _mockVaultCancellationEnabled(true);
        vm.prank(alice);
        vm.expectRevert(DepositLockRegSHook.CancellationEnabled.selector);
        concreteStandardVault.transfer(bob, 1 ether);
    }

    function test_cancellationGuard_redeemRevertsWhenCancellationEnabled() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);
        // Reg-S window: redeem is normally allowed, isolating the guard as the blocker.
        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        _mockVaultCancellationEnabled(true);
        vm.prank(alice);
        vm.expectRevert(DepositLockRegSHook.CancellationEnabled.selector);
        concreteStandardVault.redeem(1 ether, alice, alice);
    }

    function test_regSWindow_redeemPartialReducesTransferLock() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        vm.prank(alice);
        concreteStandardVault.redeem(4 ether, alice, alice);

        assertEq(hook.storedLockCount(alice), 1);
        assertEq(hook.storedTransferLocked(alice), 6 ether);
        assertEq(hook.effectiveRedeemLocked(alice), 0);

        // Remaining deposit residue is still transfer-restricted.
        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.transfer(bob, 1 ether);
    }

    function test_regSWindow_redeemDoesNotOverConsumeWhenUnlockedSharesBurnedFirst() public {
        _wireHook(hook);

        _depositAs(bob, 4 ether);
        vm.warp(block.timestamp + TOTAL_DURATION + 1);

        _depositAs(alice, 6 ether);
        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        vm.prank(bob);
        concreteStandardVault.transfer(alice, 4 ether);

        assertEq(concreteStandardVault.balanceOf(alice), 10 ether);
        assertEq(hook.storedTransferLocked(alice), 6 ether);

        // Redeem 8: 4 transfer-free (from bob) + 4 from the Reg-S-locked deposit residue.
        vm.prank(alice);
        concreteStandardVault.redeem(8 ether, alice, alice);

        assertEq(concreteStandardVault.balanceOf(alice), 2 ether);
        assertEq(hook.storedTransferLocked(alice), 2 ether);

        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.transfer(bob, 1 ether);
    }

    function test_regSWindow_redeemThenIncomingTransferCanTransfer() public {
        _wireHook(hook);

        // Charlie's deposit must fully expire before Alice's Reg-S scenario so his
        // transfer to Alice is not blocked by his own lock.
        _depositAs(bob, 4 ether);
        vm.warp(block.timestamp + TOTAL_DURATION + 1);

        _depositAs(alice, 10 ether);
        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        vm.prank(alice);
        concreteStandardVault.redeem(4 ether, alice, alice);
        assertEq(hook.storedTransferLocked(alice), 6 ether);

        vm.prank(bob);
        concreteStandardVault.transfer(alice, 4 ether);

        assertEq(concreteStandardVault.balanceOf(alice), 10 ether);
        assertEq(hook.getUnlockedTransferShares(alice), 4 ether);

        vm.prank(alice);
        concreteStandardVault.transfer(bob, 4 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 4 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Cleanup correctness across the two transitions
    // ─────────────────────────────────────────────────────────────────────────────

    function test_cleanup_isIdempotentAcrossTransitions() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        // First touchpoint that triggers cleanup (redeem during reg-s window).
        vm.prank(alice);
        concreteStandardVault.redeem(2 ether, alice, alice);

        uint256 effectiveRedeemBefore = hook.effectiveRedeemLocked(alice);
        assertEq(effectiveRedeemBefore, 0, "in middle window, no redeem lock");
        assertEq(hook.storedTransferLocked(alice), 8 ether);

        vm.prank(alice);
        concreteStandardVault.redeem(2 ether, alice, alice);

        assertEq(hook.storedTransferLocked(alice), 6 ether);
        assertEq(hook.effectiveRedeemLocked(alice), effectiveRedeemBefore);
    }

    function test_multipleLocks_redeemFromOldestFirstViaCleanup() public {
        _wireHook(hook);
        _depositAs(alice, 4 ether);
        vm.warp(block.timestamp + 1 days);
        _depositAs(alice, 6 ether);

        assertEq(hook.storedTransferLocked(alice), 10 ether);
        assertEq(hook.effectiveRedeemLocked(alice), 10 ether);
        assertEq(hook.storedLockCount(alice), 2);

        // Warp past lock 1's redeem unlock but before lock 1's transfer unlock and before lock 2 redeem unlock.
        // lock1 redeem unlock = T + 28d ; lock2 redeem unlock = T + 1d + 28d
        // Warp to T + 28d + 30s: lock1 in reg-s window, lock2 still hard-locked.
        vm.warp(block.timestamp - 1 days + HARD_LOCK_DURATION + 30);

        // Should be able to redeem lock1's 4 ether
        vm.prank(alice);
        concreteStandardVault.redeem(4 ether, alice, alice);

        // Lock2 should still be hard-locked
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockRegSHook.InsufficientRedeemUnlocked.selector, alice, 1 ether, 0)
        );
        concreteStandardVault.redeem(1 ether, alice, alice);
    }

    function test_durationDecrease_sortedInsertionAndCleanup() public {
        _wireHook(hook);

        // Lock 1: long hard lock at T
        _depositAs(alice, 5 ether);
        uint64 lock1TransferTs = hook.getStoredLock(alice, 0).unlockTimestamp;

        // Reduce hard lock dramatically
        vm.prank(hookManager);
        hook.setHardLockDuration(1 hours);
        vm.warp(block.timestamp + 1);

        // Lock 2 with much shorter hard lock at T+1
        _depositAs(alice, 3 ether);
        uint64 lock2TransferTs = hook.getStoredLock(alice, 0).unlockTimestamp;

        // Sorted insertion: lock 2 (earlier transferTs) should be at index 0.
        assertLt(lock2TransferTs, lock1TransferTs);
        assertEq(uint256(hook.getStoredLock(alice, 0).shares), 3 ether);
        assertEq(uint256(hook.getStoredLock(alice, 1).shares), 5 ether);

        // Warp past lock2's full unlock but before lock1's reg-s window.
        vm.warp(uint256(lock2TransferTs) + 1);

        // Transfer of lock2's 3 ether should succeed (lock2 fully unlocked)
        vm.prank(alice);
        concreteStandardVault.transfer(bob, 3 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 3 ether);

        // Cleanup should have removed lock2, leaving lock1
        assertEq(hook.storedLockCount(alice), 1);
        assertEq(uint256(hook.getStoredLock(alice, 0).shares), 5 ether);

        // Lock1 still fully locked: cannot transfer or redeem
        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.transfer(bob, 1 ether);
    }

    function test_multipleLocks_partialRedeemMaintainsTransferBlock() public {
        _wireHook(hook);

        _depositAs(alice, 4 ether);
        vm.warp(block.timestamp + 1 days);
        _depositAs(alice, 6 ether);

        // Warp into lock1's reg-s window (lock2 also in reg-s window by then, since lock2 was created 1 day later)
        vm.warp(block.timestamp - 1 days + HARD_LOCK_DURATION + 2 days);

        // Both locks should be in reg-s window now (since regS extension is 12 days)
        // lock1 redeem unlock = T + 28d, transfer unlock = T + 40d
        // lock2 redeem unlock = T + 29d, transfer unlock = T + 41d
        // We're at T + 30d → both in redeem-unlocked phase.
        assertEq(hook.effectiveRedeemLocked(alice), 0);
        assertGt(hook.effectiveTransferLocked(alice), 0);

        // Redeem 7 ether (spans both locks)
        vm.prank(alice);
        concreteStandardVault.redeem(7 ether, alice, alice);

        // Transfer still blocked for remaining 3 ether (transferTs not reached)
        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.transfer(bob, 1 ether);
    }

    // Regression for the `_consumeRegSRange` simplification (prefix removal driven by the
    // loop counter): a redeem that fully consumes the two oldest Reg-S locks and partially
    // consumes the third must compact the queue to a single survivor holding the residue,
    // preserving the survivor's original unlock timestamp.
    function test_multipleLocks_redeemConsumesFullPrefixThenPartial() public {
        _wireHook(hook);

        // Three locks created one day apart so the queue is [lock1, lock2, lock3] sorted by
        // unlock timestamp (same total duration ⇒ creation order == sort order).
        _depositAs(alice, 2 ether);
        vm.warp(block.timestamp + 1 days);
        _depositAs(alice, 3 ether);
        vm.warp(block.timestamp + 1 days);
        _depositAs(alice, 5 ether);

        assertEq(hook.storedLockCount(alice), 3);
        assertEq(hook.storedTransferLocked(alice), 10 ether);

        // Capture the third lock's transfer-unlock instant before the redeem so we can prove
        // it is the surviving entry afterwards.
        uint64 lock3TransferTs = hook.getStoredLock(alice, 2).unlockTimestamp;

        // Warp so all three locks are in their Reg-S window: past every redeem unlock
        // (latest is lock3 at creation+28d) but before every transfer unlock (earliest is
        // lock1 at creation+40d). We are at lock1-creation + 31d here.
        vm.warp(block.timestamp - 2 days + HARD_LOCK_DURATION + 3 days);

        assertEq(hook.effectiveRedeemLocked(alice), 0, "all three in Reg-S window");

        // Redeem 6: consumes lock1 (2) + lock2 (3) fully, then 1 of lock3's 5 (partial).
        vm.prank(alice);
        concreteStandardVault.redeem(6 ether, alice, alice);

        // Queue compacted to the single partial survivor.
        assertEq(hook.storedLockCount(alice), 1, "prefix of 2 fully-consumed locks dropped");
        assertEq(hook.storedTransferLocked(alice), 4 ether, "10 - 6 consumed");

        DepositLockHook.Lock memory survivor = hook.getStoredLock(alice, 0);
        assertEq(uint256(survivor.shares), 4 ether, "lock3 residue (5 - 1)");
        assertEq(survivor.unlockTimestamp, lock3TransferTs, "survivor is lock3, timestamp intact");

        assertEq(concreteStandardVault.balanceOf(alice), 4 ether);

        // The 4 ether residue is still Reg-S transfer-locked.
        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.transfer(bob, 1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Stored vs effective views
    // ─────────────────────────────────────────────────────────────────────────────

    function test_views_storedVsEffective() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        // Within hard lock: stored == effective for transfer; redeem is only effective.
        assertEq(hook.storedTransferLocked(alice), 10 ether);
        assertEq(hook.effectiveTransferLocked(alice), 10 ether);
        assertEq(hook.effectiveRedeemLocked(alice), 10 ether);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        // After hard lock: transfer still locked (stored == effective); redeem freed.
        assertEq(hook.storedTransferLocked(alice), 10 ether);
        assertEq(hook.effectiveTransferLocked(alice), 10 ether);
        assertEq(hook.effectiveRedeemLocked(alice), 0, "redeem free in middle window");

        vm.warp(block.timestamp + REG_S_EXTENSION);

        // After total duration: stored transfer still 10 (not cleaned), effective == 0.
        assertEq(hook.storedTransferLocked(alice), 10 ether, "stored not yet cleaned");
        assertEq(hook.effectiveTransferLocked(alice), 0);
        assertEq(hook.effectiveRedeemLocked(alice), 0);
        assertEq(hook.effectiveLockCount(alice), 0);
    }

    function test_views_unlockedShares() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        assertEq(hook.getUnlockedTransferShares(alice), 0);
        assertEq(hook.getUnlockedRedeemShares(alice), 0);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        assertEq(hook.getUnlockedTransferShares(alice), 0);
        assertEq(hook.getUnlockedRedeemShares(alice), 10 ether);

        vm.warp(block.timestamp + REG_S_EXTENSION);

        assertEq(hook.getUnlockedTransferShares(alice), 10 ether);
        assertEq(hook.getUnlockedRedeemShares(alice), 10 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Access control & overflow
    // ─────────────────────────────────────────────────────────────────────────────

    function test_postDeposit_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.postDeposit(address(0), 0, 1 ether, alice, 0);
    }

    function test_preTransfer_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.preTransfer(address(0), alice, bob, 1 ether);
    }

    function test_preRedeem_revertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(DepositLockHook.OnlyVaultOrHookContainer.selector);
        hook.preRedeem(address(0), 0, 1 ether, address(0), alice, 0);
    }

    function test_hookContainer_canCallHookFunctions() public {
        address container = makeAddr("container");
        vm.prank(hookManager);
        hook.setHookContainer(container);

        vm.prank(container);
        hook.postDeposit(address(0), 0, 1 ether, alice, 0);
        assertEq(hook.storedTransferLocked(alice), 1 ether);
        assertEq(hook.effectiveRedeemLocked(alice), 1 ether);
        assertEq(hook.storedLockCount(alice), 1);
    }

    function test_maxLocksExceeded_reverts() public {
        _wireHook(hook);
        vm.prank(hookManager);
        hook.setMaxLocksPerUser(2);

        _depositAs(alice, 1 ether);
        _depositAs(alice, 1 ether);

        vm.startPrank(alice);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(DepositLockHook.MaxLocksExceeded.selector, alice, 2, 2));
        concreteStandardVault.deposit(1 ether, alice);
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

    function test_setHardLockDuration_revertsOnSumOverflow() public {
        // `setHardLockDuration(uint64.max)` overflows when added to REG_S_EXTENSION inside the
        // setter (the sum is kept in uint64 to preserve the base's storage layout). Solidity 0.8+
        // surfaces this as a Panic(0x11).
        vm.prank(hookManager);
        vm.expectRevert(stdError.arithmeticError);
        hook.setHardLockDuration(type(uint64).max);
    }

    function test_unlockTimestampOverflow_reverts() public {
        // Pick a hard duration whose sum with REG_S_EXTENSION saturates uint64 exactly.
        // The setter succeeds (no Panic), but the next deposit's
        // `block.timestamp + (hard + regS)` then overflows and triggers the base's
        // `UnlockTimestampOverflow` check inside `_appendLock`.
        vm.startPrank(hookManager);
        hook.setHardLockDuration(type(uint64).max - REG_S_EXTENSION);
        address container = makeAddr("container");
        hook.setHookContainer(container);
        vm.stopPrank();

        vm.prank(container);
        vm.expectRevert(DepositLockHook.UnlockTimestampOverflow.selector);
        hook.postDeposit(address(0), 0, 1 ether, alice, 0);
    }

    function test_zeroSharesDeposit_createsNoLock() public {
        address container = makeAddr("container");
        vm.prank(hookManager);
        hook.setHookContainer(container);

        vm.prank(container);
        hook.postDeposit(address(0), 0, 0, alice, 0);
        assertEq(hook.storedLockCount(alice), 0);
        assertEq(hook.storedTransferLocked(alice), 0);
        assertEq(hook.effectiveRedeemLocked(alice), 0);
    }

    function test_zeroSharesTransfer_doesNotRevert() public {
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        vm.prank(alice);
        concreteStandardVault.transfer(bob, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // RegS extension == 0 (degenerate single-stage lock)
    // ─────────────────────────────────────────────────────────────────────────────

    function test_zeroRegSExtension_collapsesToSingleStage() public {
        DepositLockRegSHook h =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, 0, address(0));
        _wireHook(h);
        _depositAs(alice, 10 ether);

        // With zero Reg S extension, the derived redeem timestamp equals the stored
        // (transfer) unlock timestamp — the middle Reg S window collapses to zero length.
        DepositLockHook.Lock memory lk = h.getStoredLock(alice, 0);
        assertEq(h.getStoredLockRedeemUnlockTimestamp(alice, 0), lk.unlockTimestamp);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        // Both transfer and redeem unlock at the same time
        vm.prank(alice);
        h; // silence
        concreteStandardVault.transfer(bob, 1 ether);
        vm.prank(alice);
        concreteStandardVault.redeem(1 ether, alice, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Migration: drainAndGetLocked access control & semantics
    // ─────────────────────────────────────────────────────────────────────────────

    function test_drainAndGetLocked_revertsWhenSuccessorUnset() public {
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(DepositLockRegSHook.OnlySuccessorHook.selector);
        hook.drainAndGetLocked(alice, 0);
    }

    function test_drainAndGetLocked_revertsForNonSuccessorCaller() public {
        DepositLockRegSHook successor =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
        vm.prank(hookManager);
        hook.setSuccessorHook(address(successor));

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(DepositLockRegSHook.OnlySuccessorHook.selector);
        hook.drainAndGetLocked(alice, 0);
    }

    function test_drainAndGetLocked_returnsCleanedAggregates() public {
        // Wire base hook and deposit so alice has locks on v1.
        _wireHook(hook);
        _depositAs(alice, 10 ether);

        // Designate a successor address (impersonate it for the drain call).
        DepositLockRegSHook successor =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(0));
        vm.prank(hookManager);
        hook.setSuccessorHook(address(successor));

        // Drain before any expiry: aggregates remain at 10 ether each.
        vm.prank(address(successor));
        (uint256 t, uint256 r,) = hook.drainAndGetLocked(alice, 0);
        assertEq(t, 10 ether);
        assertEq(r, 10 ether);

        // Move past the reg-s window for redeem only.
        vm.warp(block.timestamp + HARD_LOCK_DURATION);

        vm.prank(address(successor));
        (t, r,) = hook.drainAndGetLocked(alice, 0);
        assertEq(t, 10 ether);
        assertEq(r, 0);

        // Move past full unlock.
        vm.warp(block.timestamp + REG_S_EXTENSION);

        vm.prank(address(successor));
        (t, r,) = hook.drainAndGetLocked(alice, 0);
        assertEq(t, 0);
        assertEq(r, 0);
        assertEq(hook.storedLockCount(alice), 0, "queue compacted by drain");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Migration: v2 reads legacy aggregates in enforcement
    // ─────────────────────────────────────────────────────────────────────────────

    function test_migration_v2EnforcementCombinesLegacyAndLocalLocks() public {
        // 1. Deploy v1 and wire it into the vault.
        DepositLockRegSHook v1 = hook;
        _wireHook(v1);

        // 2. Alice deposits via v1: 10 ether locked on v1.
        _depositAs(alice, 10 ether);
        assertEq(v1.storedTransferLocked(alice), 10 ether);

        // 3. Deploy v2 referencing v1 as legacy, configure v1.successorHook = v2.
        DepositLockRegSHook v2 =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(v1));
        vm.prank(hookManager);
        v1.setSuccessorHook(address(v2));

        // 4. Swap vault enforcement to v2 directly (in production this is via replaceHook on a container).
        _wireHook(v2);

        // 5. Even though v2 has no locks of its own for alice, transfer must still be blocked
        //    because v2 reads v1.drainAndGetLocked and adds the legacy contribution.
        vm.prank(alice);
        vm.expectRevert(); // InsufficientTransferUnlocked
        concreteStandardVault.transfer(bob, 1 ether);

        // 6. After full duration passes, v2 sees v1 fully drained and allows transfer.
        vm.warp(block.timestamp + TOTAL_DURATION);

        vm.expectEmit(true, false, false, true);
        emit DepositLockRegSHook.LegacyHookDrained(alice, 0, 0);

        vm.prank(alice);
        concreteStandardVault.transfer(bob, 1 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 1 ether);
    }

    function test_migration_redeemReducesLegacyRegSLocks() public {
        DepositLockRegSHook v1 = hook;
        _wireHook(v1);
        _depositAs(alice, 10 ether);

        DepositLockRegSHook v2 =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(v1));
        vm.prank(hookManager);
        v1.setSuccessorHook(address(v2));
        _wireHook(v2);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);
        assertEq(v1.storedTransferLocked(alice), 10 ether);

        vm.prank(alice);
        concreteStandardVault.redeem(4 ether, alice, alice);

        assertEq(v1.storedTransferLocked(alice), 6 ether);
        assertEq(v2.storedTransferLocked(alice), 0);
        assertEq(concreteStandardVault.balanceOf(alice), 6 ether);
        assertEq(v2.getUnlockedTransferShares(alice), 0);
    }

    function test_migration_v2EnforcesItsOwnLocksOnTopOfLegacy() public {
        // v1 has a partially-active lock for alice (10 ether, mid reg-s window).
        DepositLockRegSHook v1 = hook;
        _wireHook(v1);
        _depositAs(alice, 10 ether);
        vm.warp(block.timestamp + HARD_LOCK_DURATION); // alice now in v1's reg-s window

        DepositLockRegSHook v2 =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(v1));
        vm.prank(hookManager);
        v1.setSuccessorHook(address(v2));

        // Swap to v2; alice deposits fresh shares so v2 has its own lock.
        _wireHook(v2);
        _depositAs(alice, 5 ether);

        // v1 contributes: transferLocked = 10 ether, redeemLocked = 0.
        // v2 has its own: transferLocked = 5 ether, redeemLocked = 5 ether.
        // Total transfer-locked from alice = 15; redeem-locked = 5.
        // Alice balance = 15 (10 from v1 deposit + 5 from v2 deposit).
        // Free-to-redeem = 15 - 5 = 10. Free-to-transfer = 15 - 15 = 0.

        // Redeem of 10 should succeed (uses up the 10 redeem-free shares).
        vm.prank(alice);
        concreteStandardVault.redeem(10 ether, alice, alice);

        // Transfer of any amount should still fail.
        vm.prank(alice);
        vm.expectRevert();
        concreteStandardVault.transfer(bob, 1 ether);
    }

    function test_legacyContribution_returnsEffectiveAggregates() public {
        DepositLockRegSHook v1 = hook;
        _wireHook(v1);
        _depositAs(alice, 10 ether);

        DepositLockRegSHook v2 =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(v1));

        (uint256 legacyT, uint256 legacyR) = v2.legacyContribution(alice);
        assertEq(legacyT, 10 ether);
        assertEq(legacyR, 10 ether);

        vm.warp(block.timestamp + HARD_LOCK_DURATION);
        (legacyT, legacyR) = v2.legacyContribution(alice);
        assertEq(legacyT, 10 ether);
        assertEq(legacyR, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Migration: multi-step (v1 → v2 → disconnect → v3) — §6.5 / M-1 mitigation
    // ─────────────────────────────────────────────────────────────────────────────

    // Structural witness that after a v1 → v2 → disconnect → v3 cycle, v3 does NOT
    // cascade into v1's state. drainAndGetLocked is single-hop; the runbook requires
    // v2.disconnectLegacyHook() before v3 is wired, so the chain stays flat by
    // construction. If this test ever fails, the M-1 mitigation has regressed.
    function test_multiStepMigration_legacyChainStaysFlattenedAfterDisconnect() public {
        // 1. v1 has a real lock for alice.
        DepositLockRegSHook v1 = hook;
        _wireHook(v1);
        _depositAs(alice, 10 ether);
        assertEq(v1.storedTransferLocked(alice), 10 ether);

        // 2. v1 → v2 migration: v2 reads v1; swap enforcement to v2.
        DepositLockRegSHook v2 =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(v1));
        vm.prank(hookManager);
        v1.setSuccessorHook(address(v2));
        _wireHook(v2);

        // 3. Time elapses past v1's full duration so v1 is provably drained.
        vm.warp(block.timestamp + TOTAL_DURATION);

        // 4. Owner disconnects v1 from v2.
        vm.prank(hookManager);
        v2.disconnectLegacyHook();
        assertEq(address(v2.legacyHook()), address(0));

        // 5. v2 → v3 migration: v3 reads v2 (whose legacy is now address(0)); swap to v3.
        DepositLockRegSHook v3 =
            _deployHook(hookManager, address(concreteStandardVault), HARD_LOCK_DURATION, REG_S_EXTENSION, address(v2));
        vm.prank(hookManager);
        v2.setSuccessorHook(address(v3));
        _wireHook(v3);

        // 6. Alice deposits 5 more via v3 (creates a fresh hard-locked v3 entry).
        _depositAs(alice, 5 ether);
        assertEq(concreteStandardVault.balanceOf(alice), 15 ether);

        // 7. v3.legacyContribution(alice) MUST be (0, 0) — v2 has no own locks and its
        //    legacy slot is empty, so v3 sees nothing of v1's residual aggregate.
        (uint256 legacyT, uint256 legacyR) = v3.legacyContribution(alice);
        assertEq(legacyT, 0, "v3 must not see v1 transfer state through v2");
        assertEq(legacyR, 0, "v3 must not see v1 redeem state through v2");

        // 8. Free-to-transfer = 15 - 5 (v3 own) - 0 (legacy) = 10. Trying to transfer
        //    11 reverts with the explicit (requested, unlocked) pair.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositLockRegSHook.InsufficientTransferUnlocked.selector, alice, 11 ether, 10 ether)
        );
        concreteStandardVault.transfer(bob, 11 ether);

        // 9. Transferring exactly 10 succeeds — the v1-originated balance is free,
        //    while the v3 own lock still blocks the remaining 5.
        vm.prank(alice);
        concreteStandardVault.transfer(bob, 10 ether);
        assertEq(concreteStandardVault.balanceOf(bob), 10 ether);

        // 10. Structural proof of "no cascade": v1's stored aggregate stayed at 10 even
        //     though v3 ran a full enforcement cycle that drained v2. If v3 had
        //     cascaded into v1, _cleanupExpired on v1 would have removed alice's
        //     expired lock and cut v1.storedTransferLocked(alice) to 0. The fact that
        //     the aggregate is untouched proves v3 → v2 did not propagate to v1.
        assertEq(v1.storedTransferLocked(alice), 10 ether, "v1 was not touched by v3 enforcement");
    }
}
