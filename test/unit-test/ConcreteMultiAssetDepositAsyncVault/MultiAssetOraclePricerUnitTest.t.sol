// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {
    ConcreteMultiAssetDepositAsyncVaultBaseSetup
} from "../../common/ConcreteMultiAssetDepositAsyncVaultBaseSetup.t.sol";
import {
    IConcreteMultiAssetDepositAsyncVault as IMAV
} from "../../../src/interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {MultiAssetStrategy} from "../../../src/periphery/strategies/MultiAssetStrategy.sol";
import {MultisigStrategy} from "../../../src/periphery/strategies/MultisigStrategy.sol";
import {OracleModule} from "../../../src/periphery/oracle/OracleModule.sol";
import {OracleAssetPricer} from "../../../src/pricer/OracleAssetPricer.sol";
import {ChainlinkOracleMock} from "../../mock/ChainlinkOracleMock.sol";
import {ERC20DecimalsMock} from "../../mock/ERC20DecimalsMock.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @dev Non-base multi-asset deposits priced by {OracleAssetPricer}. The base asset (`asset`, 18dp)
 *      and every non-base deposit asset get their own Chainlink feed on a shared {OracleModule},
 *      so the minted shares must track the *ratio* of the two oracle prices, adjusted for the
 *      token decimal delta.
 */
contract MultiAssetOraclePricerUnitTest is ConcreteMultiAssetDepositAsyncVaultBaseSetup {
    address internal user1;
    address internal strategyAdmin;
    address internal multisig;

    OracleModule internal oracleModule;
    OracleAssetPricer internal pricer;
    MultiAssetStrategy internal strategy;

    ChainlinkOracleMock internal baseFeed; // feed for `asset` (the vault base asset)
    ChainlinkOracleMock internal otherFeed; // feed for `otherAsset`

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant ONE_USD = 10 ** uint256(FEED_DECIMALS);
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e18;

    function setUp() public override {
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

        // Base asset at $1, non-base asset at $2.
        oracleModule = new OracleModule(address(this), FEED_DECIMALS);
        baseFeed = _setFeed(address(asset), int256(ONE_USD));
        otherFeed = _setFeed(address(otherAsset), int256(2 * ONE_USD));

        pricer = new OracleAssetPricer(address(oracleModule));
        strategy = _deployStrategy();

        vm.prank(strategyOperator);
        multiAssetVault.addStrategy(address(strategy));

        _whitelist(address(otherAsset));
        _setPricer();
        _setStrategy();
    }

    // ── Oracle-priced share minting ────────────────────────────────────────────

    function testNonBaseDepositMintsSharesFromOraclePriceRatio() public {
        // 1_000 otherAsset @ $2 against a $1 base asset (both 18dp) => 2_000 base units.
        uint256 expectedBaseValue = 2 * DEPOSIT_AMOUNT;
        uint256 expectedShares = multiAssetVault.previewDeposit(expectedBaseValue);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        assertEq(shares, expectedShares, "shares do not reflect the oracle price ratio");
        assertEq(multiAssetVault.balanceOf(user1), shares, "receiver did not get shares");
        assertEq(multiAssetVault.cachedTotalAssets(), expectedBaseValue, "base value mispriced");
        assertEq(strategy.totalAllocatedValue(), expectedBaseValue, "strategy allocation mispriced");
        // The raw (unpriced) token amount is what leaves the user and reaches custody.
        assertEq(otherAsset.balanceOf(multisig), DEPOSIT_AMOUNT, "multisig did not receive the raw amount");
    }

    function testNonBaseDepositMintsHalfSharesWhenAssetIsWorthHalfTheBase() public {
        // otherAsset $1, base asset $2 => 1_000 otherAsset is worth 500 base units.
        otherFeed.setAnswer(int256(ONE_USD));
        baseFeed.setAnswer(int256(2 * ONE_USD));

        uint256 expectedBaseValue = DEPOSIT_AMOUNT / 2;
        uint256 expectedShares = multiAssetVault.previewDeposit(expectedBaseValue);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        assertEq(shares, expectedShares, "shares do not reflect a base asset priced above the deposit asset");
        assertEq(multiAssetVault.cachedTotalAssets(), expectedBaseValue, "base value mispriced");
    }

    function testSharesTrackBasePriceMoves() public {
        // Same deposit asset price, base asset doubles: the same token amount must mint half the
        // shares of the cheaper-base case.
        vm.prank(user1);
        uint256 sharesAtBaseOneDollar = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        baseFeed.setAnswer(int256(2 * ONE_USD));

        vm.prank(user1);
        uint256 sharesAtBaseTwoDollars = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        assertEq(sharesAtBaseTwoDollars, sharesAtBaseOneDollar / 2, "shares did not halve when the base doubled");
    }

    function testNonBaseDepositSharesMatchEquivalentBaseDeposit() public {
        // Depositing 1_000 otherAsset @ $2 must mint exactly what depositing 2_000 base @ $1 does.
        vm.prank(user1);
        uint256 nonBaseShares = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        address user2 = makeAddr("user2");
        asset.mint(user2, 2 * DEPOSIT_AMOUNT);
        vm.startPrank(user2);
        asset.approve(address(multiAssetVault), type(uint256).max);
        uint256 baseShares = multiAssetVault.deposit(address(asset), 2 * DEPOSIT_AMOUNT, user2);
        vm.stopPrank();

        assertEq(nonBaseShares, baseShares, "oracle-priced deposit diverges from the equivalent base deposit");
    }

    function testPreviewDepositMatchesActualShares() public {
        uint256 preview = multiAssetVault.previewDeposit(address(otherAsset), DEPOSIT_AMOUNT);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(otherAsset), DEPOSIT_AMOUNT, user1);

        assertEq(preview, shares, "previewDeposit(non-base) != minted shares");
    }

    // ── Decimal delta ──────────────────────────────────────────────────────────

    function testNonBaseDepositResolvesDecimalDeltaUp() public {
        // 6dp deposit asset @ $3 against an 18dp base asset @ $1 => 1_000 tokens = 3_000 base units.
        ERC20DecimalsMock token6 = new ERC20DecimalsMock(6);
        _setFeed(address(token6), int256(3 * ONE_USD));

        uint256 amount6 = 1_000e6;
        uint256 expectedBaseValue = 3_000e18;

        token6.mint(user1, amount6);
        vm.prank(user1);
        token6.approve(address(multiAssetVault), type(uint256).max);
        _whitelist(address(token6));

        uint256 expectedShares = multiAssetVault.previewDeposit(expectedBaseValue);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(token6), amount6, user1);

        assertEq(shares, expectedShares, "decimal delta not resolved on the way up");
        assertEq(multiAssetVault.cachedTotalAssets(), expectedBaseValue, "base value mispriced across decimals");
        assertEq(token6.balanceOf(multisig), amount6, "raw 6dp amount not forwarded to custody");
    }

    function testNonBaseDepositResolvesDecimalDeltaDown() public {
        // 24dp deposit asset @ $0.5 against an 18dp base asset @ $1 => 1_000 tokens = 500 base units.
        ERC20DecimalsMock token24 = new ERC20DecimalsMock(24);
        _setFeed(address(token24), int256(ONE_USD / 2));

        uint256 amount24 = 1_000e24;
        uint256 expectedBaseValue = 500e18;

        token24.mint(user1, amount24);
        vm.prank(user1);
        token24.approve(address(multiAssetVault), type(uint256).max);
        _whitelist(address(token24));

        uint256 expectedShares = multiAssetVault.previewDeposit(expectedBaseValue);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(token24), amount24, user1);

        assertEq(shares, expectedShares, "decimal delta not resolved on the way down");
        assertEq(multiAssetVault.cachedTotalAssets(), expectedBaseValue, "base value mispriced across decimals");
    }

    // ── Rounding ───────────────────────────────────────────────────────────────

    function testNonBaseDepositRoundsBaseValueDown() public {
        // $1 deposit asset against a $3 base asset: 10 tokens = 10/3 base units, truncated.
        baseFeed.setAnswer(int256(3 * ONE_USD));
        otherFeed.setAnswer(int256(ONE_USD));

        uint256 amount = 10e18;
        uint256 expectedBaseValue = 3_333_333_333_333_333_333; // floor(10e18 / 3)
        uint256 expectedShares = multiAssetVault.previewDeposit(expectedBaseValue);

        vm.prank(user1);
        uint256 shares = multiAssetVault.deposit(address(otherAsset), amount, user1);

        assertEq(multiAssetVault.cachedTotalAssets(), expectedBaseValue, "base value not rounded down");
        assertEq(shares, expectedShares, "shares not derived from the floored base value");
        // Never credit the user more than the exact rational value.
        assertLe(expectedBaseValue * 3, amount, "rounded up against the vault");
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _setFeed(address token, int256 price) internal returns (ChainlinkOracleMock feed) {
        feed = new ChainlinkOracleMock(FEED_DECIMALS, price);
        oracleModule.setOracle(token, address(feed), 0, 0, 1 hours, false, true);
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
