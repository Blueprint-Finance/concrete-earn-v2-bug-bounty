// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    ConcreteMultiAssetDepositAsyncVaultBaseSetup
} from "../../common/ConcreteMultiAssetDepositAsyncVaultBaseSetup.t.sol";
import {
    IConcreteMultiAssetDepositAsyncVault as IMAV
} from "../../../src/interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {MultiAssetStrategy} from "../../../src/periphery/strategies/MultiAssetStrategy.sol";
import {MultisigStrategy} from "../../../src/periphery/strategies/MultisigStrategy.sol";
import {OneToOneAssetPricer} from "../../../src/pricer/OneToOneAssetPricer.sol";
import {ERC20DecimalsMock} from "../../mock/ERC20DecimalsMock.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";

/**
 * @dev Shared setup for the non-base multi-asset deposit flow: a 1:1 pricer plus a live
 *      {MultiAssetStrategy} (flavour 8) registered and Active on the vault. Subclasses decide how
 *      much of the multi-asset config to wire so both the happy path and the config guards can be
 *      exercised.
 */
abstract contract MultiAssetNonBaseDepositBase is ConcreteMultiAssetDepositAsyncVaultBaseSetup {
    address internal user1;
    address internal strategyAdmin;
    address internal multisig;

    OneToOneAssetPricer internal pricer;
    MultiAssetStrategy internal strategy;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e18;

    function setUp() public virtual override {
        super.setUp();

        user1 = makeAddr("user1");
        strategyAdmin = makeAddr("strategyAdmin");
        multisig = makeAddr("multisig");

        asset.mint(user1, 100 * DEPOSIT_AMOUNT);
        otherAsset.mint(user1, 100 * DEPOSIT_AMOUNT);
        vm.startPrank(user1);
        asset.approve(address(multiAssetVault), type(uint256).max);
        otherAsset.approve(address(multiAssetVault), type(uint256).max);
        vm.stopPrank();

        pricer = new OneToOneAssetPricer();
        strategy = _deployStrategy();

        vm.prank(strategyOperator);
        multiAssetVault.addStrategy(address(strategy));
    }

    function _deployStrategy() internal returns (MultiAssetStrategy) {
        MultiAssetStrategy impl = new MultiAssetStrategy();
        bytes memory initData = abi.encodeWithSelector(
            MultisigStrategy.initialize.selector,
            strategyAdmin,
            address(multiAssetVault),
            multisig,
            uint64(1000), // maxAccountingChangeThreshold (10%)
            uint64(86400), // accountingValidityPeriod (1 day)
            uint64(3600), // cooldownPeriod (1 hour)
            address(0) // no timelock at deploy time
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return MultiAssetStrategy(address(proxy));
    }

    function _config(IMAV.MultiAssetVaultManagerConfig configType, bytes memory data) internal {
        vm.prank(vaultManager);
        multiAssetVault.configureMultiAsset(configType, data);
    }

    function _whitelist(address token) internal {
        _config(IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset, abi.encode(token));
    }

    function _setPricer() internal {
        _config(IMAV.MultiAssetVaultManagerConfig.SetPricer, abi.encode(address(pricer)));
    }

    function _setStrategy() internal {
        _config(IMAV.MultiAssetVaultManagerConfig.SetMultiAssetStrategy, abi.encode(address(strategy)));
    }
}

/**
 * @dev Fully-wired multi-asset config: whitelist(otherAsset) + pricer + strategy.
 */
contract MultiAssetNonBaseDepositUnitTest is MultiAssetNonBaseDepositBase {
    function setUp() public override {
        super.setUp();
        _whitelist(address(otherAsset));
        _setPricer();
        _setStrategy();
    }

    // ── Happy path ─────────────────────────────────────────────────────────────

    function testNonBaseDepositMintsSharesAndForwardsToStrategy() public {
        uint256 expectedShares = multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);
        uint256 userBefore = otherAsset.balanceOf(user1);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        // Shares: priced from base value (1:1 same-decimals) and minted to the receiver.
        assertEq(shares, expectedShares, "shares != previewDeposit");
        assertGt(shares, 0, "no shares minted");
        assertEq(multiAssetVault.balanceOf(user1), shares, "receiver did not get shares");

        // Funds bypass idle vault balance and land in the multi-sig custody.
        assertEq(otherAsset.balanceOf(user1), userBefore - DEPOSIT_AMOUNT, "user not debited");
        assertEq(otherAsset.balanceOf(address(multiAssetVault)), 0, "vault holds the non-base asset");
        assertEq(otherAsset.balanceOf(multisig), DEPOSIT_AMOUNT, "multisig did not receive the asset");

        // Base accounting: cachedTotalAssets and strategy allocation both move by the base value.
        assertEq(multiAssetVault.cachedTotalAssets(), DEPOSIT_AMOUNT, "cachedTotalAssets mismatch");
        assertEq(strategy.totalAllocatedValue(), DEPOSIT_AMOUNT, "strategy allocation mismatch");
        assertEq(multiAssetVault.totalAssets(), DEPOSIT_AMOUNT, "totalAssets mismatch");
    }

    function testNonBaseDepositEmitsEvent() public {
        uint256 expectedShares = multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.MultiAssetDeposit(user1, user1, address(otherAsset), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, expectedShares);

        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testNonBaseDepositEmitsErc4626DepositEvent() public {
        // The canonical ERC-4626 issuance signal must fire for non-base deposits too, carrying the
        // base-equivalent value, so indexers summing {Deposit} do not under-count them.
        uint256 expectedShares = multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IERC4626.Deposit(user1, user1, DEPOSIT_AMOUNT, expectedShares);

        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testNonBaseDepositSharesMatchBaseDeposit() public {
        // A non-base deposit of `x` (1:1) must mint the same shares as a base deposit of `x`.
        vm.prank(user1);
        uint256 nonBaseShares = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        address user2 = makeAddr("user2");
        asset.mint(user2, DEPOSIT_AMOUNT);
        vm.startPrank(user2);
        asset.approve(address(multiAssetVault), type(uint256).max);
        uint256 baseShares = multiAssetVault.deposit(address(asset), DEPOSIT_AMOUNT, user2);
        vm.stopPrank();

        assertEq(nonBaseShares, baseShares, "non-base deposit diverges from equivalent base deposit");
    }

    function testPreviewDepositNonBaseMatchesActual() public {
        uint256 preview = multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        assertEq(preview, shares, "previewDeposit(non-base) != actual shares");
    }

    function testPreviewDepositNonBaseMatchesBasePreviewOfConvertedValue() public view {
        // 1:1 same-decimals: previewDeposit(otherAsset, x) must equal previewDeposit(x).
        assertEq(
            multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT),
            multiAssetVault.previewDeposit(DEPOSIT_AMOUNT),
            "non-base preview diverges from base preview of the converted value"
        );
    }

    // ── Accrual consistency (no phantom yield/loss) ──────────────────────────────

    function testNonBaseDepositNoPhantomYieldOnAccrual() public {
        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        uint256 cachedBefore = multiAssetVault.cachedTotalAssets();

        // The strategy records the deposit in base units, so its allocated value already equals the
        // vault's recorded allocation. The up-to-date `totalAssets()` (which previews accrual) must
        // therefore match `cachedTotalAssets()`: no phantom yield or loss.
        assertEq(strategy.totalAllocatedValue(), cachedBefore, "strategy value diverges from vault allocation");
        assertEq(multiAssetVault.totalAssets(), cachedBefore, "totalAssets preview shows phantom yield/loss");

        // Trigger a real accrual via a follow-up base deposit: cached must move by exactly the new
        // deposit, confirming accrual injected nothing extra.
        vm.prank(user1);
        multiAssetVault.deposit(address(asset), DEPOSIT_AMOUNT, user1);

        assertEq(
            multiAssetVault.cachedTotalAssets(),
            cachedBefore + DEPOSIT_AMOUNT,
            "accrual synthesised yield/loss on the non-base position"
        );
    }

    // ── Decimal scaling ──────────────────────────────────────────────────────────

    function testNonBaseDepositScalesDecimalsUp() public {
        // 6-decimal deposit asset, 18-decimal base: base value is scaled up by 10^12.
        ERC20DecimalsMock token6 = new ERC20DecimalsMock(6);
        uint256 amount6 = 1_000e6;
        uint256 expectedBaseValue = amount6 * (10 ** 12);

        token6.mint(user1, amount6);
        vm.prank(user1);
        token6.approve(address(multiAssetVault), type(uint256).max);
        _whitelist(address(token6));

        uint256 expectedShares = multiAssetVault.previewDeposit(address(token6), amount6);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(token6), amount6, user1);

        assertEq(shares, expectedShares, "shares != preview for scaled deposit");
        assertEq(multiAssetVault.cachedTotalAssets(), expectedBaseValue, "base value not scaled up");
        assertEq(strategy.totalAllocatedValue(), expectedBaseValue, "strategy value not scaled up");
        assertEq(token6.balanceOf(multisig), amount6, "raw (unscaled) token not forwarded to multisig");
    }

    // ── Reverts ────────────────────────────────────────────────────────────────

    function testNonBaseDepositZeroBaseValueReverts() public {
        // 24-decimal asset, 18-decimal base: sub-10^6 wei rounds to zero base value.
        ERC20DecimalsMock token24 = new ERC20DecimalsMock(24);
        token24.mint(user1, 1);
        vm.prank(user1);
        token24.approve(address(multiAssetVault), type(uint256).max);
        _whitelist(address(token24));

        vm.expectRevert(abi.encodeWithSelector(IMAV.ZeroBaseValue.selector, address(token24), uint256(1)));
        multiAssetVault.previewDeposit(address(token24), 1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.ZeroBaseValue.selector, address(token24), uint256(1)));
        multiAssetVault.deposit(address(token24), 1, user1);
    }

    function testNonBaseDepositRevertsWhenStrategyHalted() public {
        vm.prank(strategyOperator);
        multiAssetVault.toggleStrategyStatus(address(strategy)); // Active -> Halted

        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetStrategyNotActive.selector, address(strategy)));
        multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetStrategyNotActive.selector, address(strategy)));
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testNonBaseDepositNotWhitelistedReverts() public {
        ERC20DecimalsMock notListed = new ERC20DecimalsMock(18);
        notListed.mint(user1, DEPOSIT_AMOUNT);
        vm.prank(user1);
        notListed.approve(address(multiAssetVault), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IMAV.AssetNotWhitelisted.selector, address(notListed)));
        multiAssetVault.previewDeposit(address(notListed), DEPOSIT_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.AssetNotWhitelisted.selector, address(notListed)));
        multiAssetVault.deposit(address(notListed), DEPOSIT_AMOUNT, user1);
    }
}

/**
 * @dev Config guards: the deposit asset is whitelisted but the pricer and/or strategy are missing.
 */
contract MultiAssetNonBaseDepositConfigGuardTest is MultiAssetNonBaseDepositBase {
    function testRevertsWhenPricerAndStrategyUnset() public {
        _whitelist(address(otherAsset));

        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testRevertsWhenPricerUnset() public {
        _whitelist(address(otherAsset));
        _setStrategy();

        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testRevertsWhenStrategyUnset() public {
        _whitelist(address(otherAsset));
        _setPricer();

        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }
}

/**
 * @dev Coupling between the designated non-base deposit strategy (`MASLib.strategy`, VAULT_MANAGER +
 *      timelocked) and the strategy registry lifecycle (STRATEGY_MANAGER, instant). The pointer must
 *      follow the strategy it names: cleared when the strategy is removed, moved onto the successor
 *      when a halted strategy is reconciled, and left alone by a reversible halt.
 */
contract MultiAssetStrategyPointerLifecycleTest is MultiAssetNonBaseDepositBase {
    MultiAssetStrategy internal strategy2;

    function setUp() public override {
        super.setUp();
        _whitelist(address(otherAsset));
        _setPricer();
        _setStrategy();

        strategy2 = _deployStrategy();
        vm.prank(strategyOperator);
        multiAssetVault.addStrategy(address(strategy2));
    }

    // ── removeStrategy ────────────────────────────────────────────────────────

    function testRemoveDesignatedStrategyClearsPointer() public {
        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.MultiAssetStrategySet(address(0));

        vm.prank(strategyOperator);
        multiAssetVault.removeStrategy(address(strategy));

        assertEq(multiAssetVault.getMultiAssetStrategy(), address(0), "pointer not cleared");

        // Explicit "not configured", not a dangling reference to a deleted registry row.
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testRemoveOtherStrategyLeavesPointerUntouched() public {
        vm.prank(strategyOperator);
        multiAssetVault.removeStrategy(address(strategy2));

        assertEq(multiAssetVault.getMultiAssetStrategy(), address(strategy), "pointer must not move");

        // Non-base deposits keep working.
        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
        assertGt(multiAssetVault.balanceOf(user1), 0, "deposit should still succeed");
    }

    // ── reconcileHaltedStrategy ───────────────────────────────────────────────

    function testReconcileMovesPointerOntoSuccessor() public {
        // Give the designated strategy an allocation so it can be reconciled, then halt it.
        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        vm.prank(strategyOperator);
        multiAssetVault.toggleStrategyStatus(address(strategy));

        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.MultiAssetStrategySet(address(strategy2));

        vm.prank(strategyOperator);
        multiAssetVault.reconcileHaltedStrategy(address(strategy), address(strategy2));

        assertEq(multiAssetVault.getMultiAssetStrategy(), address(strategy2), "pointer did not follow position");

        // The anti-outage property: deposits resume immediately, with no configureMultiAsset in between.
        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    function testReconcileToZeroClearsPointer() public {
        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        vm.prank(strategyOperator);
        multiAssetVault.toggleStrategyStatus(address(strategy));

        vm.expectEmit(true, true, true, true, address(multiAssetVault));
        emit IMAV.MultiAssetStrategySet(address(0));

        // Loss write-off branch: no successor to follow.
        vm.prank(strategyOperator);
        multiAssetVault.reconcileHaltedStrategy(address(strategy), address(0));

        assertEq(multiAssetVault.getMultiAssetStrategy(), address(0), "pointer not cleared");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetNotConfigured.selector));
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
    }

    // ── toggleStrategyStatus — deliberately not coupled ───────────────────────

    function testHaltLeavesPointerUntouchedAndUnhaltSelfHeals() public {
        vm.prank(strategyOperator);
        multiAssetVault.toggleStrategyStatus(address(strategy));

        assertEq(multiAssetVault.getMultiAssetStrategy(), address(strategy), "halt must not move the pointer");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IMAV.MultiAssetStrategyNotActive.selector, address(strategy)));
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        // Un-halting restores the non-base flow with no governance action.
        vm.prank(strategyOperator);
        multiAssetVault.toggleStrategyStatus(address(strategy));

        vm.prank(user1);
        multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);
        assertGt(multiAssetVault.balanceOf(user1), 0, "deposits should resume after unhalt");
    }
}
