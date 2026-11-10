// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {IERC1967} from "@openzeppelin-contracts/interfaces/IERC1967.sol";

import {Timelock} from "../../../src/periphery/timelock/Timelock.sol";
import {ITimelock} from "../../../src/periphery/interface/ITimelock.sol";
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TimelockContractTypesLib} from "../../../src/periphery/lib/TimelockContractTypesLib.sol";
import {TimelockRolesLib} from "../../../src/periphery/lib/TimelockRolesLib.sol";
import {TimelockConfigurationLib} from "../../../src/periphery/lib/TimelockConfigurationLib.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {ConcreteV2RolesLib} from "../../../src/lib/Roles.sol";

contract TimelockTest is Test {
    Timelock public timelock;

    address public admin;
    address public proposer;
    address public mockVault;
    address public stranger;
    address public account;

    // Constants pulled from {TimelockContractTypesLib} / {TimelockRolesLib} /
    // {TimelockConfigurationLib} — exposed as compile-time aliases for
    // readability.
    bytes4 internal constant CT_VAULT = TimelockContractTypesLib.CT_VAULT;
    bytes4 internal constant CT_TIMELOCK = TimelockContractTypesLib.CT_TIMELOCK;
    bytes32 internal constant PROPOSER_ROLE = TimelockRolesLib.PROPOSER_ROLE;
    bytes32 internal constant GUARDIAN_ROLE = TimelockRolesLib.GUARDIAN_ROLE;
    bytes32 internal constant CONFIG_ROLE = TimelockRolesLib.CONFIG_ROLE;
    bytes32 internal constant OVERRIDE_ROLE = TimelockRolesLib.OVERRIDE_ROLE;
    bytes32 internal constant UPGRADER_ROLE = TimelockRolesLib.UPGRADER_ROLE;
    bytes32 internal constant JANITOR_ROLE = TimelockRolesLib.JANITOR_ROLE;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes4 internal constant TIER_1 = TimelockConfigurationLib.TIER_1;
    bytes4 internal constant TIER_2 = TimelockConfigurationLib.TIER_2;
    bytes4 internal constant TIER_3 = TimelockConfigurationLib.TIER_3;
    uint256 internal constant TIER_1_DEFAULT = TimelockConfigurationLib.TIER_1_DEFAULT;
    uint256 internal constant TIER_2_DEFAULT = TimelockConfigurationLib.TIER_2_DEFAULT;
    uint256 internal constant TIER_3_DEFAULT = TimelockConfigurationLib.TIER_3_DEFAULT;

    uint256 internal MIN_DELAY;
    uint256 internal MAX_DELAY;
    uint256 internal STALENESS_WINDOW;

    function setUp() public {
        admin = makeAddr("admin");
        proposer = makeAddr("proposer");
        mockVault = makeAddr("mockVault");
        stranger = makeAddr("stranger");
        account = makeAddr("account");

        vm.label(admin, "admin");
        vm.label(proposer, "proposer");
        vm.label(mockVault, "mockVault");
        vm.label(stranger, "stranger");
        vm.label(account, "account");

        Timelock impl = new Timelock();
        bytes memory initData = abi.encodeCall(Timelock.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        timelock = Timelock(address(proxy));
        vm.label(address(timelock), "timelock");

        MIN_DELAY = timelock.MIN_DELAY();
        MAX_DELAY = timelock.MAX_DELAY();
        STALENESS_WINDOW = timelock.STALENESS_WINDOW();

        // Give a dedicated proposer (distinct from admin) so the auth path is
        // exercised explicitly.
        vm.prank(admin);
        timelock.grantRole(PROPOSER_ROLE, proposer);

        // Bind `mockVault` to `CT_VAULT` so vault-tier proposals can resolve.
        // `admin` is the bootstrap holder of `CONFIG_ROLE`.
        vm.prank(admin);
        timelock.bindContract(mockVault, CT_VAULT);
    }

    // ════════════════════════════════════════════════════════════════════════
    // computeActionId
    // ════════════════════════════════════════════════════════════════════════

    function test_computeActionId_matchesKeccakOfEncodedTuple() public view {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = abi.encode(uint256(123));

        bytes32 expected = keccak256(abi.encode(mockVault, selector, args));
        assertEq(timelock.computeActionId(mockVault, selector, args), expected);
    }

    function test_computeActionId_distinctPerTarget() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = abi.encode(uint256(1));
        address otherVault = makeAddr("otherVault");

        bytes32 a = timelock.computeActionId(mockVault, selector, args);
        bytes32 b = timelock.computeActionId(otherVault, selector, args);

        assertTrue(a != b, "actionId must depend on target");
    }

    function test_computeActionId_distinctPerSelector() public view {
        bytes memory args = abi.encode(uint256(1));

        bytes32 a = timelock.computeActionId(mockVault, IConcreteStandardVaultImpl.configure.selector, args);
        bytes32 b = timelock.computeActionId(mockVault, IConcreteStandardVaultImpl.setHooks.selector, args);

        assertTrue(a != b, "actionId must depend on selector");
    }

    function test_computeActionId_distinctPerArgs() public view {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;

        bytes32 a = timelock.computeActionId(mockVault, selector, abi.encode(uint256(1)));
        bytes32 b = timelock.computeActionId(mockVault, selector, abi.encode(uint256(2)));

        assertTrue(a != b, "actionId must depend on args");
    }

    // ════════════════════════════════════════════════════════════════════════
    // propose — function selector artifacts (seeded for CT_VAULT)
    // ════════════════════════════════════════════════════════════════════════

    function test_propose_configure_resolvesAtTier2() public {
        _proposeAndAssertSelector(IConcreteStandardVaultImpl.configure.selector, hex"deadbeef", TIER_2);
    }

    function test_propose_setHooks_resolvesAtTier2() public {
        _proposeAndAssertSelector(
            IConcreteStandardVaultImpl.setHooks.selector, abi.encode(makeAddr("hookManager")), TIER_2
        );
    }

    function test_propose_addStrategy_resolvesAtTier2() public {
        _proposeAndAssertSelector(
            IConcreteStandardVaultImpl.addStrategy.selector, abi.encode(address(0xBEEF), uint256(1)), TIER_2
        );
    }

    function test_propose_unpause_resolvesAtTier3() public {
        _proposeAndAssertSelector(ConcreteStandardVaultImpl.unpause.selector, hex"", TIER_3);
    }

    function test_propose_transferOwnership_resolvesAtTier1() public {
        _proposeAndAssertSelector(
            OwnableUpgradeable.transferOwnership.selector, abi.encode(makeAddr("newOwner")), TIER_1
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // propose — grantRole per-role artifacts
    // ════════════════════════════════════════════════════════════════════════

    function test_propose_grantRole_admin_resolvesAtTier1() public {
        _proposeGrantRoleAndAssert(ConcreteV2RolesLib.ROLE_ADMIN, TIER_1);
    }

    function test_propose_grantRole_vaultManager_resolvesAtTier1() public {
        _proposeGrantRoleAndAssert(ConcreteV2RolesLib.VAULT_MANAGER, TIER_1);
    }

    function test_propose_grantRole_hookManager_resolvesAtTier2() public {
        _proposeGrantRoleAndAssert(ConcreteV2RolesLib.HOOK_MANAGER, TIER_2);
    }

    function test_propose_grantRole_strategyManager_resolvesAtTier2() public {
        _proposeGrantRoleAndAssert(ConcreteV2RolesLib.STRATEGY_MANAGER, TIER_2);
    }

    function test_propose_grantRole_allocator_resolvesAtTier2() public {
        _proposeGrantRoleAndAssert(ConcreteV2RolesLib.ALLOCATOR, TIER_2);
    }

    function test_propose_grantRole_pauser_resolvesAtTier3() public {
        _proposeGrantRoleAndAssert(ConcreteV2RolesLib.PAUSER, TIER_3);
    }

    // ════════════════════════════════════════════════════════════════════════
    // propose — schedule / return value
    // ════════════════════════════════════════════════════════════════════════

    function test_propose_writesScheduleEntry() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";
        uint256 expectedReadyAt = block.timestamp + timelock.tierDelay(TIER_2);
        bytes32 expectedActionId = timelock.computeActionId(mockVault, selector, args);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        assertEq(actionId, expectedActionId, "returned actionId mismatch");
        assertEq(timelock.readyAt(actionId), expectedReadyAt, "schedule.readyAt mismatch");
    }

    // ════════════════════════════════════════════════════════════════════════
    // propose — error paths
    // ════════════════════════════════════════════════════════════════════════

    function test_propose_revertsOnZeroTarget() public {
        vm.prank(proposer);
        vm.expectRevert(ITimelock.ZeroAddress.selector);
        timelock.propose(address(0), IConcreteStandardVaultImpl.configure.selector, hex"");
    }

    function test_propose_revertsOnUnboundTarget() public {
        address unbound = makeAddr("unboundTarget");

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.TargetNotBound.selector, unbound));
        timelock.propose(unbound, IConcreteStandardVaultImpl.configure.selector, hex"");
    }

    function test_propose_revertsOnUnregisteredSelector() public {
        bytes4 selector = bytes4(keccak256("unregisteredFn()"));
        bytes32 artifact = bytes32(selector);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ArtifactNotRegistered.selector, CT_VAULT, artifact));
        timelock.propose(mockVault, selector, hex"");
    }

    function test_propose_revertsOnUnregisteredRoleArtifact() public {
        bytes32 unknownRole = keccak256("UNREGISTERED_ROLE");
        bytes memory args = abi.encode(unknownRole, account);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ArtifactNotRegistered.selector, CT_VAULT, unknownRole));
        timelock.propose(mockVault, IAccessControl.grantRole.selector, args);
    }

    function test_propose_revertsOnDuplicateAction() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.DuplicateAction.selector, actionId));
        timelock.propose(mockVault, selector, args);
    }

    function test_propose_revertsWhenCallerLacksProposerRole() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PROPOSER_ROLE)
        );
        timelock.propose(mockVault, IConcreteStandardVaultImpl.configure.selector, hex"");
    }

    // ════════════════════════════════════════════════════════════════════════
    // bindContract
    // ════════════════════════════════════════════════════════════════════════

    function test_bindContract_bindsTargetAndEmits() public {
        // `mockVault` is already bound in setUp; bind a fresh target here so we
        // can assert both the storage write and the emitted event.
        address newTarget = makeAddr("newTarget");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ContractBound(newTarget, CT_VAULT);

        vm.prank(admin);
        timelock.bindContract(newTarget, CT_VAULT);

        assertEq(timelock.contractTypeOf(newTarget), CT_VAULT, "binding not persisted");
    }

    function test_bindContract_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ITimelock.ZeroAddress.selector);
        timelock.bindContract(address(0), CT_VAULT);
    }

    function test_bindContract_revertsWhenAlreadyBound() public {
        // `mockVault` was bound to `CT_VAULT` in setUp.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.TargetAlreadyBound.selector, mockVault, CT_VAULT));
        timelock.bindContract(mockVault, CT_VAULT);
    }

    function test_bindContract_revertsWhenCallerLacksConfigRole() public {
        address newTarget = makeAddr("anotherTarget");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CONFIG_ROLE)
        );
        timelock.bindContract(newTarget, CT_VAULT);
    }

    function test_bindContract_notGatedAfterActivation() public {
        // `bindContract` is intentionally NOT self-timelocked: even with the
        // timelock active it executes immediately, with no prior {propose}
        // and no schedule entry to consume.
        _activate();

        address newTarget = makeAddr("newTarget");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ContractBound(newTarget, CT_VAULT);

        vm.prank(admin);
        timelock.bindContract(newTarget, CT_VAULT);

        assertEq(timelock.contractTypeOf(newTarget), CT_VAULT, "binding not persisted");
    }

    // ════════════════════════════════════════════════════════════════════════
    // unbindContract
    // ════════════════════════════════════════════════════════════════════════

    function test_unbindContract_unbindsTargetAndEmits() public {
        // `mockVault` was bound to `CT_VAULT` in setUp.
        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ContractUnbound(mockVault, CT_VAULT);

        vm.prank(admin);
        timelock.unbindContract(mockVault);

        assertEq(timelock.contractTypeOf(mockVault), bytes4(0), "binding not cleared");
    }

    function test_unbindContract_allowsRebindingAfterRemoval() public {
        vm.prank(admin);
        timelock.unbindContract(mockVault);

        // Re-binding the same slot should now succeed because the previous
        // entry was cleared (otherwise {bindContract} would revert
        // {TargetAlreadyBound}).
        vm.prank(admin);
        timelock.bindContract(mockVault, CT_VAULT);

        assertEq(timelock.contractTypeOf(mockVault), CT_VAULT, "rebinding not persisted");
    }

    function test_unbindContract_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ITimelock.ZeroAddress.selector);
        timelock.unbindContract(address(0));
    }

    function test_unbindContract_revertsWhenNotBound() public {
        address unbound = makeAddr("unboundTarget");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.TargetNotBound.selector, unbound));
        timelock.unbindContract(unbound);
    }

    function test_unbindContract_revertsWhenCallerLacksConfigRole() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CONFIG_ROLE)
        );
        timelock.unbindContract(mockVault);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Self-timelock registrations (CT_TIMELOCK)
    // ════════════════════════════════════════════════════════════════════════

    function test_init_selfTimelock_timelockIsBoundToCT_TIMELOCK() public view {
        assertEq(timelock.contractTypeOf(address(timelock)), CT_TIMELOCK, "timelock self-bind missing");
    }

    function test_init_selfTimelock_bindContractUnregistered() public view {
        bytes32 artifact = bytes32(Timelock.bindContract.selector);
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, artifact), bytes4(0), "bindContract must be unregistered");
    }

    function test_init_selfTimelock_unbindContractRegisteredAtTier2() public view {
        bytes32 artifact = bytes32(Timelock.unbindContract.selector);
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, artifact), TIER_2, "unbindContract tier mismatch");
    }

    function test_init_selfTimelock_updateTierDelayRegisteredAtTier1() public view {
        bytes32 artifact = bytes32(Timelock.updateTierDelay.selector);
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, artifact), TIER_1, "updateTierDelay tier mismatch");
    }

    function test_init_selfTimelock_addArtifactUnregistered() public view {
        bytes32 artifact = bytes32(Timelock.addArtifact.selector);
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, artifact), bytes4(0), "addArtifact must be unregistered");
    }

    function test_init_selfTimelock_changeTierRegisteredAtTier1() public view {
        bytes32 artifact = bytes32(Timelock.changeTier.selector);
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, artifact), TIER_1, "changeTier tier mismatch");
    }

    function test_init_selfTimelock_grantRoleConfigRegisteredAtTier2() public view {
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, CONFIG_ROLE), TIER_2, "CONFIG_ROLE tier mismatch");
    }

    function test_init_selfTimelock_grantRoleOverrideRegisteredAtTier1() public view {
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, OVERRIDE_ROLE), TIER_1, "OVERRIDE_ROLE tier mismatch");
    }

    function test_init_selfTimelock_grantRoleUpgraderRegisteredAtTier1() public view {
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, UPGRADER_ROLE), TIER_1, "UPGRADER_ROLE tier mismatch");
    }

    function test_init_selfTimelock_grantRoleDefaultAdminRegisteredAtTier1() public view {
        assertEq(
            timelock.artifactDelayTier(CT_TIMELOCK, DEFAULT_ADMIN_ROLE), TIER_1, "DEFAULT_ADMIN_ROLE tier mismatch"
        );
    }

    function test_init_selfTimelock_exemptRolesUnregistered() public view {
        assertEq(
            timelock.artifactDelayTier(CT_TIMELOCK, PROPOSER_ROLE), bytes4(0), "PROPOSER_ROLE must be unregistered"
        );
        assertEq(
            timelock.artifactDelayTier(CT_TIMELOCK, GUARDIAN_ROLE), bytes4(0), "GUARDIAN_ROLE must be unregistered"
        );
        assertEq(timelock.artifactDelayTier(CT_TIMELOCK, JANITOR_ROLE), bytes4(0), "JANITOR_ROLE must be unregistered");
    }

    function test_init_tierDelayDefaultsSeeded() public view {
        assertEq(timelock.tierDelay(TIER_1), TIER_1_DEFAULT, "TIER_1 default missing");
        assertEq(timelock.tierDelay(TIER_2), TIER_2_DEFAULT, "TIER_2 default missing");
        assertEq(timelock.tierDelay(TIER_3), TIER_3_DEFAULT, "TIER_3 default missing");
    }

    // ════════════════════════════════════════════════════════════════════════
    // activateTimelock
    // ════════════════════════════════════════════════════════════════════════

    function test_activateTimelock_setsActiveAndEmits() public {
        assertFalse(timelock.isActive(), "should start inactive");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.TimelockActivated();

        vm.prank(admin);
        timelock.activateTimelock();

        assertTrue(timelock.isActive(), "active flag not flipped");
    }

    function test_activateTimelock_revertsIfAlreadyActive() public {
        vm.prank(admin);
        timelock.activateTimelock();

        vm.prank(admin);
        vm.expectRevert(ITimelock.AlreadyActive.selector);
        timelock.activateTimelock();
    }

    function test_activateTimelock_revertsWhenCallerLacksAdminRole() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        timelock.activateTimelock();
    }

    // ════════════════════════════════════════════════════════════════════════
    // checkDelayExpired (direct calls)
    // ════════════════════════════════════════════════════════════════════════

    function test_checkDelayExpired_noopsWhileInactive() public {
        // Pre-activation: any direct call returns silently regardless of
        // caller / selector / args (the deployment-window escape hatch).
        timelock.checkDelayExpired(bytes4(0xdeadbeef), hex"");
    }

    function test_checkDelayExpired_postActivation_revertsUnknownActionForMissingSchedule() public {
        // Bind this test contract so it clears the trust gate and reaches the
        // schedule lookup (an unbound caller would revert `TargetNotBound`).
        vm.prank(admin);
        timelock.bindContract(address(this), CT_VAULT);

        _activate();

        bytes4 selector = bytes4(0xdeadbeef);
        bytes memory args = hex"";
        // `msg.sender` of the direct call is this test contract.
        bytes32 expectedActionId = timelock.computeActionId(address(this), selector, args);

        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        timelock.checkDelayExpired(selector, args);
    }

    function test_checkDelayExpired_postActivation_revertsActionNotReadyBeforeReadyAt() public {
        _activate();

        bytes4 selector = Timelock.unbindContract.selector;
        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), selector, args);
        uint256 ready = timelock.readyAt(actionId);

        // Call via the timelock proxy so `msg.sender` of checkDelayExpired
        // equals `address(timelock)` (the bound target). Warp to just before
        // the schedule matures.
        vm.warp(ready - 1);

        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, ready, ready - 1));
        vm.prank(address(timelock));
        timelock.checkDelayExpired(selector, args);
    }

    function test_stalenessWindow_isTwoWeeks() public view {
        // Hardcoded by design (no governance lever) — pin the value so any
        // accidental change fails loudly.
        assertEq(STALENESS_WINDOW, 2 weeks, "STALENESS_WINDOW drift");
    }

    function test_checkDelayExpired_postActivation_consumableAtStalenessBoundary() public {
        // The boundary is inclusive — at exactly `readyAt + STALENESS_WINDOW`
        // the action is still consumable. Symmetric to the `ActionNotReady`
        // check which uses strict `<` at the lower bound.
        _activate();

        bytes4 selector = Timelock.unbindContract.selector;
        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), selector, args);
        uint256 ready = timelock.readyAt(actionId);

        vm.warp(ready + STALENESS_WINDOW);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(address(timelock));
        timelock.checkDelayExpired(selector, args);

        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed at boundary");
    }

    function test_checkDelayExpired_postActivation_revertsActionStaleJustPastBoundary() public {
        _activate();

        bytes4 selector = Timelock.unbindContract.selector;
        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), selector, args);
        uint256 ready = timelock.readyAt(actionId);
        uint256 staleAt = ready + STALENESS_WINDOW;

        // One second past the inclusive boundary.
        vm.warp(staleAt + 1);

        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionStale.selector, actionId, staleAt, staleAt + 1));
        vm.prank(address(timelock));
        timelock.checkDelayExpired(selector, args);

        assertTrue(timelock.readyAt(actionId) != 0, "stale entry should not be cleared by the failed check");
    }

    // ════════════════════════════════════════════════════════════════════════
    // afterDelay — self-timelocked functions, happy path
    // ════════════════════════════════════════════════════════════════════════

    function test_afterDelay_unbindContract_succeedsOncePostActivation() public {
        _activate();

        // `mockVault` was already bound in setUp; propose its removal.
        bytes memory args = abi.encode(mockVault);
        bytes32 actionId = _proposeAndWarp(address(timelock), Timelock.unbindContract.selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ContractUnbound(mockVault, CT_VAULT);

        vm.prank(admin);
        timelock.unbindContract(mockVault);

        assertEq(timelock.contractTypeOf(mockVault), bytes4(0), "binding not cleared");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    function test_afterDelay_upgradeToAndCall_succeedsOncePostActivation() public {
        _activate();

        // Spin up a fresh implementation to upgrade the proxy to.
        Timelock newImpl = new Timelock();
        bytes memory args = abi.encode(address(newImpl), bytes(""));
        bytes32 actionId = _proposeAndWarp(address(timelock), UUPSUpgradeable.upgradeToAndCall.selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.TimelockUpgradeAuthorized(address(newImpl), admin);
        vm.expectEmit(true, true, true, true, address(timelock));
        emit IERC1967.Upgraded(address(newImpl));

        vm.prank(admin);
        timelock.upgradeToAndCall(address(newImpl), "");

        // ERC1967 implementation slot — verify the pointer was swapped.
        bytes32 storedImpl = vm.load(address(timelock), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        assertEq(address(uint160(uint256(storedImpl))), address(newImpl), "implementation pointer not updated");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ════════════════════════════════════════════════════════════════════════
    // afterDelay — shared error paths (exercised via unbindContract)
    // ════════════════════════════════════════════════════════════════════════

    function test_afterDelay_revertsActionNotReadyBeforeDelay() public {
        _activate();

        // `mockVault` was bound in setUp; propose its removal as the vehicle.
        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), Timelock.unbindContract.selector, args);
        uint256 ready = timelock.readyAt(actionId);

        // One second before maturity.
        vm.warp(ready - 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, ready, ready - 1));
        timelock.unbindContract(mockVault);
    }

    function test_afterDelay_revertsUnknownActionWithoutPropose() public {
        _activate();

        bytes memory args = abi.encode(mockVault);
        bytes32 expectedActionId = timelock.computeActionId(address(timelock), Timelock.unbindContract.selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, expectedActionId));
        timelock.unbindContract(mockVault);
    }

    function test_afterDelay_revertsActionStaleAfterWindow() public {
        // End-to-end staleness check through the {afterDelay} modifier: an
        // action that matured but lingered past `STALENESS_WINDOW` is no
        // longer consumable, even when the caller holds the right role.
        _activate();

        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), Timelock.unbindContract.selector, args);
        uint256 ready = timelock.readyAt(actionId);
        uint256 staleAt = ready + STALENESS_WINDOW;

        vm.warp(staleAt + 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionStale.selector, actionId, staleAt, staleAt + 1));
        timelock.unbindContract(mockVault);

        // No state change — the stale entry is still on the books and only
        // {cancel} or {overrideTimelock} can dispose of it.
        assertTrue(timelock.readyAt(actionId) != 0, "stale entry should not be cleared by the failed call");
        assertEq(timelock.contractTypeOf(mockVault), CT_VAULT, "binding must not have been removed");
    }

    function test_cancel_clearsStaleEntry() public {
        // Guardian can always clean up a stale entry — cancel never consults
        // `readyAt` so it is unaffected by the staleness gate.
        _activate();

        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), Timelock.unbindContract.selector, args);
        vm.warp(timelock.readyAt(actionId) + STALENESS_WINDOW + 1);

        vm.prank(admin);
        timelock.cancel(actionId);

        assertEq(timelock.readyAt(actionId), 0, "cancel did not clear stale entry");
    }

    function test_overrideTimelock_revivesStaleEntry() public {
        // `overrideTimelock` is the only path to revive a stale action: it
        // re-stamps `readyAt` to `block.timestamp`, opening a fresh
        // `STALENESS_WINDOW`.
        _activate();

        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), Timelock.unbindContract.selector, args);
        uint256 originalReady = timelock.readyAt(actionId);
        vm.warp(originalReady + STALENESS_WINDOW + 1);

        vm.prank(admin);
        timelock.overrideTimelock(actionId);
        assertEq(timelock.readyAt(actionId), block.timestamp, "override did not re-stamp readyAt");

        // Now consumable again — even though the original `readyAt` is far
        // in the past, the override has reset the window.
        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        timelock.unbindContract(mockVault);

        assertEq(timelock.contractTypeOf(mockVault), bytes4(0), "binding not cleared after revival");
        assertEq(timelock.readyAt(actionId), 0, "revived entry not consumed");
    }

    // ════════════════════════════════════════════════════════════════════════
    // cancel (defensive, NOT self-timelocked)
    // ════════════════════════════════════════════════════════════════════════

    function test_cancel_clearsScheduleAndEmits() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);
        assertTrue(timelock.readyAt(actionId) != 0, "pre-condition: schedule entry should exist");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Canceled(actionId);

        vm.prank(admin);
        timelock.cancel(actionId);

        assertEq(timelock.readyAt(actionId), 0, "schedule not cleared");
    }

    function test_cancel_revertsOnUnknownAction() public {
        bytes32 phantomActionId = keccak256("phantom");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, phantomActionId));
        timelock.cancel(phantomActionId);
    }

    function test_cancel_revertsOnDoubleCancel() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        vm.prank(admin);
        timelock.cancel(actionId);

        // Second cancel: entry was deleted by the first call.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        timelock.cancel(actionId);
    }

    function test_cancel_revertsWhenCallerLacksGuardianRole() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, GUARDIAN_ROLE)
        );
        timelock.cancel(actionId);
    }

    function test_cancel_worksBeforeReadyAt() public {
        // Demonstrates the defensive property: the Guardian can invalidate a
        // queued action before its delay matures (no `afterDelay` modifier).
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        uint256 ready = timelock.readyAt(actionId);
        assertGt(ready, block.timestamp, "pre-condition: schedule should be in the future");

        vm.prank(admin);
        timelock.cancel(actionId);

        assertEq(timelock.readyAt(actionId), 0, "cancel did not clear schedule before delay elapsed");
    }

    function test_cancel_preventsSubsequentConsumption() public {
        _activate();

        bytes memory args = abi.encode(mockVault);
        bytes32 actionId = _proposeAndWarp(address(timelock), Timelock.unbindContract.selector, args);

        vm.prank(admin);
        timelock.cancel(actionId);

        // The matured-but-canceled action must no longer satisfy `afterDelay`:
        // checkDelayExpired finds no schedule entry → `UnknownAction`.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        timelock.unbindContract(mockVault);
    }

    function test_cancel_allowsRePropose() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        vm.prank(admin);
        timelock.cancel(actionId);

        // Same `(target, selector, args)` should produce the same `actionId`
        // and be re-schedulable now that the prior entry is gone (otherwise
        // {propose} would revert {DuplicateAction}).
        vm.prank(proposer);
        bytes32 newActionId = timelock.propose(mockVault, selector, args);

        assertEq(newActionId, actionId, "actionId should be deterministic");
        assertTrue(timelock.readyAt(newActionId) != 0, "re-proposed schedule should be written");
    }

    function test_afterDelay_revertsUnknownActionOnReConsumption() public {
        _activate();

        // `mockVault` was bound in setUp; the first call consumes the schedule
        // entry and unbinds it.
        bytes memory args = abi.encode(mockVault);
        bytes32 actionId = _proposeAndWarp(address(timelock), Timelock.unbindContract.selector, args);

        vm.prank(admin);
        timelock.unbindContract(mockVault);

        // Second invocation: the entry was consumed by the first call, so the
        // modifier should now revert {UnknownAction} on the recomputed id
        // before the body could trip {TargetNotBound}.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        timelock.unbindContract(mockVault);
    }

    // ════════════════════════════════════════════════════════════════════════
    // updateTierDelay (self-timelocked at TIER_1)
    // ════════════════════════════════════════════════════════════════════════

    // All "pre-activation" tests below rely on `checkDelayExpired` being a
    // no-op while `active == false` — the `afterDelay` modifier is still
    // applied, but it does not require a queued schedule entry. This lets us
    // exercise the validation surface in isolation. The post-activation happy
    // path further down covers the self-timelock integration.

    function test_updateTierDelay_setsDelayAndEmits_tier1() public {
        uint256 newDelay = 36 hours; // > TIER_2_DEFAULT (24h), maintains TIER_1 > TIER_2

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.TierDelayUpdated(TIER_1, TIER_1_DEFAULT, newDelay);

        vm.prank(admin);
        timelock.updateTierDelay(TIER_1, newDelay);

        assertEq(timelock.tierDelay(TIER_1), newDelay, "TIER_1 delay not written");
    }

    function test_updateTierDelay_setsDelayAndEmits_tier3() public {
        uint256 newDelay = 18 hours; // < TIER_2_DEFAULT (24h), maintains TIER_2 > TIER_3

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.TierDelayUpdated(TIER_3, TIER_3_DEFAULT, newDelay);

        vm.prank(admin);
        timelock.updateTierDelay(TIER_3, newDelay);

        assertEq(timelock.tierDelay(TIER_3), newDelay, "TIER_3 delay not written");
    }

    function test_updateTierDelay_revertsDelayBelowMin() public {
        uint256 belowMin = MIN_DELAY - 1;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.DelayOutOfBounds.selector, belowMin, MIN_DELAY, MAX_DELAY));
        timelock.updateTierDelay(TIER_1, belowMin);
    }

    function test_updateTierDelay_revertsDelayAboveMax() public {
        uint256 aboveMax = MAX_DELAY + 1;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.DelayOutOfBounds.selector, aboveMax, MIN_DELAY, MAX_DELAY));
        timelock.updateTierDelay(TIER_3, aboveMax);
    }

    // ── Tier ordering invariant (TIER_1 > TIER_2 > TIER_3) ──────────────────

    function test_updateTierDelay_revertsWhenTier1DelayNotGreaterThanTier2() public {
        // Set TIER_1 to equal TIER_2_DEFAULT — violates TIER_1 > TIER_2.
        uint256 violating = TIER_2_DEFAULT; // 24h, same as TIER_2

        vm.prank(admin);
        vm.expectRevert(ITimelock.TierOrderViolation.selector);
        timelock.updateTierDelay(TIER_1, violating);
    }

    function test_updateTierDelay_revertsWhenTier2DelayNotGreaterThanTier3() public {
        // Set TIER_2 to equal TIER_3_DEFAULT — violates TIER_2 > TIER_3.
        uint256 violating = TIER_3_DEFAULT; // 12h, same as TIER_3

        vm.prank(admin);
        vm.expectRevert(ITimelock.TierOrderViolation.selector);
        timelock.updateTierDelay(TIER_2, violating);
    }

    function test_updateTierDelay_revertsWhenTier3DelayExceedsTier2() public {
        // Set TIER_3 above TIER_2 — violates TIER_2 > TIER_3.
        uint256 violating = TIER_2_DEFAULT + 1 hours; // above TIER_2

        vm.prank(admin);
        vm.expectRevert(ITimelock.TierOrderViolation.selector);
        timelock.updateTierDelay(TIER_3, violating);
    }

    function test_updateTierDelay_revertsUnknownTier_zero() public {
        bytes4 unknown = bytes4(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownTier.selector, unknown));
        timelock.updateTierDelay(unknown, 8 hours);
    }

    function test_updateTierDelay_revertsUnknownTier_arbitraryCode() public {
        bytes4 unknown = bytes4(0xdeadbeef);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownTier.selector, unknown));
        timelock.updateTierDelay(unknown, 8 hours);
    }

    function test_updateTierDelay_revertsWhenCallerLacksConfigRole() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CONFIG_ROLE)
        );
        timelock.updateTierDelay(TIER_1, 8 hours);
    }

    function test_afterDelay_updateTierDelay_succeedsOncePostActivation() public {
        _activate();

        uint256 newDelay = 36 hours; // > TIER_2_DEFAULT (24h), maintains TIER_1 > TIER_2
        bytes memory args = abi.encode(TIER_1, newDelay);
        bytes32 actionId = _proposeAndWarp(address(timelock), Timelock.updateTierDelay.selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.TierDelayUpdated(TIER_1, TIER_1_DEFAULT, newDelay);

        vm.prank(admin);
        timelock.updateTierDelay(TIER_1, newDelay);

        assertEq(timelock.tierDelay(TIER_1), newDelay, "TIER_1 delay not written");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    function test_afterDelay_updateTierDelay_revertsActionNotReadyBeforeDelay() public {
        _activate();

        uint256 newDelay = 8 hours;
        bytes memory args = abi.encode(TIER_1, newDelay);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), Timelock.updateTierDelay.selector, args);
        uint256 ready = timelock.readyAt(actionId);

        // updateTierDelay is gated by TIER_1 (48h by default), so a propose
        // with no warp must not be consumable.
        assertEq(ready, block.timestamp + TIER_1_DEFAULT, "expected TIER_1 delay");
        vm.warp(ready - 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, ready, ready - 1));
        timelock.updateTierDelay(TIER_1, newDelay);
    }

    // ════════════════════════════════════════════════════════════════════════
    // addArtifact (self-timelocked at TIER_3)
    // ════════════════════════════════════════════════════════════════════════

    // `addArtifact` is intentionally NOT self-timelocked, so its behaviour is
    // identical before and after {activateTimelock}; the cases below exercise the
    // validation surface directly, and a dedicated post-activation case
    // confirms it stays ungated.

    function test_addArtifact_registersSelectorAndEmits() public {
        bytes4 newContractType = bytes4(0xcafebabe);
        bytes32 newArtifact = bytes32(bytes4(0xdeadbeef));

        assertEq(timelock.artifactDelayTier(newContractType, newArtifact), bytes4(0), "pre-condition: should be unset");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ArtifactRegistered(newContractType, newArtifact, TIER_2);

        vm.prank(admin);
        timelock.addArtifact(newContractType, newArtifact, TIER_2);

        assertEq(timelock.artifactDelayTier(newContractType, newArtifact), TIER_2, "tier not written");
    }

    function test_addArtifact_registersRoleArtifact() public {
        // Roles use the full 32-byte hash as the artifact key; verify the
        // encoding works through the same entry point as selector artifacts.
        bytes4 newContractType = bytes4(0xcafebabe);
        bytes32 roleArtifact = keccak256("SOME_CUSTOM_ROLE");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ArtifactRegistered(newContractType, roleArtifact, TIER_3);

        vm.prank(admin);
        timelock.addArtifact(newContractType, roleArtifact, TIER_3);

        assertEq(timelock.artifactDelayTier(newContractType, roleArtifact), TIER_3, "role tier not written");
    }

    function test_addArtifact_revertsArtifactAlreadyRegistered() public {
        // `configure` is seeded at TIER_2 under CT_VAULT in {initialize}.
        bytes32 existingArtifact = bytes32(IConcreteStandardVaultImpl.configure.selector);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ITimelock.ArtifactAlreadyRegistered.selector, CT_VAULT, existingArtifact)
        );
        timelock.addArtifact(CT_VAULT, existingArtifact, TIER_1);
    }

    function test_addArtifact_revertsArtifactAlreadyRegistered_forSeededRole() public {
        // Per-role artifact for `ROLE_ADMIN` is seeded at TIER_1 under CT_VAULT.
        bytes32 seededRole = ConcreteV2RolesLib.ROLE_ADMIN;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ArtifactAlreadyRegistered.selector, CT_VAULT, seededRole));
        timelock.addArtifact(CT_VAULT, seededRole, TIER_2);
    }

    function test_addArtifact_revertsUnknownTier_zero() public {
        bytes4 newContractType = bytes4(0xcafebabe);
        bytes32 newArtifact = bytes32(bytes4(0xdeadbeef));
        bytes4 unknown = bytes4(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownTier.selector, unknown));
        timelock.addArtifact(newContractType, newArtifact, unknown);
    }

    function test_addArtifact_revertsUnknownTier_arbitraryCode() public {
        bytes4 newContractType = bytes4(0xcafebabe);
        bytes32 newArtifact = bytes32(bytes4(0xdeadbeef));
        bytes4 unknown = bytes4(0x12345678);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownTier.selector, unknown));
        timelock.addArtifact(newContractType, newArtifact, unknown);
    }

    function test_addArtifact_revertsWhenCallerLacksConfigRole() public {
        bytes4 newContractType = bytes4(0xcafebabe);
        bytes32 newArtifact = bytes32(bytes4(0xdeadbeef));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CONFIG_ROLE)
        );
        timelock.addArtifact(newContractType, newArtifact, TIER_1);
    }

    function test_addArtifact_notGatedAfterActivation() public {
        // `addArtifact` is intentionally NOT self-timelocked: even with the
        // timelock active it executes immediately, with no prior {propose}
        // and no schedule entry to consume.
        _activate();

        bytes4 newContractType = bytes4(0xcafebabe);
        bytes32 newArtifact = bytes32(bytes4(0xdeadbeef));

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ArtifactRegistered(newContractType, newArtifact, TIER_2);

        vm.prank(admin);
        timelock.addArtifact(newContractType, newArtifact, TIER_2);

        assertEq(timelock.artifactDelayTier(newContractType, newArtifact), TIER_2, "tier not written");
    }

    // ════════════════════════════════════════════════════════════════════════
    // changeTier (self-timelocked at TIER_1)
    // ════════════════════════════════════════════════════════════════════════

    // `changeTier` IS self-timelocked: `afterDelay` no-ops while
    // `active == false`, so behavioural cases can be exercised without going
    // through {propose}/{warp}. The post-activation happy path further down
    // covers the self-timelock integration.

    function test_changeTier_updatesRegistrationAndEmits() public {
        // `configure` is seeded at TIER_2 under CT_VAULT in {initialize}.
        bytes32 artifact = bytes32(IConcreteStandardVaultImpl.configure.selector);

        assertEq(timelock.artifactDelayTier(CT_VAULT, artifact), TIER_2, "pre-condition: should be seeded");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ArtifactTierChanged(CT_VAULT, artifact, TIER_2, TIER_1);

        vm.prank(admin);
        timelock.changeTier(CT_VAULT, artifact, TIER_1);

        assertEq(timelock.artifactDelayTier(CT_VAULT, artifact), TIER_1, "tier not updated");
    }

    function test_changeTier_updatesRoleArtifact() public {
        // Per-role artifact for `ROLE_ADMIN` is seeded at TIER_1 under CT_VAULT.
        bytes32 roleArtifact = ConcreteV2RolesLib.ROLE_ADMIN;

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ArtifactTierChanged(CT_VAULT, roleArtifact, TIER_1, TIER_2);

        vm.prank(admin);
        timelock.changeTier(CT_VAULT, roleArtifact, TIER_2);

        assertEq(timelock.artifactDelayTier(CT_VAULT, roleArtifact), TIER_2, "role tier not updated");
    }

    function test_changeTier_acceptsNoOpToSameTier() public {
        // Re-asserting the current tier is intentionally a valid no-op write —
        // the event is still emitted so off-chain indexers can confirm the
        // operation was processed. Simpler semantics than special-casing it.
        bytes32 artifact = bytes32(IConcreteStandardVaultImpl.configure.selector);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ArtifactTierChanged(CT_VAULT, artifact, TIER_2, TIER_2);

        vm.prank(admin);
        timelock.changeTier(CT_VAULT, artifact, TIER_2);

        assertEq(timelock.artifactDelayTier(CT_VAULT, artifact), TIER_2, "tier should be unchanged");
    }

    function test_changeTier_revertsArtifactNotRegistered() public {
        bytes4 unknownContractType = bytes4(0xcafebabe);
        bytes32 unknownArtifact = bytes32(bytes4(0xdeadbeef));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ITimelock.ArtifactNotRegistered.selector, unknownContractType, unknownArtifact)
        );
        timelock.changeTier(unknownContractType, unknownArtifact, TIER_1);
    }

    function test_changeTier_revertsUnknownTier_zero() public {
        // `bytes4(0)` is rejected by the same `_requireKnownTier` helper as
        // {addArtifact} — removal is intentionally not exposed through this
        // entry point.
        bytes32 artifact = bytes32(IConcreteStandardVaultImpl.configure.selector);
        bytes4 unknown = bytes4(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownTier.selector, unknown));
        timelock.changeTier(CT_VAULT, artifact, unknown);
    }

    function test_changeTier_revertsUnknownTier_arbitraryCode() public {
        bytes32 artifact = bytes32(IConcreteStandardVaultImpl.configure.selector);
        bytes4 unknown = bytes4(0x12345678);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownTier.selector, unknown));
        timelock.changeTier(CT_VAULT, artifact, unknown);
    }

    function test_changeTier_unknownTierRejectedBeforeArtifactCheck() public {
        // Tier validity is checked before the registry lookup, so an
        // unknown-tier call against an unregistered artifact surfaces
        // {UnknownTier}, not {ArtifactNotRegistered}.
        bytes4 unknownContractType = bytes4(0xcafebabe);
        bytes32 unknownArtifact = bytes32(bytes4(0xdeadbeef));
        bytes4 unknownTier = bytes4(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownTier.selector, unknownTier));
        timelock.changeTier(unknownContractType, unknownArtifact, unknownTier);
    }

    function test_changeTier_revertsWhenCallerLacksConfigRole() public {
        bytes32 artifact = bytes32(IConcreteStandardVaultImpl.configure.selector);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CONFIG_ROLE)
        );
        timelock.changeTier(CT_VAULT, artifact, TIER_1);
    }

    function test_changeTier_affectsSubsequentProposalDelay() public {
        // After re-tiering, a fresh {propose} for the same artifact must
        // resolve the new tier's delay — proves the change actually flows
        // through {propose}'s `artifactDelayTier` lookup.
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes32 artifact = bytes32(selector);

        vm.prank(admin);
        timelock.changeTier(CT_VAULT, artifact, TIER_1);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, hex"");

        assertEq(timelock.readyAt(actionId), block.timestamp + TIER_1_DEFAULT, "propose did not pick up new tier delay");
    }

    function test_afterDelay_changeTier_succeedsOncePostActivation() public {
        _activate();

        bytes32 artifact = bytes32(IConcreteStandardVaultImpl.configure.selector);
        bytes memory args = abi.encode(CT_VAULT, artifact, TIER_1);
        bytes32 actionId = _proposeAndWarp(address(timelock), Timelock.changeTier.selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ArtifactTierChanged(CT_VAULT, artifact, TIER_2, TIER_1);

        vm.prank(admin);
        timelock.changeTier(CT_VAULT, artifact, TIER_1);

        assertEq(timelock.artifactDelayTier(CT_VAULT, artifact), TIER_1, "tier not updated");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    function test_afterDelay_changeTier_revertsActionNotReadyBeforeDelay() public {
        _activate();

        bytes32 artifact = bytes32(IConcreteStandardVaultImpl.configure.selector);
        bytes memory args = abi.encode(CT_VAULT, artifact, TIER_1);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), Timelock.changeTier.selector, args);
        uint256 ready = timelock.readyAt(actionId);

        // changeTier is gated by TIER_1 (48h by default).
        assertEq(ready, block.timestamp + TIER_1_DEFAULT, "expected TIER_1 delay");
        vm.warp(ready - 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, ready, ready - 1));
        timelock.changeTier(CT_VAULT, artifact, TIER_1);
    }

    // ════════════════════════════════════════════════════════════════════════
    // overrideTimelock (defensive, NOT self-timelocked)
    // ════════════════════════════════════════════════════════════════════════

    function test_overrideTimelock_isNotSelfTimelocked() public view {
        // The break-glass lever must never live behind the same delay machinery
        // it short-circuits — guard against a future {addArtifact} entry
        // accidentally re-protecting it.
        bytes32 artifact = bytes32(Timelock.overrideTimelock.selector);
        assertEq(
            timelock.artifactDelayTier(CT_TIMELOCK, artifact), bytes4(0), "overrideTimelock must remain unregistered"
        );
    }

    function test_overrideTimelock_compressesReadyAtAndEmits() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        uint256 originalReady = timelock.readyAt(actionId);
        assertGt(originalReady, block.timestamp, "pre-condition: schedule should be in the future");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Overridden(actionId, block.timestamp);

        vm.prank(admin);
        timelock.overrideTimelock(actionId);

        assertEq(timelock.readyAt(actionId), block.timestamp, "readyAt not compressed to now");
    }

    function test_overrideTimelock_revertsUnknownAction() public {
        bytes32 phantomActionId = keccak256("phantom");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, phantomActionId));
        timelock.overrideTimelock(phantomActionId);
    }

    function test_overrideTimelock_revertsAfterConsumption() public {
        // Once consumed by {checkDelayExpired}, the entry is deleted and looks
        // identical to a never-proposed action — same `UnknownAction` revert.
        _activate();

        bytes memory args = abi.encode(mockVault);
        bytes32 actionId = _proposeAndWarp(address(timelock), Timelock.unbindContract.selector, args);

        vm.prank(admin);
        timelock.unbindContract(mockVault);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        timelock.overrideTimelock(actionId);
    }

    function test_overrideTimelock_revertsWhenCallerLacksOverrideRole() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OVERRIDE_ROLE)
        );
        timelock.overrideTimelock(actionId);
    }

    function test_overrideTimelock_allowsImmediateConsumption() public {
        // End-to-end: propose → override → consume *without warping*. Proves
        // the override actually unblocks the {afterDelay} modifier rather than
        // just touching storage. Run post-activation so {checkDelayExpired}
        // enforces the schedule.
        _activate();

        bytes memory args = abi.encode(mockVault);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), Timelock.unbindContract.selector, args);

        vm.prank(admin);
        timelock.overrideTimelock(actionId);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);
        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.ContractUnbound(mockVault, CT_VAULT);

        vm.prank(admin);
        timelock.unbindContract(mockVault);

        assertEq(timelock.contractTypeOf(mockVault), bytes4(0), "binding not cleared");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    function test_overrideTimelock_canBeCanceledByGuardianAfterOverride() public {
        // Defensive interaction: even after the override has compressed
        // `readyAt`, the Guardian retains the ability to {cancel} before
        // anyone executes — both safety levers stay independent.
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        vm.prank(admin);
        timelock.overrideTimelock(actionId);
        assertEq(timelock.readyAt(actionId), block.timestamp, "pre-condition: should be matured");

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Canceled(actionId);

        vm.prank(admin);
        timelock.cancel(actionId);

        assertEq(timelock.readyAt(actionId), 0, "cancel did not clear overridden schedule");
    }

    function test_overrideTimelock_isIdempotent() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        vm.prank(admin);
        timelock.overrideTimelock(actionId);
        uint256 firstReady = timelock.readyAt(actionId);

        // Advance one block and override again — `readyAt` should track the
        // new `block.timestamp`. Confirms the function rewrites the slot
        // unconditionally rather than checking for an already-matured entry.
        vm.warp(block.timestamp + 1 hours);

        vm.prank(admin);
        timelock.overrideTimelock(actionId);

        assertGt(timelock.readyAt(actionId), firstReady, "second override should re-stamp readyAt");
        assertEq(timelock.readyAt(actionId), block.timestamp, "second override should compress to new now");
    }

    // ════════════════════════════════════════════════════════════════════════
    // pruneStale (automation / JANITOR_ROLE, NOT self-timelocked)
    // ════════════════════════════════════════════════════════════════════════

    function test_pruneStale_removesStaleEntryAndEmits() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        // Advance past readyAt + STALENESS_WINDOW so the entry is stale.
        uint256 staleAt = timelock.readyAt(actionId) + STALENESS_WINDOW;
        vm.warp(staleAt + 1);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Pruned(actionId);

        vm.prank(admin);
        timelock.pruneStale(actionId);

        assertEq(timelock.readyAt(actionId), 0, "stale entry not cleared");
    }

    function test_pruneStale_revertsIfNotYetStale() public {
        bytes4 selector = IConcreteStandardVaultImpl.configure.selector;
        bytes memory args = hex"abcd";

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        // Warp to exactly readyAt — the entry is matured but still within the
        // staleness window, so pruneStale must reject it.
        uint256 readyAt_ = timelock.readyAt(actionId);
        uint256 staleAt = readyAt_ + STALENESS_WINDOW;
        vm.warp(readyAt_);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ITimelock.ActionNotYetStale.selector, actionId, staleAt, block.timestamp)
        );
        timelock.pruneStale(actionId);
    }

    // ════════════════════════════════════════════════════════════════════════
    // grantRole (self-timelocked for CONFIG / OVERRIDE / UPGRADER roles)
    // ════════════════════════════════════════════════════════════════════════

    function test_grantRole_proposerRole_exemptFromDelay() public {
        _activate();

        vm.prank(admin);
        timelock.grantRole(PROPOSER_ROLE, account);

        assertTrue(timelock.hasRole(PROPOSER_ROLE, account), "PROPOSER_ROLE not granted");
    }

    function test_grantRole_guardianRole_exemptFromDelay() public {
        _activate();

        vm.prank(admin);
        timelock.grantRole(GUARDIAN_ROLE, account);

        assertTrue(timelock.hasRole(GUARDIAN_ROLE, account), "GUARDIAN_ROLE not granted");
    }

    function test_grantRole_janitorRole_exemptFromDelay() public {
        _activate();

        vm.prank(admin);
        timelock.grantRole(JANITOR_ROLE, account);

        assertTrue(timelock.hasRole(JANITOR_ROLE, account), "JANITOR_ROLE not granted");
    }

    function test_grantRole_configRole_revertsWithoutProposalPostActivation() public {
        _activate();

        bytes memory args = abi.encode(CONFIG_ROLE, account);
        bytes32 actionId = timelock.computeActionId(address(timelock), IAccessControl.grantRole.selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        timelock.grantRole(CONFIG_ROLE, account);
    }

    function test_grantRole_configRole_succeedsViaProposalPostActivation() public {
        _activate();

        bytes memory args = abi.encode(CONFIG_ROLE, account);
        bytes32 actionId = _proposeAndWarp(address(timelock), IAccessControl.grantRole.selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        timelock.grantRole(CONFIG_ROLE, account);

        assertTrue(timelock.hasRole(CONFIG_ROLE, account), "CONFIG_ROLE not granted");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    function test_grantRole_configRole_resolvesAtTier2() public {
        bytes memory args = abi.encode(CONFIG_ROLE, account);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), IAccessControl.grantRole.selector, args);

        assertEq(timelock.readyAt(actionId), block.timestamp + TIER_2_DEFAULT, "expected TIER_2 delay");
    }

    function test_grantRole_overrideRole_succeedsViaProposalPostActivation() public {
        _activate();

        bytes memory args = abi.encode(OVERRIDE_ROLE, account);
        _proposeAndWarp(address(timelock), IAccessControl.grantRole.selector, args);

        vm.prank(admin);
        timelock.grantRole(OVERRIDE_ROLE, account);

        assertTrue(timelock.hasRole(OVERRIDE_ROLE, account), "OVERRIDE_ROLE not granted");
    }

    function test_grantRole_upgraderRole_succeedsViaProposalPostActivation() public {
        _activate();

        bytes memory args = abi.encode(UPGRADER_ROLE, account);
        _proposeAndWarp(address(timelock), IAccessControl.grantRole.selector, args);

        vm.prank(admin);
        timelock.grantRole(UPGRADER_ROLE, account);

        assertTrue(timelock.hasRole(UPGRADER_ROLE, account), "UPGRADER_ROLE not granted");
    }

    function test_grantRole_configRole_revertsActionNotReadyBeforeDelay() public {
        _activate();

        bytes memory args = abi.encode(CONFIG_ROLE, account);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), IAccessControl.grantRole.selector, args);
        uint256 ready = timelock.readyAt(actionId);
        vm.warp(ready - 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, ready, ready - 1));
        timelock.grantRole(CONFIG_ROLE, account);
    }

    function test_grantRole_configRole_exemptBeforeActivation() public {
        // While inactive, checkDelayExpired is a no-op so even gated roles can
        // be granted without a prior proposal during bootstrap.
        vm.prank(admin);
        timelock.grantRole(CONFIG_ROLE, account);

        assertTrue(timelock.hasRole(CONFIG_ROLE, account), "CONFIG_ROLE not granted pre-activation");
    }

    // ── DEFAULT_ADMIN_ROLE (self-timelocked at TIER_1) ──────────────────────

    function test_grantRole_defaultAdminRole_resolvesAtTier1() public {
        // DEFAULT_ADMIN_ROLE is seeded under CT_TIMELOCK at TIER_1, so a
        // grantRole proposal for it must mature over the TIER_1 delay.
        bytes memory args = abi.encode(DEFAULT_ADMIN_ROLE, account);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), IAccessControl.grantRole.selector, args);

        assertEq(timelock.readyAt(actionId), block.timestamp + TIER_1_DEFAULT, "expected TIER_1 delay");
    }

    function test_grantRole_defaultAdminRole_revertsWithoutProposalPostActivation() public {
        _activate();

        bytes memory args = abi.encode(DEFAULT_ADMIN_ROLE, account);
        bytes32 actionId = timelock.computeActionId(address(timelock), IAccessControl.grantRole.selector, args);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.UnknownAction.selector, actionId));
        timelock.grantRole(DEFAULT_ADMIN_ROLE, account);
    }

    function test_grantRole_defaultAdminRole_revertsActionNotReadyBeforeDelay() public {
        // Core assertion for the self-timelock: granting DEFAULT_ADMIN_ROLE is
        // blocked until the TIER_1 delay has fully elapsed.
        _activate();

        bytes memory args = abi.encode(DEFAULT_ADMIN_ROLE, account);

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(address(timelock), IAccessControl.grantRole.selector, args);
        uint256 ready = timelock.readyAt(actionId);

        assertEq(ready, block.timestamp + TIER_1_DEFAULT, "expected TIER_1 delay");

        // One second before maturity — must still be rejected.
        vm.warp(ready - 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITimelock.ActionNotReady.selector, actionId, ready, ready - 1));
        timelock.grantRole(DEFAULT_ADMIN_ROLE, account);

        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, account), "DEFAULT_ADMIN_ROLE must not be granted early");
    }

    function test_grantRole_defaultAdminRole_succeedsViaProposalPostActivation() public {
        _activate();

        bytes memory args = abi.encode(DEFAULT_ADMIN_ROLE, account);
        bytes32 actionId = _proposeAndWarp(address(timelock), IAccessControl.grantRole.selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Consumed(actionId);

        vm.prank(admin);
        timelock.grantRole(DEFAULT_ADMIN_ROLE, account);

        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, account), "DEFAULT_ADMIN_ROLE not granted");
        assertEq(timelock.readyAt(actionId), 0, "schedule entry not consumed");
    }

    // ════════════════════════════════════════════════════════════════════════
    // revokeRole / renounceRole — last-admin protection
    // ════════════════════════════════════════════════════════════════════════

    function test_revokeRole_cannotRemoveLastAdmin() public {
        // `admin` is the sole DEFAULT_ADMIN_ROLE holder from {initialize}.
        assertEq(timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "pre-condition: single admin");

        vm.prank(admin);
        vm.expectRevert(Timelock.CannotRemoveLastAdmin.selector);
        timelock.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin must retain DEFAULT_ADMIN_ROLE");
    }

    function test_renounceRole_cannotRemoveLastAdmin() public {
        // {renounceRole} funnels through the same `_revokeRole` hook.
        assertEq(timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "pre-condition: single admin");

        vm.prank(admin);
        vm.expectRevert(Timelock.CannotRemoveLastAdmin.selector);
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin must retain DEFAULT_ADMIN_ROLE");
    }

    function test_revokeRole_succeedsWhenMultipleAdmins() public {
        // Grant a second admin during bootstrap (checkDelayExpired is a no-op
        // while inactive), after which removing one is allowed.
        vm.prank(admin);
        timelock.grantRole(DEFAULT_ADMIN_ROLE, account);
        assertEq(timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2, "pre-condition: two admins");

        vm.prank(admin);
        timelock.revokeRole(DEFAULT_ADMIN_ROLE, account);

        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, account), "second admin not removed");
        assertEq(timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin count should drop to 1");
    }

    function test_renounceRole_succeedsWhenMultipleAdmins() public {
        vm.prank(admin);
        timelock.grantRole(DEFAULT_ADMIN_ROLE, account);
        assertEq(timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2, "pre-condition: two admins");

        // With two admins, one can renounce its own role.
        vm.prank(admin);
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin should have renounced");
        assertEq(timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin count should drop to 1");
    }

    // ════════════════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Flips `active` to `true` via the real {activateTimelock} function.
    function _activate() internal {
        vm.prank(admin);
        timelock.activateTimelock();
    }

    /// @dev Schedules `(target, selector, args)` via {propose} as `proposer`,
    ///      then warps `block.timestamp` to the resulting `readyAt`. Returns
    ///      the `actionId` so callers can assert against it.
    function _proposeAndWarp(address target, bytes4 selector, bytes memory args) internal returns (bytes32 actionId) {
        vm.prank(proposer);
        actionId = timelock.propose(target, selector, args);
        vm.warp(timelock.readyAt(actionId));
    }

    /// @dev Drives a `propose` call for an ordinary function selector and
    ///      asserts the emitted {Proposed} event, returned `actionId`, and the
    ///      written `readyAt` against the seeded tier.
    function _proposeAndAssertSelector(bytes4 selector, bytes memory args, bytes4 expectedTier) internal {
        bytes32 artifact = bytes32(selector);
        uint256 expectedReadyAt = block.timestamp + timelock.tierDelay(expectedTier);
        bytes32 expectedActionId = timelock.computeActionId(mockVault, selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Proposed(
            expectedActionId, mockVault, CT_VAULT, selector, artifact, args, expectedTier, expectedReadyAt
        );

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        assertEq(actionId, expectedActionId, "returned actionId mismatch");
        assertEq(timelock.readyAt(actionId), expectedReadyAt, "readyAt mismatch");
    }

    /// @dev Same as {_proposeAndAssertSelector} but for `grantRole` — the
    ///      artifact is the role itself (per `_artifactFor`'s special case).
    function _proposeGrantRoleAndAssert(bytes32 role, bytes4 expectedTier) internal {
        bytes4 selector = IAccessControl.grantRole.selector;
        bytes memory args = abi.encode(role, account);
        bytes32 artifact = role;
        uint256 expectedReadyAt = block.timestamp + timelock.tierDelay(expectedTier);
        bytes32 expectedActionId = timelock.computeActionId(mockVault, selector, args);

        vm.expectEmit(true, true, true, true, address(timelock));
        emit ITimelock.Proposed(
            expectedActionId, mockVault, CT_VAULT, selector, artifact, args, expectedTier, expectedReadyAt
        );

        vm.prank(proposer);
        bytes32 actionId = timelock.propose(mockVault, selector, args);

        assertEq(actionId, expectedActionId, "returned actionId mismatch");
        assertEq(timelock.readyAt(actionId), expectedReadyAt, "readyAt mismatch");
    }
}
