// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "../../../src/interface/IHook.sol";
import {HooksLibV2} from "../../../src/lib/Hooks.sol";
import {BaseHook} from "../../../src/periphery/hooks/BaseHook.sol";
import {HookContainer} from "../../../src/periphery/hooks/HookContainer.sol";
import {MultiAssetDepositCapHook} from "../../../src/periphery/hooks/MultiAssetDepositCapHook.sol";
import {UserDepositCapHook} from "../../../src/periphery/hooks/UserDepositCapHook.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {ContractIdEncoding} from "../../../src/lib/ContractIdEncoding.sol";
import {
    MultiAssetNonBaseDepositBase
} from "../../unit-test/ConcreteMultiAssetDepositAsyncVault/MultiAssetNonBaseDepositUnitTest.t.sol";
import {ERC20DecimalsMock} from "../../mock/ERC20DecimalsMock.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

/**
 * @dev Fully-wired multi-asset vault (pricer + live strategy + whitelisted `otherAsset`) with a
 *      {MultiAssetDepositCapHook} clone installed as the vault's direct hook target on the
 *      `PRE_MULTI_DEPOSIT` flag. This test contract acts as the factory authorized to initialize
 *      the clones.
 */
contract MultiAssetDepositCapHookTest is MultiAssetNonBaseDepositBase {
    MultiAssetDepositCapHook internal capHook;

    address internal hookOwner;

    function setUp() public virtual override {
        super.setUp();

        _whitelist(address(otherAsset));
        _setPricer();
        _setStrategy();

        hookOwner = makeAddr("hookOwner");
        capHook = _deployCapHook(hookOwner);

        _setVaultHookTarget(address(capHook));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _deployCapHook(address owner_) internal returns (MultiAssetDepositCapHook h) {
        MultiAssetDepositCapHook impl = new MultiAssetDepositCapHook();
        // Immutable args mirror the factory layout: [factory (20)][vault (20)].
        h = MultiAssetDepositCapHook(
            ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), address(multiAssetVault)))
        );
        h.initialize(owner_);
    }

    function _setVaultHookTarget(address target) internal {
        Hooks memory hooks = Hooks({target: target, flags: uint96(1) << HooksLibV2.PRE_MULTI_DEPOSIT});
        vm.prank(hookManager);
        multiAssetVault.setHooks(hooks);
    }

    function _setCap(address token, uint256 cap) internal {
        vm.prank(hookOwner);
        capHook.setDepositCap(token, cap);
    }

    function _depositOther(uint256 amount) internal returns (uint256) {
        vm.prank(user1);
        return multiAssetVault.deposit(address(otherAsset), amount, user1);
    }

    /// @dev Whitelists a freshly deployed token, mints it to `user1` and approves the vault.
    function _newWhitelistedToken(uint8 decimals, uint256 mintAmount) internal returns (ERC20DecimalsMock token) {
        token = new ERC20DecimalsMock(decimals);
        token.mint(user1, mintAmount);
        vm.prank(user1);
        token.approve(address(multiAssetVault), type(uint256).max);
        _whitelist(address(token));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Identity & initialization
    // ═════════════════════════════════════════════════════════════════════════════

    function test_identity() public view {
        assertEq(capHook.FLAVOUR(), 9, "unexpected flavour");
        // Version literals are bumped by scripts/bump-version-diff.js, so assert that ID() is composed
        // from CONTRACT_TYPE / FLAVOUR() / VERSION() rather than pinning a release number here.
        (uint256 major, uint256 minor, uint256 patch) = capHook.VERSION();
        assertEq(
            capHook.ID(),
            ContractIdEncoding.encode(capHook.CONTRACT_TYPE(), capHook.FLAVOUR(), major, minor, patch),
            "ID does not match type/flavour/version"
        );
        assertEq(capHook.VAULT(), address(multiAssetVault), "vault immutable arg mismatch");
        assertEq(capHook.owner(), hookOwner, "owner not set");
    }

    function test_init_everyTokenStartsUncapped() public view {
        assertEq(capHook.getRawDepositCap(address(otherAsset)), 0);
        (bool capped, uint256 cap) = capHook.getDepositCap(address(otherAsset));
        assertFalse(capped, "token should start uncapped");
        assertEq(cap, 0);
        assertEq(capHook.totalDeposited(address(otherAsset)), 0);
    }

    function test_init_revertsWhenCallerNotFactory() public {
        MultiAssetDepositCapHook impl = new MultiAssetDepositCapHook();
        MultiAssetDepositCapHook newHook = MultiAssetDepositCapHook(
            ClonesWithImmutableArgs.clone(
                address(impl), abi.encodePacked(makeAddr("otherFactory"), address(multiAssetVault))
            )
        );
        vm.expectRevert(BaseHook.NotFactory.selector);
        newHook.initialize(hookOwner);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Offset-by-1 cap encoding
    // ═════════════════════════════════════════════════════════════════════════════

    function test_setCap_storesOffsetByOne() public {
        _setCap(address(otherAsset), 422);

        assertEq(capHook.getRawDepositCap(address(otherAsset)), 423, "raw cap not offset by one");
        (bool capped, uint256 cap) = capHook.getDepositCap(address(otherAsset));
        assertTrue(capped);
        assertEq(cap, 422, "decoded cap mismatch");
    }

    function test_setCap_zeroCapIsDistinctFromUncapped() public {
        _setCap(address(otherAsset), 0);

        assertEq(capHook.getRawDepositCap(address(otherAsset)), 1, "cap of zero must store as 1");
        (bool capped, uint256 cap) = capHook.getDepositCap(address(otherAsset));
        assertTrue(capped, "cap of zero must read as capped");
        assertEq(cap, 0);

        // A cap of zero blocks every deposit of that token.
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiAssetDepositCapHook.TokenDepositCapExceeded.selector,
                address(otherAsset),
                DEPOSIT_AMOUNT,
                uint256(0)
            )
        );
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function test_clearCap_restoresUnlimited() public {
        _setCap(address(otherAsset), 0);

        vm.prank(hookOwner);
        capHook.removeCap(address(otherAsset));

        assertEq(capHook.getRawDepositCap(address(otherAsset)), 0);
        (bool capped,) = capHook.getDepositCap(address(otherAsset));
        assertFalse(capped, "cap should be cleared");

        _depositOther(DEPOSIT_AMOUNT);
        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT);
    }

    function test_clearCap_keepsRollingSum() public {
        _depositOther(DEPOSIT_AMOUNT);
        _setCap(address(otherAsset), 10 * DEPOSIT_AMOUNT);

        vm.prank(hookOwner);
        capHook.removeCap(address(otherAsset));

        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT, "clearing a cap must not reset the sum");
    }

    function test_setCap_revertsOnMaxUint() public {
        vm.prank(hookOwner);
        vm.expectRevert(abi.encodeWithSelector(MultiAssetDepositCapHook.CapTooLarge.selector, type(uint256).max));
        capHook.setDepositCap(address(otherAsset), type(uint256).max);
    }

    function test_setCap_revertsOnZeroToken() public {
        vm.prank(hookOwner);
        vm.expectRevert(BaseHook.ZeroAddress.selector);
        capHook.setDepositCap(address(0), 1 ether);
    }

    function test_setCap_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(capHook));
        emit MultiAssetDepositCapHook.DepositCapSet(address(otherAsset), 0, 422);
        vm.prank(hookOwner);
        capHook.setDepositCap(address(otherAsset), 422);

        // The previous value is reported decoded, not offset.
        vm.expectEmit(true, true, true, true, address(capHook));
        emit MultiAssetDepositCapHook.DepositCapSet(address(otherAsset), 422, 999);
        vm.prank(hookOwner);
        capHook.setDepositCap(address(otherAsset), 999);

        vm.expectEmit(true, true, true, true, address(capHook));
        emit MultiAssetDepositCapHook.DepositCapCleared(address(otherAsset), 999);
        vm.prank(hookOwner);
        capHook.removeCap(address(otherAsset));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Access control
    // ═════════════════════════════════════════════════════════════════════════════

    function test_setCap_revertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        capHook.setDepositCap(address(otherAsset), 1 ether);
    }

    function test_clearCap_revertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        capHook.removeCap(address(otherAsset));
    }

    function test_setHookContainer_revertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        capHook.setHookContainer(makeAddr("container"));
    }

    function test_setHookContainer_revertsOnVaultMismatch() public {
        HookContainer impl = new HookContainer();
        address otherVault = makeAddr("otherVault");
        HookContainer other =
            HookContainer(ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), otherVault)));

        vm.prank(hookOwner);
        vm.expectRevert(MultiAssetDepositCapHook.InvalidHookContainer.selector);
        capHook.setHookContainer(address(other));
    }

    function test_preMultiDeposit_revertsForUnauthorizedCaller() public {
        vm.prank(user1);
        vm.expectRevert(MultiAssetDepositCapHook.OnlyVaultOrHookContainer.selector);
        capHook.preMultiDeposit(user1, address(otherAsset), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, 0, user1, 0);

        // Even the hook owner cannot advance the counters directly.
        vm.prank(hookOwner);
        vm.expectRevert(MultiAssetDepositCapHook.OnlyVaultOrHookContainer.selector);
        capHook.preMultiDeposit(user1, address(otherAsset), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, 0, user1, 0);

        assertEq(capHook.totalDeposited(address(otherAsset)), 0, "unauthorized caller moved the counter");
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Rolling sum accounting
    // ═════════════════════════════════════════════════════════════════════════════

    function test_rollingSum_accumulatesRawTokenAmounts() public {
        _depositOther(DEPOSIT_AMOUNT);
        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT);

        _depositOther(2 * DEPOSIT_AMOUNT);
        assertEq(capHook.totalDeposited(address(otherAsset)), 3 * DEPOSIT_AMOUNT, "sum did not accumulate");
    }

    function test_rollingSum_accumulatesEvenWhenUncapped() public {
        (bool capped,) = capHook.getDepositCap(address(otherAsset));
        assertFalse(capped, "precondition: token is uncapped");

        _depositOther(DEPOSIT_AMOUNT);

        assertEq(
            capHook.totalDeposited(address(otherAsset)),
            DEPOSIT_AMOUNT,
            "uncapped tokens must still be recorded so a later cap accounts for them"
        );
    }

    function test_rollingSum_usesTokenDecimalsNotBaseValue() public {
        // 6-decimal token against an 18-decimal base: the sum must stay in token units.
        uint256 amount6 = 1_000e6;
        ERC20DecimalsMock token6 = _newWhitelistedToken(6, amount6);

        vm.prank(user1);
        multiAssetVault.deposit(address(token6), amount6, user1);

        assertEq(capHook.totalDeposited(address(token6)), amount6, "sum should be in raw token units");
        assertEq(multiAssetVault.cachedTotalAssets(), amount6 * (10 ** 12), "precondition: base value is scaled up");
    }

    function test_rollingSum_isolatedPerToken() public {
        ERC20DecimalsMock token18 = _newWhitelistedToken(18, 20 * DEPOSIT_AMOUNT);

        _setCap(address(otherAsset), DEPOSIT_AMOUNT);

        _depositOther(DEPOSIT_AMOUNT);

        // otherAsset is now exactly at its cap; token18 is untouched and uncapped.
        vm.prank(user1);
        multiAssetVault.deposit(address(token18), 5 * DEPOSIT_AMOUNT, user1);

        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT);
        assertEq(capHook.totalDeposited(address(token18)), 5 * DEPOSIT_AMOUNT);

        // The capped token rejects even the smallest possible deposit.
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiAssetDepositCapHook.TokenDepositCapExceeded.selector,
                address(otherAsset),
                DEPOSIT_AMOUNT + 1,
                DEPOSIT_AMOUNT
            )
        );
        multiAssetVault.deposit(address(otherAsset), 1, user1);

        // The other token is unaffected and still accepts deposits.
        vm.prank(user1);
        multiAssetVault.deposit(address(token18), 5 * DEPOSIT_AMOUNT, user1);

        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT, "capped token advanced past its cap");
        assertEq(
            capHook.totalDeposited(address(token18)),
            10 * DEPOSIT_AMOUNT,
            "uncapped token blocked by another token's cap"
        );
    }

    function test_rollingSum_ignoresBaseAssetDeposits() public {
        _setCap(address(asset), 1); // A cap on the base asset must have no effect.

        vm.prank(user1);
        multiAssetVault.deposit(address(asset), DEPOSIT_AMOUNT, user1);

        assertEq(capHook.totalDeposited(address(asset)), 0, "base-asset deposits must not reach this hook");
        assertEq(multiAssetVault.balanceOf(user1), DEPOSIT_AMOUNT, "base deposit should have succeeded");
    }

    function test_rollingSum_notReducedByRedeem() public {
        uint256 shares = _depositOther(DEPOSIT_AMOUNT);
        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT);

        vm.prank(user1);
        multiAssetVault.redeem(shares, user1, user1);

        assertEq(
            capHook.totalDeposited(address(otherAsset)),
            DEPOSIT_AMOUNT,
            "the cap is a lifetime cap; exits must not rewind it"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Cap enforcement
    // ═════════════════════════════════════════════════════════════════════════════

    function test_deposit_succeedsExactlyAtCap() public {
        _setCap(address(otherAsset), 2 * DEPOSIT_AMOUNT);

        _depositOther(DEPOSIT_AMOUNT);
        _depositOther(DEPOSIT_AMOUNT);

        assertEq(capHook.totalDeposited(address(otherAsset)), 2 * DEPOSIT_AMOUNT, "landing on the cap must succeed");
    }

    function test_deposit_revertsOneWeiOverCap() public {
        _setCap(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiAssetDepositCapHook.TokenDepositCapExceeded.selector,
                address(otherAsset),
                DEPOSIT_AMOUNT + 1,
                DEPOSIT_AMOUNT
            )
        );
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT + 1, user1);
    }

    function test_deposit_revertRollsBackEverything() public {
        _setCap(address(otherAsset), DEPOSIT_AMOUNT);
        _depositOther(DEPOSIT_AMOUNT);

        uint256 sharesBefore = multiAssetVault.balanceOf(user1);
        uint256 cachedBefore = multiAssetVault.cachedTotalAssets();
        uint256 allocatedBefore = strategy.totalAllocatedValue();
        uint256 userBalanceBefore = otherAsset.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiAssetDepositCapHook.TokenDepositCapExceeded.selector,
                address(otherAsset),
                2 * DEPOSIT_AMOUNT,
                DEPOSIT_AMOUNT
            )
        );
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        assertEq(multiAssetVault.balanceOf(user1), sharesBefore, "shares minted despite revert");
        assertEq(multiAssetVault.cachedTotalAssets(), cachedBefore, "accounting moved despite revert");
        assertEq(strategy.totalAllocatedValue(), allocatedBefore, "strategy allocated despite revert");
        assertEq(otherAsset.balanceOf(user1), userBalanceBefore, "user debited despite revert");
        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT, "rolling sum advanced despite revert");
    }

    function test_capBelowExistingTotal_closesTheToken() public {
        _depositOther(5 * DEPOSIT_AMOUNT);

        // Retroactively cap below what has already been deposited.
        _setCap(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiAssetDepositCapHook.TokenDepositCapExceeded.selector,
                address(otherAsset),
                6 * DEPOSIT_AMOUNT,
                DEPOSIT_AMOUNT
            )
        );
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function test_raisingCap_reopensTheToken() public {
        _setCap(address(otherAsset), DEPOSIT_AMOUNT);
        _depositOther(DEPOSIT_AMOUNT);

        _setCap(address(otherAsset), 3 * DEPOSIT_AMOUNT);
        _depositOther(2 * DEPOSIT_AMOUNT);

        assertEq(capHook.totalDeposited(address(otherAsset)), 3 * DEPOSIT_AMOUNT);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // canDeposit view
    // ═════════════════════════════════════════════════════════════════════════════

    function test_canDeposit_trueWhenWithinCap() public {
        _setCap(address(otherAsset), DEPOSIT_AMOUNT);
        assertTrue(capHook.canDeposit(address(otherAsset), DEPOSIT_AMOUNT));
    }

    function test_canDeposit_trueWhenUncapped() public view {
        assertTrue(capHook.canDeposit(address(otherAsset), type(uint128).max));
    }

    function test_canDeposit_revertsWhenOverCap() public {
        _setCap(address(otherAsset), DEPOSIT_AMOUNT);
        _depositOther(DEPOSIT_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiAssetDepositCapHook.TokenDepositCapExceeded.selector,
                address(otherAsset),
                DEPOSIT_AMOUNT + 1,
                DEPOSIT_AMOUNT
            )
        );
        capHook.canDeposit(address(otherAsset), 1);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Hook wiring
    // ═════════════════════════════════════════════════════════════════════════════

    function test_flagNotSet_hookIsNotConsulted() public {
        // Clear the PRE_MULTI_DEPOSIT flag while keeping the same target.
        vm.prank(hookManager);
        multiAssetVault.setHooks(Hooks({target: address(capHook), flags: uint96(1) << HooksLibV2.PRE_DEPOSIT}));

        _setCap(address(otherAsset), 0);

        _depositOther(DEPOSIT_AMOUNT);
        assertEq(capHook.totalDeposited(address(otherAsset)), 0, "hook ran despite the flag being unset");
    }
}

/**
 * @dev Same vault, but the cap hook sits behind a {HookContainer} rather than being the vault's
 *      direct hook target.
 */
contract MultiAssetDepositCapHookContainerTest is MultiAssetNonBaseDepositBase {
    MultiAssetDepositCapHook internal capHook;
    UserDepositCapHook internal passiveHook;
    HookContainer internal container;

    address internal hookOwner;
    address internal containerAdmin;

    function setUp() public virtual override {
        super.setUp();

        _whitelist(address(otherAsset));
        _setPricer();
        _setStrategy();

        hookOwner = makeAddr("hookOwner");
        containerAdmin = makeAddr("containerAdmin");

        container = _deployContainer(containerAdmin);
        capHook = _deployCapHook(hookOwner);
        passiveHook = _deployPassiveHook(hookOwner);

        vm.startPrank(containerAdmin);
        container.grantRole(PeripheryRolesLib.HOOK_MANAGER_ROLE, containerAdmin);
        container.addHook(address(capHook));
        // A hook that does not override preMultiDeposit must be a silent no-op, not a revert.
        container.addHook(address(passiveHook));
        vm.stopPrank();

        vm.prank(hookOwner);
        capHook.setHookContainer(address(container));

        vm.prank(hookManager);
        multiAssetVault.setHooks(Hooks({target: address(container), flags: uint96(1) << HooksLibV2.PRE_MULTI_DEPOSIT}));
    }

    function _deployContainer(address admin_) internal returns (HookContainer c) {
        HookContainer impl = new HookContainer();
        c = HookContainer(
            ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), address(multiAssetVault)))
        );
        c.initialize(admin_);
    }

    function _deployCapHook(address owner_) internal returns (MultiAssetDepositCapHook h) {
        MultiAssetDepositCapHook impl = new MultiAssetDepositCapHook();
        h = MultiAssetDepositCapHook(
            ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), address(multiAssetVault)))
        );
        h.initialize(owner_);
    }

    function _deployPassiveHook(address owner_) internal returns (UserDepositCapHook h) {
        UserDepositCapHook impl = new UserDepositCapHook();
        h = UserDepositCapHook(
            ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(this), address(multiAssetVault)))
        );
        h.initialize(owner_);
    }

    function test_container_forwardsAndEnforcesCap() public {
        vm.prank(hookOwner);
        capHook.setDepositCap(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
        assertEq(capHook.totalDeposited(address(otherAsset)), DEPOSIT_AMOUNT, "container did not forward the call");

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiAssetDepositCapHook.TokenDepositCapExceeded.selector,
                address(otherAsset),
                2 * DEPOSIT_AMOUNT,
                DEPOSIT_AMOUNT
            )
        );
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function test_container_rejectsNonVaultCaller() public {
        vm.prank(user1);
        vm.expectRevert(HookContainer.OnlyVault.selector);
        container.preMultiDeposit(user1, address(otherAsset), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, 0, user1, 0);
    }

    function test_capHook_rejectsVaultBypassWhenContainerIsWired() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(MultiAssetDepositCapHook.OnlyVaultOrHookContainer.selector);
        capHook.preMultiDeposit(stranger, address(otherAsset), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, 0, stranger, 0);
    }

    function test_container_withoutSetHookContainerBlocksDeposits() public {
        vm.prank(hookOwner);
        capHook.setHookContainer(address(0));

        vm.prank(user1);
        vm.expectRevert(MultiAssetDepositCapHook.OnlyVaultOrHookContainer.selector);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }
}
