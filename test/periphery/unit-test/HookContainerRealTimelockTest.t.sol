// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IHook} from "../../../src/interface/IHook.sol";
import {HookContainer} from "../../../src/periphery/hooks/HookContainer.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {TimelockContractTypesLib as CT} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockConfigurationLib as Config} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {TimelockRealBaseSetup} from "../../common/TimelockRealBaseSetup.t.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

/// @dev Minimal no-op hook used only so `addHook`/`removeHook` have a valid, vault-matching
///      target to register; none of its lifecycle callbacks are exercised in these tests.
contract NoopHook is IHook {
    address public immutable VAULT_ADDR;

    constructor(address vault_) {
        VAULT_ADDR = vault_;
    }

    function VAULT() external view returns (address) {
        return VAULT_ADDR;
    }

    function FACTORY() external pure returns (address) {
        return address(0);
    }

    function preDeposit(address, uint256, uint256, address, uint256) external pure {}
    function preMultiDeposit(address, address, uint256, uint256, uint256, address, uint256) external pure {}
    function preMint(address, uint256, uint256, address, uint256) external pure {}
    function preWithdraw(address, uint256, uint256, address, address, uint256) external pure {}
    function preRedeem(address, uint256, uint256, address, address, uint256) external pure {}
    function postDeposit(address, uint256, uint256, address, uint256) external pure {}
    function postMint(address, uint256, uint256, address, uint256) external pure {}
    function postWithdraw(address, uint256, uint256, address, uint256) external pure {}
    function postRedeem(address, uint256, uint256, address, uint256) external pure {}
    function preTransfer(address, address, address, uint256) external pure {}
    function postTransfer(address, address, address, uint256) external pure {}
}

/**
 * @title HookContainerRealTimelockTest
 * @notice Sanity-checks that `HookContainer`'s timelock-gated admin surface actually
 *         works end-to-end against a real {Timelock}: propose -> warp -> execute.
 *         Also exercises `HookContainer.removeHook()`, verifying the audit-driven change
 *         that treats hook removal as gated (`afterDelay`, TIER_2) rather than as an
 *         instant restrictive correction — see `doc/spec/Timelock.md` §9.
 *
 * @dev Regression test for the clone immutable-args / actionId corruption finding:
 *      `HookContainer._enforceDelay` forwarded the *entire* clone calldata tail
 *      (`msg.data[4:]`) to the timelock. For a `HookContainer` deployed via
 *      `ClonesWithImmutableArgs` (as `PeripheryFactory.cloneHook` does), the clone
 *      stub appends `[factory (20)][vault (20)][length (2)]` to the calldata of
 *      every call, so that 42-byte tail got hashed into the recomputed actionId.
 *      That id could never match the one `Timelock.propose` derives from the
 *      canonical, non-corrupted args — permanently bricking every
 *      `afterDelay`-gated function (`addHook`, `replaceHook`, `removeHook`,
 *      `setTimelock`, `grantRole`) on the container once `activateTimelock`
 *      (irreversible) had been called.
 *
 *      `_enforceDelay` now slices only up to `_getImmutableArgsOffset()`, so every
 *      proposal below is made with the plain, canonically ABI-encoded arguments —
 *      no clone-specific suffix has to be reproduced by the proposer.
 */
contract HookContainerRealTimelockTest is TimelockRealBaseSetup {
    HookContainer public container;
    NoopHook public hookA;
    NoopHook public hookB;

    address public containerAdmin;
    address public hookManager;
    address public dummyVault;

    function setUp() public {
        containerAdmin = makeAddr("containerAdmin");
        dummyVault = makeAddr("dummyVault");
        hookManager = makeAddr("hookManager");

        container = _deployContainer(containerAdmin, dummyVault);
        hookA = new NoopHook(dummyVault);
        hookB = new NoopHook(dummyVault);

        // Grant HOOK_MANAGER_ROLE and register both hooks before the timelock is active
        // (bootstrap window — `afterDelay` no-ops while `active == false`).
        vm.startPrank(containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, hookManager);
        container.addHook(address(hookA));
        container.addHook(address(hookB));
        vm.stopPrank();

        _deployTimelock();

        vm.prank(containerAdmin);
        container.setTimelock(address(timelock));

        // Binds the container to CT_HOOK_CONTAINER and activates the *Timelock's*
        // own global enforcement switch.
        _bindAndActivate(address(container), CT.CT_HOOK_CONTAINER);

        // Irreversibly activate the *container's* own timelock enforcement — the
        // point of no return referenced in the finding.
        vm.prank(containerAdmin);
        container.activateTimelock();
    }

    /// @dev Deploys a locked implementation, clones it (ClonesWithImmutableArgs) and initializes
    ///      the clone. Mirrors the pattern in `HookContainer.t.sol`, and — crucially for the
    ///      regression above — the `[factory (20)][vault (20)]` immutable args that
    ///      `PeripheryFactory.cloneHook` supplies in production.
    function _deployContainer(address admin_, address vault_) internal returns (HookContainer c) {
        HookContainer impl = new HookContainer();
        c = HookContainer(ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), vault_)));
        c.initialize(admin_);
    }

    // ── addHook — end-to-end through a real proposal ──────────────────────────

    /// @notice End-to-end sanity check: propose `addHook` on the real timelock, warp
    ///         past its TIER_2 delay, then execute. Demonstrates that at least one
    ///         `afterDelay`-gated function on `HookContainer` is actually usable
    ///         post-activation.
    /// @dev Prior to the fix this reverts with `UnknownAction` because `_enforceDelay`
    ///      hashes the clone's appended immutable-args tail into the recomputed
    ///      actionId, which never matches the one `propose` derived from the clean
    ///      `abi.encode(hook)` args — i.e. the timelock can never be satisfied.
    function test_addHook_succeedsViaRealTimelockProposal() public {
        NoopHook hook = new NoopHook(dummyVault);
        uint256 countBefore = container.getHooksCount();

        _proposeAndWarp(address(container), HookContainer.addHook.selector, abi.encode(address(hook)), TIER_2_DELAY);

        vm.prank(hookManager);
        container.addHook(address(hook));

        assertTrue(container.isHookRegistered(address(hook)), "hook should be registered after timelocked addHook");
        assertEq(container.getHooksCount(), countBefore + 1, "hook count should have grown by one");
    }

    /// @notice Companion negative-path check: calling `addHook` one second before its
    ///         proposal's `readyAt` must still revert `ActionNotReady`, not succeed.
    /// @dev This also guards against the fix over-correcting: with the actionId
    ///      corruption present, the call would instead revert `UnknownAction` (a
    ///      *different* error, since the recomputed id never matches the schedule
    ///      entry at all). Asserting `ActionNotReady` specifically only holds once the
    ///      recomputed action id genuinely matches the one `propose` derived, proving
    ///      the delay itself — not just the id mismatch — is what's being enforced.
    function test_addHook_revertsActionNotReadyBeforeDelay() public {
        NoopHook hook = new NoopHook(dummyVault);

        vm.prank(timelockAdmin);
        bytes32 actionId =
            timelock.propose(address(container), HookContainer.addHook.selector, abi.encode(address(hook)));
        uint256 ready = timelock.readyAt(actionId);

        // One second before maturity.
        vm.warp(ready - 1);

        vm.prank(hookManager);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, ready, ready - 1));
        container.addHook(address(hook));

        assertFalse(container.isHookRegistered(address(hook)), "hook must not be registered before delay matures");
    }

    // ── Artifact registry ─────────────────────────────────────────────────────

    function testArtifactsRegistered_removeHookIsTier2() public view {
        assertEq(
            timelock.artifactDelayTier(CT.CT_HOOK_CONTAINER, bytes32(HookContainer.removeHook.selector)), Config.TIER_2
        );
        // Matches the tier of the additive operations it now mirrors.
        assertEq(
            timelock.artifactDelayTier(CT.CT_HOOK_CONTAINER, bytes32(HookContainer.addHook.selector)),
            timelock.artifactDelayTier(CT.CT_HOOK_CONTAINER, bytes32(HookContainer.removeHook.selector))
        );
    }

    /// @dev Directly exercises the seeding helper wired into `reinitializeV3`, so an upgrade
    ///      applied to an already-deployed timelock re-registers `removeHook` at TIER_2 exactly
    ///      as a fresh `initialize` would.
    function testReinitializeV3_wiresRemoveHookToTier2() public {
        vm.prank(timelockAdmin);
        timelock.reinitializeV3();

        assertEq(
            timelock.artifactDelayTier(CT.CT_HOOK_CONTAINER, bytes32(HookContainer.removeHook.selector)), Config.TIER_2
        );
    }

    // ── removeHook — gated behind the timelock ────────────────────────────────

    function testRemoveHook_revertsWithoutProposal() public {
        bytes32 actionId =
            timelock.computeActionId(address(container), HookContainer.removeHook.selector, abi.encode(address(hookA)));

        vm.prank(containerAdmin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        container.removeHook(address(hookA));
    }

    function testRemoveHook_revertsBeforeDelayMatures() public {
        vm.prank(timelockAdmin);
        bytes32 actionId =
            timelock.propose(address(container), HookContainer.removeHook.selector, abi.encode(address(hookA)));

        // Warp partway through the TIER_2 delay — not yet matured.
        vm.warp(block.timestamp + TIER_2_DELAY / 2);

        uint256 readyAt_ = timelock.readyAt(actionId);
        vm.prank(containerAdmin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, readyAt_, block.timestamp));
        container.removeHook(address(hookA));
    }

    function testRemoveHook_succeedsAfterDelay() public {
        assertTrue(container.isHookRegistered(address(hookA)));

        _proposeAndWarp(address(container), HookContainer.removeHook.selector, abi.encode(address(hookA)), TIER_2_DELAY);

        vm.prank(containerAdmin);
        container.removeHook(address(hookA));

        assertFalse(container.isHookRegistered(address(hookA)));
        assertEq(container.getHooksCount(), 1);
    }

    function testRemoveHook_revertsUnauthorizedEvenWithMaturedProposal() public {
        _proposeAndWarp(address(container), HookContainer.removeHook.selector, abi.encode(address(hookA)), TIER_2_DELAY);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        container.removeHook(address(hookA));
    }
}
