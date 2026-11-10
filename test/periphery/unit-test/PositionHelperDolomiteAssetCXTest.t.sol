// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

// ── Clone library ─────────────────────────────────────────────────────────────
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

// ── Test mocks ────────────────────────────────────────────────────────────────
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {ERC4626Mock} from "../../mock/ERC4626Mock.sol";
import {MockLiquidationModule} from "../mock/MockLiquidationModule.sol";

// ── OpenZeppelin ──────────────────────────────────────────────────────────────
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";

// ── Subject under test ────────────────────────────────────────────────────────
import {PositionHelperDolomiteAssetCX} from "../../../src/periphery/positionhelper/PositionHelperDolomiteAssetCX.sol";
import {PositionHelperDolomiteBase} from "../../../src/periphery/positionhelper/PositionHelperDolomiteBase.sol";
import {DolomitePositionViewLib} from "../../../src/periphery/lib/DolomitePositionViewLib.sol";
import {DolomiteInitLib} from "../../../src/periphery/lib/DolomiteInitLib.sol";
import {IDolomiteMargin, DolomiteAccount} from "../../../src/periphery/interface/IDolomiteMargin.sol";
import {IPositionHelperBase, PositionApprovals} from "../../../src/periphery/interface/IPositionHelperBase.sol";
import {LIQUIDATOR_ROLE, Liquidation} from "../../../src/periphery/interface/ILiquidationModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

/// @dev `ERC20Mock` with a caller-chosen `decimals()`, used to give the redemption claim token a
///      decimals count that differs from the borrow token's.
contract ERC20MockWithDecimals is ERC20Mock {
    uint8 private immutable _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20Mock(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @title  PositionHelperDolomiteAssetCXTest
/// @notice Unit tests for the AssetCX-specific surface of `PositionHelperDolomiteAssetCX`:
///         the `LIQUIDATOR_ROLE` gate on `_getLenderApprovals`, the primary-only position views
///         (`getPosition` / `getCollateralAmount` / `getDebtAmount`) versus the full breakdown
///         (`getFullAssetCXPosition`, which also sums in-flight liquidations' temporary
///         positions), and `_selfLiquidate` delegation to `liquidationModule`.
///
/// @dev No mainnet fork is needed: `DOLOMITE_MARGIN` is a label-only address with no code, and
///      every Dolomite view it needs (`getIsLocalOperator`, `getAccountWei`, `getMarketPrice`) is
///      stubbed per-test via `vm.mockCall`. `liquidationModule` is a real `MockLiquidationModule`
///      contract implementing `ILiquidationModule` plus a bare `hasRole` for the `IAccessControl`
///      cast in `_hasLiquidatorRole`.
contract PositionHelperDolomiteAssetCXTest is Test {
    // ── Dolomite market IDs (arbitrary — only used as mock-call keys here) ────

    uint256 internal constant COLLATERAL_MARKET_ID = 1;
    uint256 internal constant BORROW_MARKET_ID = 2;
    uint256 internal constant REDEMPTION_CLAIM_MARKET_ID = 3;
    uint256 internal constant ACCOUNT_NUMBER = 0;
    uint256 internal constant TEMP_ACCOUNT_NUMBER = 1_000_001;

    // ── LTV parameters (WAD-scaled) ───────────────────────────────────────────

    uint64 internal constant HEALTHY_LTV = 600_000_000_000_000_000; // 60%
    uint64 internal constant HEALTHY_LTV_DEVIATION = 50_000_000_000_000_000; // 5%
    uint64 internal constant SELF_LIQ_BUFFER = 50_000_000_000_000_000; // 5%

    // ── Contracts ─────────────────────────────────────────────────────────────

    address internal dolomiteMargin;
    PositionHelperDolomiteAssetCX internal implementation;
    PositionHelperDolomiteAssetCX internal helper;
    ERC20Mock internal collateralToken;
    ERC20Mock internal borrowToken;
    ERC20Mock internal redemptionClaimToken;
    ERC4626Mock internal yieldVault;
    MockLiquidationModule internal liquidationModule;

    // ── Actors ────────────────────────────────────────────────────────────────

    address internal positionOwner;
    address internal admin;
    address internal operator;
    address internal liquidator;

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        positionOwner = makeAddr("positionOwner");
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        liquidator = makeAddr("liquidator");
        dolomiteMargin = makeAddr("dolomiteMargin");

        collateralToken = new ERC20Mock("Wrapped Ether", "WETH");
        borrowToken = new ERC20Mock("USD Coin", "USDC");
        redemptionClaimToken = new ERC20Mock("Redemption Claim Token", "rCLAIM");
        yieldVault = new ERC4626Mock(address(borrowToken));
        liquidationModule = new MockLiquidationModule();

        implementation = new PositionHelperDolomiteAssetCX(dolomiteMargin, ACCOUNT_NUMBER);

        bytes memory cloneArgs = abi.encodePacked(
            positionOwner,
            address(collateralToken),
            address(borrowToken),
            uint8(18),
            uint8(18),
            COLLATERAL_MARKET_ID,
            BORROW_MARKET_ID
        );
        helper = PositionHelperDolomiteAssetCX(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        // `initialize` validates the encoded market IDs round-trip to the encoded tokens.
        _mockMarketTokenAddress(COLLATERAL_MARKET_ID, address(collateralToken));
        _mockMarketTokenAddress(BORROW_MARKET_ID, address(borrowToken));
        // `initialize` also validates the configured LTV band against Dolomite's liquidation
        // threshold (`_ltvRangeIsValid`), which reads margin ratio/premiums for the clone's own
        // market IDs. Zero premiums/base ratio => a 100% liquidation threshold, comfortably above
        // the HEALTHY_LTV + HEALTHY_LTV_DEVIATION + SELF_LIQ_BUFFER band used by these tests; no
        // test in this file exercises the threshold value itself.
        _mockMarginRatioForAccount(0);
        _mockMarketMarginPremium(COLLATERAL_MARKET_ID, 0);
        _mockMarketMarginPremium(BORROW_MARKET_ID, 0);

        helper.initialize(
            admin,
            operator,
            address(yieldVault),
            address(liquidationModule),
            liquidator,
            address(redemptionClaimToken),
            REDEMPTION_CLAIM_MARKET_ID,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );

        // Default every Dolomite view used by `_getLenderApprovals`/position views to a benign
        // zero/false value; tests override individually via `_mockAccountWei`/`_mockIsOperator`.
        _mockIsOperator(false);
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 0);
        _mockAccountWei(BORROW_MARKET_ID, false, 0);
        // Default to "no extra markets" so `onlySingleCollateralPosition`/`canTransfer` (both of
        // which now run via the shared `PositionHelperDolomiteBase._isSingleCollateralAndDebtMarket`)
        // don't hit an unmocked call on this no-code address; tests override via
        // `_mockNumberOfMarketsWithBalances`/`_mockNumberOfMarketsWithDebt` to simulate extra markets.
        _mockNumberOfMarketsWithBalances(0);
        _mockNumberOfMarketsWithDebt(0);
        // `ERC4626Mock` has no `hasRole`; stub it so `checkApprovals()` (which reads
        // `hasWithdrawalManagerRole` via IAccessControl) doesn't revert. Not under test here.
        vm.mockCall(
            address(yieldVault),
            abi.encodeWithSelector(IAccessControl.hasRole.selector, RolesLib.WITHDRAWAL_MANAGER, address(helper)),
            abi.encode(false)
        );

        vm.label(dolomiteMargin, "DolomiteMargin(mock)");
        vm.label(address(liquidationModule), "LiquidationModule(mock)");
        vm.label(address(helper), "PositionHelperDolomiteAssetCX(clone)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _mockAccountWei(uint256 marketId, bool sign, uint256 value) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(
                IDolomiteMargin.getAccountWei.selector,
                DolomiteAccount.Info({owner: positionOwner, number: 0}),
                marketId
            ),
            abi.encode(sign, value)
        );
    }

    function _mockMarketTokenAddress(uint256 marketId, address token) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(IDolomiteMargin.getMarketTokenAddress.selector, marketId),
            abi.encode(token)
        );
    }

    function _mockMarginRatioForAccount(uint256 value) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(
                IDolomiteMargin.getMarginRatioForAccount.selector,
                DolomiteAccount.Info({owner: positionOwner, number: 0})
            ),
            abi.encode(value)
        );
    }

    function _mockMarketMarginPremium(uint256 marketId, uint256 value) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(IDolomiteMargin.getMarketMarginPremium.selector, marketId),
            abi.encode(value)
        );
    }

    function _mockNumberOfMarketsWithBalances(uint256 count) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(
                IDolomiteMargin.getAccountNumberOfMarketsWithBalances.selector,
                DolomiteAccount.Info({owner: positionOwner, number: 0})
            ),
            abi.encode(count)
        );
    }

    function _mockNumberOfMarketsWithDebt(uint256 count) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(
                IDolomiteMargin.getAccountNumberOfMarketsWithDebt.selector,
                DolomiteAccount.Info({owner: positionOwner, number: 0})
            ),
            abi.encode(count)
        );
    }

    function _mockIsOperator(bool isOperator) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(IDolomiteMargin.getIsLocalOperator.selector, positionOwner, address(helper)),
            abi.encode(isOperator)
        );
    }

    function _mockMarketPrice(uint256 marketId, uint256 priceMock) internal {
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(IDolomiteMargin.getMarketPrice.selector, marketId),
            abi.encode(priceMock)
        );
    }

    /// @dev Seeds a `Liquidation` record on `liquidationModule` for `(positionOwner, ACCOUNT_NUMBER)`
    ///      and mocks the module-owned temp account's DOLOMITE_MARGIN balances so
    ///      `_getRedemptionClaimCollateralAmount`/`_getDebtAmountAgainstClaimToken` can read them.
    function _seedLiquidation(
        uint256 redemptionId,
        uint256 tempAccountNumber,
        uint256 claimTokenSupplied,
        uint256 debtOwed,
        bool active
    ) internal {
        liquidationModule.setLiquidation(
            redemptionId,
            Liquidation({
                positionOwner: positionOwner,
                accountNumber: ACCOUNT_NUMBER,
                tempAccountNumber: tempAccountNumber,
                redemptionClaimTokenSupplied: claimTokenSupplied,
                debtMoved: debtOwed,
                collateralRedeemed: 0,
                debtRepaid: 0,
                redemptionClaimTokenWithdrawn: 0,
                active: active
            })
        );
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(
                IDolomiteMargin.getAccountWei.selector,
                DolomiteAccount.Info({owner: address(liquidationModule), number: tempAccountNumber}),
                REDEMPTION_CLAIM_MARKET_ID
            ),
            abi.encode(true, claimTokenSupplied)
        );
        vm.mockCall(
            dolomiteMargin,
            abi.encodeWithSelector(
                IDolomiteMargin.getAccountWei.selector,
                DolomiteAccount.Info({owner: address(liquidationModule), number: tempAccountNumber}),
                BORROW_MARKET_ID
            ),
            abi.encode(false, debtOwed)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Deployment & init
    // ─────────────────────────────────────────────────────────────────────────

    function testDeployment_verifyLiquidationModuleAndRedemptionClaimStorage() public view {
        assertEq(helper.liquidationModule(), address(liquidationModule), "liquidationModule mismatch");
        assertEq(helper.liquidator(), liquidator, "liquidator mismatch");
        assertEq(helper.redemptionClaimToken(), address(redemptionClaimToken), "redemptionClaimToken mismatch");
        assertEq(helper.redemptionClaimMarketId(), REDEMPTION_CLAIM_MARKET_ID, "redemptionClaimMarketId mismatch");
    }

    function testDeployment_revertsWhenMissingLiquidationMechanism() public {
        bytes memory args = abi.encodePacked(
            positionOwner,
            address(collateralToken),
            address(borrowToken),
            uint8(18),
            uint8(18),
            COLLATERAL_MARKET_ID,
            BORROW_MARKET_ID
        );
        PositionHelperDolomiteAssetCX fresh =
            PositionHelperDolomiteAssetCX(ClonesWithImmutableArgs.clone(address(implementation), args));

        vm.expectRevert(PositionHelperDolomiteBase.MissingLiquidationMechanism.selector);
        fresh.initialize(
            admin,
            operator,
            address(yieldVault),
            address(0), // no liquidation module
            liquidator,
            address(redemptionClaimToken),
            REDEMPTION_CLAIM_MARKET_ID,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    function testDeployment_revertsWhenLiquidatorIsZero() public {
        bytes memory args = abi.encodePacked(
            positionOwner,
            address(collateralToken),
            address(borrowToken),
            uint8(18),
            uint8(18),
            COLLATERAL_MARKET_ID,
            BORROW_MARKET_ID
        );
        PositionHelperDolomiteAssetCX fresh =
            PositionHelperDolomiteAssetCX(ClonesWithImmutableArgs.clone(address(implementation), args));

        vm.expectRevert(IPositionHelperBase.ZeroAddress.selector);
        fresh.initialize(
            admin,
            operator,
            address(yieldVault),
            address(liquidationModule),
            address(0), // no liquidator
            address(redemptionClaimToken),
            REDEMPTION_CLAIM_MARKET_ID,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    function testDeployment_revertsWhenRedemptionClaimTokenIsZero() public {
        PositionHelperDolomiteAssetCX fresh = _cloneUninitialized();

        vm.expectRevert(IPositionHelperBase.ZeroAddress.selector);
        _initialize(fresh, address(0));
    }

    /// @dev Clones the implementation with the same immutable args `setUp` uses, without initializing.
    function _cloneUninitialized() internal returns (PositionHelperDolomiteAssetCX) {
        bytes memory args = abi.encodePacked(
            positionOwner,
            address(collateralToken),
            address(borrowToken),
            uint8(18),
            uint8(18),
            COLLATERAL_MARKET_ID,
            BORROW_MARKET_ID
        );
        return PositionHelperDolomiteAssetCX(ClonesWithImmutableArgs.clone(address(implementation), args));
    }

    /// @dev Initializes `fresh` with the `setUp` parameters, varying only the redemption claim token.
    function _initialize(PositionHelperDolomiteAssetCX fresh, address rc) internal {
        fresh.initialize(
            admin,
            operator,
            address(yieldVault),
            address(liquidationModule),
            liquidator,
            rc,
            REDEMPTION_CLAIM_MARKET_ID,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    /// @dev `initialize` must reject a healthy-LTV band that reaches or exceeds the lender's
    ///      liquidation threshold via `_ltvRangeIsValid` — the same guard the Aave/Morpho
    ///      initializers already apply. The mocked margin ratio/premiums in `setUp` are all 0,
    ///      so the liquidation threshold is 100%; a 95/3/3 band sums to 101%.
    function testInitialize_revertsWhenLtvRangeInvalid() public {
        PositionHelperDolomiteAssetCX fresh = _cloneUninitialized();

        uint64 healthyLtv = 950_000_000_000_000_000; // 95%
        uint64 deviation = 30_000_000_000_000_000; // 3%
        uint64 buffer = 30_000_000_000_000_000; // 3%
        uint64 liqThr = 1e18; // 100%, given the 0% margin ratio/premiums mocked in setUp.

        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.InvalidLtvRange.selector, healthyLtv, deviation, buffer, liqThr)
        );
        fresh.initialize(
            admin,
            operator,
            address(yieldVault),
            address(liquidationModule),
            liquidator,
            address(redemptionClaimToken),
            REDEMPTION_CLAIM_MARKET_ID,
            healthyLtv,
            deviation,
            buffer
        );
    }

    /// @dev `initialize` must reject a zero self-liq buffer via `_ltvRangeIsValid`, even when the
    ///      healthy LTV band on its own would be valid.
    function testInitialize_revertsWhenSelfLiqBufferZero() public {
        bytes memory args = abi.encodePacked(
            positionOwner,
            address(collateralToken),
            address(borrowToken),
            uint8(18),
            uint8(18),
            COLLATERAL_MARKET_ID,
            BORROW_MARKET_ID
        );
        PositionHelperDolomiteAssetCX fresh =
            PositionHelperDolomiteAssetCX(ClonesWithImmutableArgs.clone(address(implementation), args));

        vm.expectRevert(IPositionHelperBase.InvalidSelfLiqThrBufferInWad.selector);
        fresh.initialize(
            admin,
            operator,
            address(yieldVault),
            address(liquidationModule),
            liquidator,
            address(redemptionClaimToken),
            REDEMPTION_CLAIM_MARKET_ID,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            0
        );
    }

    /// @dev A 62-byte header-only blob must not finish initialization.
    function testDeployment_revertsWhenMarketIdsMissing() public {
        bytes memory args =
            abi.encodePacked(positionOwner, address(collateralToken), address(borrowToken), uint8(18), uint8(18));
        PositionHelperDolomiteAssetCX fresh =
            PositionHelperDolomiteAssetCX(ClonesWithImmutableArgs.clone(address(implementation), args));

        vm.expectRevert(); // getMarketTokenAddress on the garbage suffix read reverts
        fresh.initialize(
            admin,
            operator,
            address(yieldVault),
            address(liquidationModule),
            liquidator,
            address(redemptionClaimToken),
            REDEMPTION_CLAIM_MARKET_ID,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    /// @dev Encoded market IDs that do not round-trip to the encoded tokens are rejected.
    function testDeployment_revertsWhenMarketIdDoesNotMatchToken() public {
        bytes memory args = abi.encodePacked(
            positionOwner,
            address(collateralToken),
            address(borrowToken),
            uint8(18),
            uint8(18),
            COLLATERAL_MARKET_ID,
            BORROW_MARKET_ID
        );
        PositionHelperDolomiteAssetCX fresh =
            PositionHelperDolomiteAssetCX(ClonesWithImmutableArgs.clone(address(implementation), args));

        _mockMarketTokenAddress(COLLATERAL_MARKET_ID, address(0xdead));
        _mockMarketTokenAddress(BORROW_MARKET_ID, address(borrowToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                DolomiteInitLib.MarketIdTokenMismatch.selector, COLLATERAL_MARKET_ID, address(collateralToken)
            )
        );
        fresh.initialize(
            admin,
            operator,
            address(yieldVault),
            address(liquidationModule),
            liquidator,
            address(redemptionClaimToken),
            REDEMPTION_CLAIM_MARKET_ID,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. setLiquidator
    // ─────────────────────────────────────────────────────────────────────────

    function testSetLiquidator_updatesAndEmits() public {
        address newLiquidator = makeAddr("newLiquidator");

        vm.expectEmit(true, false, false, false, address(helper));
        emit PositionHelperDolomiteAssetCX.LiquidatorUpdated(newLiquidator);

        vm.prank(admin);
        helper.setLiquidator(newLiquidator);

        assertEq(helper.liquidator(), newLiquidator, "liquidator should be updated");
    }

    function testSetLiquidator_revertsWhenCalledByNonAdmin() public {
        vm.prank(operator);
        vm.expectRevert();
        helper.setLiquidator(makeAddr("newLiquidator"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. hasLiquidatorRole
    // ─────────────────────────────────────────────────────────────────────────

    function testHasLiquidatorRole_falseByDefault() public view {
        assertFalse(helper.hasLiquidatorRole(), "role not granted yet");
    }

    function testHasLiquidatorRole_trueAfterGrant() public {
        liquidationModule.grantRole(LIQUIDATOR_ROLE, address(helper));
        assertTrue(helper.hasLiquidatorRole(), "role should be granted");
    }

    function testHasLiquidatorRole_falseAfterRevoke() public {
        liquidationModule.grantRole(LIQUIDATOR_ROLE, address(helper));
        assertTrue(helper.hasLiquidatorRole(), "sanity: role granted");

        liquidationModule.revokeRole(LIQUIDATOR_ROLE, address(helper));
        assertFalse(helper.hasLiquidatorRole(), "role should be revoked");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. _getLenderApprovals / checkApprovals
    // ─────────────────────────────────────────────────────────────────────────

    function testCheckApprovals_neitherOperatorNorLiquidatorRole() public view {
        PositionApprovals memory approvals = helper.checkApprovals();
        assertFalse(approvals.lenderCollateralApproved, "collateral approval requires operator + liquidator role");
        assertFalse(approvals.lenderDebtDelegated, "debt delegation requires operator");
    }

    function testCheckApprovals_operatorOnlyIsNotEnoughForCollateral() public {
        _mockIsOperator(true);

        PositionApprovals memory approvals = helper.checkApprovals();
        assertFalse(approvals.lenderCollateralApproved, "collateral approval also needs LIQUIDATOR_ROLE");
        assertTrue(approvals.lenderDebtDelegated, "debt delegation only needs operator status");
    }

    function testCheckApprovals_liquidatorRoleOnlyIsNotEnoughForCollateral() public {
        liquidationModule.grantRole(LIQUIDATOR_ROLE, address(helper));

        PositionApprovals memory approvals = helper.checkApprovals();
        assertFalse(approvals.lenderCollateralApproved, "collateral approval also needs operator status");
        assertFalse(approvals.lenderDebtDelegated, "debt delegation still needs operator status");
    }

    function testCheckApprovals_operatorAndLiquidatorRoleBothSet() public {
        _mockIsOperator(true);
        liquidationModule.grantRole(LIQUIDATOR_ROLE, address(helper));

        PositionApprovals memory approvals = helper.checkApprovals();
        assertTrue(approvals.lenderCollateralApproved, "both conditions met");
        assertTrue(approvals.lenderDebtDelegated, "operator status met");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. getCollateralAmount / getDebtAmount / getPosition — primary only
    // ─────────────────────────────────────────────────────────────────────────

    function testGetCollateralAmount_zeroWhenNoActivity() public view {
        assertEq(helper.getCollateralAmount(), 0, "collateral should be 0 before any activity");
    }

    function testGetCollateralAmount_excludesRedemptionClaim() public {
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 10 ether);
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 4 ether, 0, true);

        assertEq(helper.getCollateralAmount(), 10 ether, "collateral should exclude redemption claim");
    }

    function testGetDebtAmount_excludesClaimTokenDebt() public {
        _mockAccountWei(BORROW_MARKET_ID, false, 1_000e6);
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 0, 200e6, true);

        assertEq(helper.getDebtAmount(), 1_000e6, "debt should exclude claim-token debt");
    }

    function testGetPosition_excludesRedemptionClaim() public {
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 10 ether);
        _mockAccountWei(BORROW_MARKET_ID, false, 1_000e6);
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 4 ether, 200e6, true);

        (uint256 collateral, uint256 debt) = helper.getPosition();
        assertEq(collateral, 10 ether, "getPosition collateral should exclude redemption claim");
        assertEq(debt, 1_000e6, "getPosition debt should exclude claim-token debt");
    }

    function testGetFullAssetCXPosition_includesActiveLiquidation() public {
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 10 ether);
        _mockAccountWei(BORROW_MARKET_ID, false, 1_000e6);
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 4 ether, 200e6, true);

        (uint256 collateral, uint256 debt, uint256 claimAmount, uint256 claimDebt) = helper.getFullAssetCXPosition();
        assertEq(collateral, 10 ether, "primary collateral only");
        assertEq(debt, 1_000e6, "primary debt only");
        assertEq(claimAmount, 4 ether, "redemption claim collateral from active liquidation");
        assertEq(claimDebt, 200e6, "redemption claim debt from active liquidation");
    }

    function testGetFullAssetCXPosition_excludesInactiveLiquidation() public {
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 10 ether);
        _mockAccountWei(BORROW_MARKET_ID, false, 1_000e6);
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 4 ether, 200e6, false);

        (uint256 collateral, uint256 debt, uint256 claimAmount, uint256 claimDebt) = helper.getFullAssetCXPosition();
        assertEq(collateral, 10 ether, "primary collateral only");
        assertEq(debt, 1_000e6, "primary debt only");
        assertEq(claimAmount, 0, "inactive liquidation should not contribute collateral");
        assertEq(claimDebt, 0, "inactive liquidation should not contribute debt");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. getCurrentLtvWithLiquidationsInWad
    // ─────────────────────────────────────────────────────────────────────────

    function testGetCurrentLtvWithLiquidationsInWad_zeroWhenNoCollateral() public view {
        assertEq(helper.getCurrentLtvWithLiquidationsInWad(), 0, "LTV should be 0 with no collateral at all");
    }

    function testGetCurrentLtvWithLiquidationsInWad_primaryOnly() public {
        // 10 collateral at $2,000 => $20,000 collateral value. 8,000 debt (borrow token, $1 each).
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 10 ether);
        _mockAccountWei(BORROW_MARKET_ID, false, 8_000 ether);
        _mockMarketPrice(COLLATERAL_MARKET_ID, 2_000 ether);
        _mockMarketPrice(BORROW_MARKET_ID, 1 ether);

        // 8,000 / 20,000 = 40%
        assertEq(helper.getCurrentLtvWithLiquidationsInWad(), 400_000_000_000_000_000, "LTV mismatch");
    }

    function testGetCurrentLtvWithLiquidationsInWad_includesActiveLiquidation() public {
        // Collateral: 10 primary at $2,000 = $20,000, plus 5,000 redemption-claim tokens
        // (priced 1:1 with the borrow token) => $25,000 total collateral value.
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 10 ether);
        _mockMarketPrice(COLLATERAL_MARKET_ID, 2_000 ether);
        _mockMarketPrice(BORROW_MARKET_ID, 1 ether);
        // Debt: 8,000 primary + 2,000 against the redemption claim market => $10,000 total debt.
        _mockAccountWei(BORROW_MARKET_ID, false, 8_000 ether);
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 5_000 ether, 2_000 ether, true);

        // 10,000 / 25,000 = 40%
        assertEq(helper.getCurrentLtvWithLiquidationsInWad(), 400_000_000_000_000_000, "LTV mismatch");
    }

    function testGetCurrentLtvWithLiquidationsInWad_excludesInactiveLiquidation() public {
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 10 ether);
        _mockMarketPrice(COLLATERAL_MARKET_ID, 2_000 ether);
        _mockMarketPrice(BORROW_MARKET_ID, 1 ether);
        _mockAccountWei(BORROW_MARKET_ID, false, 8_000 ether);
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 5_000 ether, 2_000 ether, false);

        // Inactive liquidation ignored => same as primary-only: 8,000 / 20,000 = 40%
        assertEq(helper.getCurrentLtvWithLiquidationsInWad(), 400_000_000_000_000_000, "LTV mismatch");
    }

    /// @dev Redemption claim token with FEWER decimals (6) than the borrow token (18): its raw
    ///      balance must be scaled UP. Unscaled, the raw amount (1,000e6) would be summed as if it
    ///      were borrow-token units, understating collateral value by 12 orders of magnitude and
    ///      overstating the LTV accordingly.
    function testGetCurrentLtvWithLiquidationsInWad_normalizesRedemptionClaimFewerDecimals() public {
        ERC20MockWithDecimals rc6 = new ERC20MockWithDecimals("6-Decimal Claim", "RC6", 6);
        PositionHelperDolomiteAssetCX fresh = _cloneUninitialized();
        _initialize(fresh, address(rc6));

        // No primary collateral/debt; only an active liquidation supplying 1,000 RC6 tokens
        // (1,000e6 raw) against 500 borrow-token debt on the temp position.
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 1_000e6, 500 ether, true);

        // Collateral value = 1,000e6 * 10**(18-6) = 1,000e18. Debt value = 500e18.
        // LTV = 500e18 / 1,000e18 = 50%.
        assertEq(fresh.getCurrentLtvWithLiquidationsInWad(), 500_000_000_000_000_000, "LTV mismatch");
    }

    /// @dev Redemption claim token with MORE decimals (24) than the borrow token (18): its raw
    ///      balance must be scaled DOWN, or collateral value would be overstated and the LTV
    ///      understated by the same factor.
    function testGetCurrentLtvWithLiquidationsInWad_normalizesRedemptionClaimMoreDecimals() public {
        ERC20MockWithDecimals rc24 = new ERC20MockWithDecimals("24-Decimal Claim", "RC24", 24);
        PositionHelperDolomiteAssetCX fresh = _cloneUninitialized();
        _initialize(fresh, address(rc24));

        // 1,000 RC24 tokens (1,000e24 raw) against 500 borrow-token debt on the temp position.
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 1_000e24, 500 ether, true);

        // Collateral value = 1,000e24 / 10**(24-18) = 1,000e18. Debt value = 500e18.
        // LTV = 500e18 / 1,000e18 = 50%.
        assertEq(fresh.getCurrentLtvWithLiquidationsInWad(), 500_000_000_000_000_000, "LTV mismatch");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. _selfLiquidate delegation to liquidationModule
    // ─────────────────────────────────────────────────────────────────────────

    function testSelfLiquidate_delegatesExplicitDebtAmountToLiquidationModule() public {
        // Admin bypasses the canLiquidate LTV gate, so no LTV/price mocks are needed here.
        // debtAmount must be at or below the outstanding debt or it gets clamped.
        _mockAccountWei(BORROW_MARKET_ID, false, 700e6);

        vm.prank(admin);
        helper.selfLiquidate(500e6, 0);

        assertEq(liquidationModule.lastPositionOwner(), positionOwner, "positionOwner mismatch");
        assertEq(liquidationModule.lastAccountNumber(), ACCOUNT_NUMBER, "accountNumber mismatch");
        assertEq(liquidationModule.lastDebtAmountToLiquidate(), 500e6, "explicit debt amount should pass through");
        assertEq(liquidationModule.lastReceiver(), liquidator, "receiver should be the liquidator");
        assertEq(liquidationModule.callCount(), 1, "liquidation module should be called exactly once");
    }

    function testSelfLiquidate_fullDebtAmountUsesPrimaryGetDebtAmount() public {
        _mockAccountWei(BORROW_MARKET_ID, false, 700e6);
        // Redemption-claim debt from an in-flight liquidation must not inflate the amount liquidated.
        _seedLiquidation(1, TEMP_ACCOUNT_NUMBER, 0, 300e6, true);

        vm.prank(admin);
        helper.selfLiquidate(type(uint256).max, 0);

        assertEq(liquidationModule.lastDebtAmountToLiquidate(), 700e6, "should liquidate primary debt only");
    }

    function testSelfLiquidate_revertsWhenNoDebt() public {
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.NoDebt.selector);
        helper.selfLiquidate(0, 0);
    }

    function testSelfLiquidateToLtv_disabled() public {
        vm.prank(admin);
        vm.expectRevert(PositionHelperDolomiteAssetCX.SelfLiquidateToLtvDisabled.selector);
        helper.selfLiquidateToLtv(500_000_000_000_000_000, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. collateralPriceInBorrowTokensInRay
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A zero collateral-market oracle price must revert with `ZeroMarketPrice` instead of
    ///      silently returning 0 (which would then propagate into a second division-by-zero
    ///      panic in callers like `selfLiquidateDolomiteNative`).
    function testCollateralPriceInBorrowTokensInRay_revertsWhenCollateralPriceZero() public {
        _mockMarketPrice(COLLATERAL_MARKET_ID, 0);
        _mockMarketPrice(BORROW_MARKET_ID, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DolomitePositionViewLib.ZeroMarketPrice.selector, COLLATERAL_MARKET_ID));
        helper.collateralPriceInBorrowTokensInRay();
    }

    /// @dev A zero borrow-market oracle price must revert with `ZeroMarketPrice` instead of an
    ///      opaque `Panic(0x12)` division-by-zero from `mulDiv`.
    function testCollateralPriceInBorrowTokensInRay_revertsWhenBorrowPriceZero() public {
        _mockMarketPrice(COLLATERAL_MARKET_ID, 2_000 ether);
        _mockMarketPrice(BORROW_MARKET_ID, 0);

        vm.expectRevert(abi.encodeWithSelector(DolomitePositionViewLib.ZeroMarketPrice.selector, BORROW_MARKET_ID));
        helper.collateralPriceInBorrowTokensInRay();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. onlySingleCollateralPosition / canTransfer — shared Base guard
    // ─────────────────────────────────────────────────────────────────────────
    //
    // `_requireSingleCollateralPosition`/`_isSafe` live on `PositionHelperDolomiteBase`, shared
    // with `PositionHelperDolomiteNative` — these confirm the AssetCX flavour is wired up the
    // same way, not just that the Base logic works (that's covered in the Native fork tests).

    function testOnlySingleCollateralPosition_revertsOnMultipleCollateralMarkets() public {
        _mockNumberOfMarketsWithBalances(2);
        _mockNumberOfMarketsWithDebt(0);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.deploy(0, 0);
    }

    function testOnlySingleCollateralPosition_revertsOnMultipleDebtMarkets() public {
        _mockNumberOfMarketsWithBalances(3);
        _mockNumberOfMarketsWithDebt(2);
        _mockAccountWei(COLLATERAL_MARKET_ID, true, 1 ether); // passes the collateral identity check

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleDebtReservesDetected.selector);
        helper.deploy(0, 0);
    }

    function testCanTransfer_operatorRevertsWhenDefaultAccountHasExtraMarkets() public {
        _mockNumberOfMarketsWithBalances(2);
        _mockNumberOfMarketsWithDebt(0);

        // otherAccountNumber == ACCOUNT_NUMBER here purely to reuse the account-0 mocks above —
        // `canTransfer`'s guard runs before `operate()`, so the transfer's real semantics never matter.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PositionHelperDolomiteBase.AccountLeftInSelfLiqZone.selector, operator));
        helper.transferFromDefaultAccount(COLLATERAL_MARKET_ID, 0, ACCOUNT_NUMBER);
    }
}
