// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

// ── Clone library ─────────────────────────────────────────────────────────────
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

// ── OpenZeppelin ──────────────────────────────────────────────────────────────
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

// ── Protocol ──────────────────────────────────────────────────────────────────
import {ConcreteFactory} from "../../../src/factory/ConcreteFactory.sol";
import {ConcreteAsyncVaultImpl} from "../../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {AllocateModule} from "../../../src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

// ── Test mocks ────────────────────────────────────────────────────────────────
import {MockFlashModule} from "../mock/MockFlashModule.sol";
import {MockSwapper} from "../mock/MockSwapper.sol";
import {MockDolomiteExchangeWrapper} from "../mock/MockDolomiteExchangeWrapper.sol";

// ── Subject under test ────────────────────────────────────────────────────────
import {PositionHelperDolomiteNative} from "../../../src/periphery/positionhelper/PositionHelperDolomiteNative.sol";
import {PositionHelperDolomiteBase} from "../../../src/periphery/positionhelper/PositionHelperDolomiteBase.sol";
import {DolomitePositionViewLib} from "../../../src/periphery/lib/DolomitePositionViewLib.sol";
import {DolomiteInitLib} from "../../../src/periphery/lib/DolomiteInitLib.sol";
import {IDolomiteMargin, DolomiteAccount} from "../../../src/periphery/interface/IDolomiteMargin.sol";
import {IPositionHelperBase, PositionApprovals} from "../../../src/periphery/interface/IPositionHelperBase.sol";
import {PositionManagementHelperLib as PMHLib} from "../../../src/periphery/lib/PositionManagementHelperLib.sol";
import {WAD, RAY} from "../../../src/periphery/lib/Constants.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

/// @dev Minimal interface for the one Dolomite call not in IDolomiteMargin (operator management).
interface IDolomiteOperatorSetter {
    struct OperatorArg {
        address operator;
        bool trusted;
    }

    function setOperators(OperatorArg[] calldata args) external;
}

/// @title  PositionHelperDolomiteTest
/// @notice Fork-based unit tests for PositionHelperDolomiteNative using WETH as collateral
///         and USDC as borrow token against the Dolomite mainnet deployment.
///
/// @dev Setup overview:
///   • Ethereum mainnet fork (MAINNET_RPC_URL).
///   • Lender: DolomiteMargin at 0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D.
///   • Token pair: WETH (collateral) / USDC (borrow). Market IDs resolved at setUp time
///     via `implementation.resolveTokenInfo()` so they stay correct if markets shift.
///   • positionOwner grants helper `setOperators` authority — one call covers both
///     supply-withdraw and borrow-repay (unlike Aave which needs separate approvals).
///   • Vault: freshly deployed ConcreteAsyncVaultImpl with USDC as asset.
///
/// @dev Price mocking:
///   Dolomite's internal `getAccountValues` uses market prices from its oracle registry.
///   For scenario tests, both `getMarketPrice` (used by `collateralPriceInBorrowTokensInRay`)
///   AND `getAccountValues` (used by `getCurrentLtvInWad`) are mocked independently so
///   all views return consistent values without depending on live Chainlink state.
///
///   Oracle price format (Dolomite): "USD value of 1 wei, scaled to 36 decimals"
///     WETH ($2,000): 1 wei = $2e-15  → 2e-15 * 1e36 = 2000 * 1e18
///     USDC ($1):     1 wei = $1e-6   → 1e-6  * 1e36 =       1e30
contract PositionHelperDolomiteTest is Test {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ── Mainnet constants ─────────────────────────────────────────────────────

    address internal constant DOLOMITE_MARGIN = 0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // 22_800_000 previously used here had zero real USDC liquidity in DolomiteMargin (this pool's
    // USDC market held nothing for the entire 20_000_000-22_800_000 range), so any borrow reverted
    // with "Token: transfer failed". 24_000_000 had healthy liquidity but later started reverting
    // with "AccountRiskOverrideSetter: Invalid account for debt" — Dolomite's risk-override module
    // (queried via getAccountRiskOverride on every operate() call) started rejecting this test's
    // account/market pair at that block, likely due to an on-chain config change to the risk
    // override setter. 25_100_000 clears that and has healthy USDC liquidity for the borrows
    // exercised in these tests (~144k USDC).
    uint256 internal constant FORK_BLOCK = 25_100_000;
    uint8 internal constant WETH_DECIMALS = 18;
    uint8 internal constant USDC_DECIMALS = 6;
    uint256 internal constant ACCOUNT_NUMBER = 0;

    // ── Oracle price mock values ──────────────────────────────────────────────

    // WETH ($2,000): getMarketPrice returns 2000 * 1e18
    // USDC ($1):     getMarketPrice returns 1e30
    // Resulting collateralPriceInBorrowTokensInRay = 2000e18 * RAY / 1e30 = 2e18
    //   => 1 WETH wei = 2e18/RAY USDC wei => 100 WETH = 200_000 USDC at 100% LTV
    uint256 internal constant WETH_PRICE_MOCK = 2_000 * 1e18;
    uint256 internal constant USDC_PRICE_MOCK = 1e30;

    // ── LTV parameters (WAD-scaled) ───────────────────────────────────────────

    uint64 internal constant HEALTHY_LTV = 600_000_000_000_000_000; // 60%
    uint64 internal constant HEALTHY_LTV_DEVIATION = 50_000_000_000_000_000; // 5%
    uint64 internal constant SELF_LIQ_BUFFER = 50_000_000_000_000_000; // 5%

    // ── Contracts ─────────────────────────────────────────────────────────────

    PositionHelperDolomiteNative internal implementation;
    PositionHelperDolomiteNative internal helper;
    ConcreteAsyncVaultImpl internal targetVault;

    // ── Dolomite market IDs (resolved from live chain in setUp) ───────────────

    uint256 internal wethMarketId;
    uint256 internal usdcMarketId;

    // ── Actors ────────────────────────────────────────────────────────────────

    address internal positionOwner;
    address internal admin;
    address internal operator;
    address internal flashModule;
    address internal swapModule;
    address internal vaultAdmin;
    address internal vaultManager;

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        // ── Actors ────────────────────────────────────────────────────────────
        positionOwner = makeAddr("positionOwner");
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        vaultAdmin = makeAddr("vaultAdmin");
        vaultManager = makeAddr("vaultManager");

        // ── Modules ───────────────────────────────────────────────────────────
        flashModule = address(new MockFlashModule(admin, 0));
        swapModule = address(new MockSwapper(admin));

        // ── Deploy ConcreteAsyncVaultImpl as target vault (USDC asset) ────────
        address factoryOwner = makeAddr("factoryOwner");
        address managementFeeRecipient = makeAddr("managementFeeRecipient");
        address performanceFeeRecipient = makeAddr("performanceFeeRecipient");

        address factoryImpl = address(new ConcreteFactory());
        ConcreteFactory factory = ConcreteFactory(
            address(
                new ERC1967Proxy(factoryImpl, abi.encodeCall(ConcreteFactory.initialize, (factoryOwner, address(0))))
            )
        );
        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(managementFeeRecipient, performanceFeeRecipient);

        ConcreteAsyncVaultImpl asyncVaultImpl = new ConcreteAsyncVaultImpl(address(factory));
        uint64 vaultImpl = uint64(IContractId(address(asyncVaultImpl)).ID());
        vm.prank(factoryOwner);
        factory.approveImplementation(address(asyncVaultImpl));

        AllocateModule allocateModule = new AllocateModule();
        targetVault = ConcreteAsyncVaultImpl(
            factory.create(
                vaultImpl,
                vaultAdmin,
                abi.encode(address(allocateModule), USDC, vaultManager, "Test Dolomite USDC Vault", "tdUSDC")
            )
        );

        // ── Deploy PositionHelperDolomiteNative implementation ─────────────────
        implementation = new PositionHelperDolomiteNative(DOLOMITE_MARGIN, ACCOUNT_NUMBER);

        // ── Resolve Dolomite market IDs from the live chain ───────────────────
        wethMarketId = implementation.resolveTokenInfo(WETH);
        usdcMarketId = implementation.resolveTokenInfo(USDC);

        // ── Clone with immutable args (base 62 bytes + 32 + 32 market IDs = 126) ──
        bytes memory cloneArgs = abi.encodePacked(
            positionOwner, WETH, USDC, uint8(WETH_DECIMALS), uint8(USDC_DECIMALS), wethMarketId, usdcMarketId
        );
        helper = PositionHelperDolomiteNative(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        // ── Initialize clone ──────────────────────────────────────────────────
        // dolomiteExchangeWrapper_ = address(0): use flash+swap path (flashModule is non-zero)
        helper.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            address(0),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );

        // ── Grant helper WITHDRAWAL_MANAGER on targetVault ────────────────────
        vm.prank(vaultManager);
        targetVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, address(helper));

        // ── Labels ────────────────────────────────────────────────────────────
        vm.label(DOLOMITE_MARGIN, "DolomiteMargin");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(positionOwner, "positionOwner");
        vm.label(admin, "admin");
        vm.label(operator, "operator");
        vm.label(address(helper), "PositionHelper(clone)");
        vm.label(address(implementation), "PositionHelper(impl)");
        vm.label(address(targetVault), "targetVault");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Grants helper operator authority on DolomiteMargin for positionOwner.
    ///      One call covers both withdraw (collateral) and borrow on positionOwner's account.
    function _setOperator() internal {
        IDolomiteOperatorSetter.OperatorArg[] memory ops = new IDolomiteOperatorSetter.OperatorArg[](1);
        ops[0] = IDolomiteOperatorSetter.OperatorArg({operator: address(helper), trusted: true});
        vm.prank(positionOwner);
        IDolomiteOperatorSetter(DOLOMITE_MARGIN).setOperators(ops);
    }

    /// @dev Sets every positionOwner approval required for the full helper surface.
    function _setupOwnerApprovals() internal {
        _setOperator();
        vm.startPrank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max); // supply
        IERC20(USDC).forceApprove(address(helper), type(uint256).max); // repay
        IERC20(address(targetVault)).approve(address(helper), type(uint256).max); // redeem
        vm.stopPrank();
    }

    /// @dev Deals WETH to positionOwner, approves helper for WETH, and calls supply.
    function _supply(uint256 amount) internal {
        deal(WETH, positionOwner, amount);
        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        vm.prank(operator);
        helper.supply(amount);
    }

    /// @dev Supplies collateral then borrows USDC.
    ///      positionOwner must have granted setOperators before calling.
    function _supplyAndBorrow(uint256 collateral, uint256 borrowAmount) internal {
        _supply(collateral);
        vm.prank(operator);
        helper.borrow(borrowAmount);
    }

    /// @dev Mocks both views used by price-sensitive operations.
    ///      `getMarketPrice` → used by `collateralPriceInBorrowTokensInRay`.
    ///      `getAccountValues` → used by `getCurrentLtvInWad`.
    function _mockPrices(uint256 wethPriceMock, uint256 supplyValue, uint256 borrowValue) internal {
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getMarketPrice.selector, wethMarketId),
            abi.encode(wethPriceMock)
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getMarketPrice.selector, usdcMarketId),
            abi.encode(USDC_PRICE_MOCK)
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(
                IDolomiteMargin.getAccountValues.selector, DolomiteAccount.Info({owner: positionOwner, number: 0})
            ),
            abi.encode(supplyValue, borrowValue)
        );
    }

    /// @dev Sets deterministic prices and approvals for scenario tests.
    ///      At WETH=$2,000: 100 WETH collateral has $200k supply value.
    ///      At 50% LTV: $100k borrow (= 100_000 USDC).
    function _scenarioSetup() internal {
        // Initial price: WETH=$2,000 → supplyValue=$200k, borrowValue=$100k (50% LTV)
        _mockPrices(WETH_PRICE_MOCK, 200_000e18, 100_000e18);
        _setupOwnerApprovals();
    }

    /// @dev Deploy 100 WETH at 50% LTV using mocked prices. Returns vault shares minted.
    function _deployAt50Pct() internal returns (uint256 shares) {
        deal(WETH, positionOwner, 100 ether);
        vm.prank(operator);
        helper.deploy(100 ether, 500_000_000_000_000_000); // 50%
        shares = IERC20(address(targetVault)).balanceOf(positionOwner);
    }

    /// @dev Grants `account` the WITHDRAWAL_MANAGER role via vaultManager
    ///      (who holds WITHDRAWAL_MANAGER_ADMIN from vault initialization).
    function _grantWithdrawalManager(address account) internal {
        vm.prank(vaultManager);
        targetVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, account);
    }

    /// @dev Closes and processes the current vault epoch (makes queued redemptions claimable).
    function _processCurrentEpoch() internal {
        _grantWithdrawalManager(vaultManager);
        vm.prank(vaultManager);
        targetVault.closeEpoch();
        vm.prank(vaultManager);
        targetVault.processEpoch();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Deployment & init
    // ─────────────────────────────────────────────────────────────────────────

    function testDeployment_verifyImmutables() public view {
        assertEq(helper.POSITION_OWNER(), positionOwner, "POSITION_OWNER mismatch");
        assertEq(helper.COLLATERAL_TOKEN(), WETH, "COLLATERAL_TOKEN mismatch");
        assertEq(helper.BORROW_TOKEN(), USDC, "BORROW_TOKEN mismatch");
        assertEq(helper.COLLATERAL_DECIMALS(), WETH_DECIMALS, "COLLATERAL_DECIMALS mismatch");
        assertEq(helper.BORROW_DECIMALS(), USDC_DECIMALS, "BORROW_DECIMALS mismatch");
        assertEq(address(helper.DOLOMITE_MARGIN()), DOLOMITE_MARGIN, "DOLOMITE_MARGIN mismatch");
        assertEq(helper.COLLATERAL_MARKET_ID(), wethMarketId, "COLLATERAL_MARKET_ID mismatch");
        assertEq(helper.BORROW_MARKET_ID(), usdcMarketId, "BORROW_MARKET_ID mismatch");
        uint64 id = uint64(IContractId(address(helper)).ID());
        assertEq(id, 400310600, "ID must be 400310600 (position helper dolomite native v1.6.0)");
    }

    function testDeployment_verifyInitParams() public view {
        assertEq(helper.yieldVault(), address(targetVault), "yieldVault mismatch");
        assertEq(helper.flashModule(), flashModule, "flashModule mismatch");
        assertEq(helper.swapModule(), swapModule, "swapModule mismatch");
        assertTrue(helper.hasRole(helper.POSITION_ADMIN_ROLE(), admin), "admin should have POSITION_ADMIN_ROLE");
        assertTrue(
            helper.hasRole(helper.POSITION_OPERATOR_ROLE(), operator), "operator should have POSITION_OPERATOR_ROLE"
        );
    }

    function testDeployment_verifyHelperTokenAllowances() public view {
        assertEq(
            IERC20(WETH).allowance(address(helper), DOLOMITE_MARGIN),
            type(uint256).max,
            "WETH -> DolomiteMargin allowance must be MAX"
        );
        assertEq(
            IERC20(WETH).allowance(address(helper), swapModule),
            type(uint256).max,
            "WETH -> swapModule allowance must be MAX"
        );
        assertEq(
            IERC20(USDC).allowance(address(helper), DOLOMITE_MARGIN),
            type(uint256).max,
            "USDC -> DolomiteMargin allowance must be MAX"
        );
        assertEq(
            IERC20(USDC).allowance(address(helper), address(targetVault)),
            type(uint256).max,
            "USDC -> targetVault allowance must be MAX"
        );
        assertEq(
            IERC20(USDC).allowance(address(helper), flashModule),
            type(uint256).max,
            "USDC -> flashModule allowance must be MAX"
        );
        assertEq(
            IERC20(address(targetVault)).allowance(address(helper), address(targetVault)),
            type(uint256).max,
            "vault shares -> targetVault allowance must be MAX"
        );
    }

    function testDeployment_revertsWhenDolomiteMarginIsZero() public {
        vm.expectRevert(IPositionHelperBase.ZeroAddress.selector);
        new PositionHelperDolomiteNative(address(0), ACCOUNT_NUMBER);
    }

    function testDeployment_revertsOnDoubleInitialize() public {
        vm.expectRevert();
        helper.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            address(0),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    function testDeployment_revertsWhenMissingLiquidationMechanism() public {
        bytes memory args = abi.encodePacked(
            positionOwner, WETH, USDC, uint8(WETH_DECIMALS), uint8(USDC_DECIMALS), wethMarketId, usdcMarketId
        );
        PositionHelperDolomiteNative fresh =
            PositionHelperDolomiteNative(ClonesWithImmutableArgs.clone(address(implementation), args));
        vm.expectRevert(PositionHelperDolomiteBase.MissingLiquidationMechanism.selector);
        fresh.initialize(
            admin,
            operator,
            address(targetVault),
            address(0),
            address(0), // no flashModule, no wrapper
            address(0),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    /// @dev `initialize` must reject a healthy-LTV band that reaches or exceeds the lender's
    ///      liquidation threshold via `_ltvRangeIsValid` — the same guard the Aave/Morpho
    ///      initializers already apply. A 99/1/1 band sums to 101%, which exceeds any real
    ///      liquidation threshold (≤ 100%), so this holds regardless of the live fork's value.
    function testDeployment_revertsWhenLtvRangeInvalid() public {
        bytes memory args = abi.encodePacked(
            positionOwner, WETH, USDC, uint8(WETH_DECIMALS), uint8(USDC_DECIMALS), wethMarketId, usdcMarketId
        );
        PositionHelperDolomiteNative fresh =
            PositionHelperDolomiteNative(ClonesWithImmutableArgs.clone(address(implementation), args));
        // `InvalidLtvRange` carries the live fork's liquidation threshold as an argument, so match
        // on the selector only rather than the fully-encoded error.
        vm.expectPartialRevert(IPositionHelperBase.InvalidLtvRange.selector);
        fresh.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            address(0),
            990_000_000_000_000_000, // 99%
            10_000_000_000_000_000, // 1%
            10_000_000_000_000_000 // 1%
        );
    }

    /// @dev `initialize` must reject a zero self-liq buffer via `_ltvRangeIsValid`, even when the
    ///      healthy LTV band on its own would be valid.
    function testDeployment_revertsWhenSelfLiqBufferZero() public {
        bytes memory args = abi.encodePacked(
            positionOwner, WETH, USDC, uint8(WETH_DECIMALS), uint8(USDC_DECIMALS), wethMarketId, usdcMarketId
        );
        PositionHelperDolomiteNative fresh =
            PositionHelperDolomiteNative(ClonesWithImmutableArgs.clone(address(implementation), args));
        vm.expectRevert(IPositionHelperBase.InvalidSelfLiqThrBufferInWad.selector);
        fresh.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            address(0),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            0
        );
    }

    /// @dev A 62-byte header-only blob (factory skips market IDs when resolveTokenInfo
    ///      reverts) must not finish initialization.
    function testDeployment_revertsWhenMarketIdsMissing() public {
        bytes memory args = abi.encodePacked(positionOwner, WETH, USDC, uint8(WETH_DECIMALS), uint8(USDC_DECIMALS));
        PositionHelperDolomiteNative fresh =
            PositionHelperDolomiteNative(ClonesWithImmutableArgs.clone(address(implementation), args));

        vm.expectRevert(); // getMarketTokenAddress(62 << 240) reverts on Dolomite
        fresh.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            address(0),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    /// @dev Encoded market IDs that do not round-trip to the encoded tokens are rejected.
    function testDeployment_revertsWhenMarketIdDoesNotMatchToken() public {
        bytes memory args = abi.encodePacked(
            positionOwner, WETH, USDC, uint8(WETH_DECIMALS), uint8(USDC_DECIMALS), usdcMarketId, wethMarketId
        );
        PositionHelperDolomiteNative fresh =
            PositionHelperDolomiteNative(ClonesWithImmutableArgs.clone(address(implementation), args));

        vm.expectRevert(abi.encodeWithSelector(DolomiteInitLib.MarketIdTokenMismatch.selector, usdcMarketId, WETH));
        fresh.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            address(0),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. supply
    // ─────────────────────────────────────────────────────────────────────────

    function testSupply_depositsWethToDolomiteUnderPositionOwner() public {
        _setOperator(); // helper must be DolomiteMargin operator before any operate() call
        uint256 supplyAmount = 2 ether;
        deal(WETH, positionOwner, supplyAmount);

        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Supplied(supplyAmount);

        vm.prank(operator);
        helper.supply(supplyAmount);

        assertEq(IERC20(WETH).balanceOf(positionOwner), 0, "positionOwner WETH should be spent");
        assertApproxEqAbs(helper.getCollateralAmount(), supplyAmount, 1e9, "getCollateralAmount mismatch");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    function testSupply_revertsWhenCalledByNonOperator() public {
        deal(WETH, positionOwner, 1 ether);
        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);

        vm.expectRevert();
        helper.supply(1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. borrow
    // ─────────────────────────────────────────────────────────────────────────

    function testBorrow_createsDebtAndSendsUsdcToPositionOwner() public {
        _setOperator(); // must be set before supply (Dolomite deposit needs operator)
        _supply(5 ether);

        uint256 borrowAmount = 100e6; // 100 USDC

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Borrowed(borrowAmount);

        vm.prank(operator);
        helper.borrow(borrowAmount);

        assertEq(IERC20(USDC).balanceOf(positionOwner), borrowAmount, "positionOwner USDC balance mismatch");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
        assertApproxEqAbs(helper.getDebtAmount(), borrowAmount, 1e6, "getDebtAmount mismatch");
        assertGt(helper.getCurrentLtvInWad(), 0, "LTV should be > 0 after borrow");
    }

    function testBorrow_revertsWhenCalledByNonOperator() public {
        _setOperator();
        _supply(5 ether);

        vm.expectRevert();
        helper.borrow(10e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. repay
    // ─────────────────────────────────────────────────────────────────────────

    function testRepay_clearsDebt() public {
        _setOperator(); // must be set before _supplyAndBorrow
        _supplyAndBorrow(5 ether, 200e6);

        uint256 debtBefore = helper.getDebtAmount();
        assertGt(debtBefore, 0, "no debt to repay");

        deal(USDC, positionOwner, debtBefore);
        vm.prank(positionOwner);
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);

        vm.expectEmit(false, false, false, false, address(helper));
        emit IPositionHelperBase.Repaid(0);

        vm.prank(operator);
        helper.repay(debtBefore);

        assertApproxEqAbs(helper.getDebtAmount(), 0, 1e4, "debt should be fully cleared (within 10k USDC wei dust)");
        assertEq(helper.getCurrentLtvInWad(), 0, "LTV must be 0 after full repay");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    function testRepay_revertsWhenCalledByNonOperator() public {
        deal(USDC, positionOwner, 100e6);
        vm.prank(positionOwner);
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);

        vm.expectRevert();
        helper.repay(100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. withdraw
    // ─────────────────────────────────────────────────────────────────────────

    function testWithdraw_returnsCollateralToPositionOwner() public {
        uint256 supplyAmount = 5 ether;
        uint256 withdrawAmount = supplyAmount / 2;
        _setOperator(); // must be set before supply
        _supply(supplyAmount);

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Withdrawn(withdrawAmount);

        vm.prank(operator);
        helper.withdraw(withdrawAmount);

        assertApproxEqAbs(IERC20(WETH).balanceOf(positionOwner), withdrawAmount, 1e9, "WETH balance mismatch");
        assertApproxEqAbs(helper.getCollateralAmount(), supplyAmount - withdrawAmount, 1e9, "remaining collateral");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    function testWithdraw_revertsWhenCalledByNonOperator() public {
        _setOperator();
        _supply(2 ether);

        vm.expectRevert();
        helper.withdraw(1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. deploy (high-level)
    // ─────────────────────────────────────────────────────────────────────────

    function testDeploy_supplyBorrowDepositToTargetLtv() public {
        _scenarioSetup();

        uint256 collateralAmount = 5 ether;
        deal(WETH, positionOwner, collateralAmount);

        uint64 targetLtvInWad = 500_000_000_000_000_000; // 50%
        vm.prank(operator);
        helper.deploy(collateralAmount, targetLtvInWad);

        assertApproxEqAbs(helper.getCollateralAmount(), collateralAmount, 1e9, "collateral not supplied");
        assertGt(helper.getDebtAmount(), 0, "no debt after deploy");
        // With mocked prices: 5 WETH × $2k × 50% = 5,000 USDC debt
        assertApproxEqAbs(helper.getDebtAmount(), 5_000e6, 100, "debt should be ~5k USDC");
        assertGt(IERC20(address(targetVault)).balanceOf(positionOwner), 0, "positionOwner should hold vault shares");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    function testDeploy_withZeroTargetLtv_onlySupplies() public {
        _setOperator(); // Dolomite deposit needs helper as operator
        uint256 collateralAmount = 3 ether;
        deal(WETH, positionOwner, collateralAmount);
        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);

        vm.prank(operator);
        helper.deploy(collateralAmount, 0);

        assertApproxEqAbs(helper.getCollateralAmount(), collateralAmount, 1e9, "collateral should be supplied");
        assertEq(helper.getDebtAmount(), 0, "no debt expected when targetLtv = 0");
        assertEq(IERC20(address(targetVault)).balanceOf(positionOwner), 0, "no vault shares");
    }

    function testDeploy_revertsWhenTargetLtvExceedsMaxLtv() public {
        uint64 tooHighLtv = helper.getMaxLtvInWad() + 1;

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.TargetLtvExceedsMaxLtv.selector);
        helper.deploy(1 ether, tooHighLtv);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. View / position data
    // ─────────────────────────────────────────────────────────────────────────

    function testGetPosition_returnsZeroBeforeActivity() public view {
        (uint256 col, uint256 debt) = helper.getPosition();
        assertEq(col, 0, "collateral should be 0");
        assertEq(debt, 0, "debt should be 0");
        assertEq(helper.getCurrentLtvInWad(), 0, "LTV should be 0");
    }

    function testGetMaxLtvInWad_equalsLiquidationThreshold() public view {
        // Dolomite has no separate borrow cap — max LTV equals the liquidation threshold.
        assertEq(helper.getMaxLtvInWad(), helper.getLiquidationThresholdInWad(), "max LTV should equal liq threshold");
        assertGt(helper.getMaxLtvInWad(), 0, "max LTV should be > 0");
        assertLt(helper.getMaxLtvInWad(), WAD, "max LTV should be < 100%");
    }

    function testGetLiquidationThresholdInWad_isReasonable() public view {
        uint64 liqThr = helper.getLiquidationThresholdInWad();
        // Dolomite's default margin ratio is 15% → threshold = 1/1.15 ≈ 86.96%
        assertGt(liqThr, 800_000_000_000_000_000, "liq threshold should be > 80%");
        assertLt(liqThr, WAD, "liq threshold should be < 100%");
    }

    /// @dev The returned rate is borrow-token *wei* per collateral *wei*, in RAY — Dolomite's
    ///      `getMarketPrice` is quoted at `36 − tokenDecimals`, i.e. already per-wei, so the two
    ///      prices divide directly with no decimals rescaling.
    ///
    ///      Bounded on BOTH sides on purpose: a lower bound alone passes just as happily when the
    ///      price is rescaled by `10**(18−6)`, which is exactly the mistake this pins down.
    ///      At $100–$100k per ETH and ~$1 per USDC: 1 WETH wei buys 1e-13…1e-8 USDC wei.
    function testCollateralPrice_returnsReasonableWethUsdcPrice() public view {
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        // 1 WETH ≥ 100 USDC  →  100e6 * RAY / 1e18
        assertGt(price, 100e6 * RAY / 1e18, "WETH price below sane floor");
        // 1 WETH ≤ 100_000 USDC  →  100_000e6 * RAY / 1e18.  Catches whole-token-denominated
        // prices, which land ~1e12 above this ceiling.
        assertLt(price, 100_000e6 * RAY / 1e18, "WETH price above sane ceiling (whole-unit scaling?)");
    }

    /// @dev `Math.mulDiv` keeps the full 512-bit product, so `cPrice * RAY` never has to fit in a
    ///      uint256 — only the quotient does. Even an absurd price pair stays far below the type's
    ///      ceiling, so no defensive down-scaling (e.g. via WAD) is warranted.
    function testCollateralPrice_extremePriceRatioDoesNotOverflow() public {
        // cPrice at uint128 max over the smallest non-zero bPrice: 3.4e38 * 1e27 = 3.4e65,
        // ~12 orders of magnitude below type(uint256).max ≈ 1.16e77.
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getMarketPrice.selector, wethMarketId),
            abi.encode(uint256(type(uint128).max))
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getMarketPrice.selector, usdcMarketId),
            abi.encode(uint256(1))
        );

        assertEq(
            helper.collateralPriceInBorrowTokensInRay(),
            uint256(type(uint128).max) * RAY,
            "extreme ratio must compute exactly, not overflow"
        );
    }

    /// @dev A zero collateral-market (WETH) oracle price must revert with `ZeroMarketPrice`
    ///      instead of silently returning 0, which would then propagate into a second
    ///      division-by-zero panic in callers like `selfLiquidateDolomiteNative`.
    function testCollateralPrice_revertsWhenCollateralPriceZero() public {
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getMarketPrice.selector, wethMarketId),
            abi.encode(0)
        );

        vm.expectRevert(abi.encodeWithSelector(DolomitePositionViewLib.ZeroMarketPrice.selector, wethMarketId));
        helper.collateralPriceInBorrowTokensInRay();
    }

    /// @dev A zero borrow-market (USDC) oracle price must revert with `ZeroMarketPrice` instead
    ///      of an opaque `Panic(0x12)` division-by-zero from `mulDiv`.
    function testCollateralPrice_revertsWhenBorrowPriceZero() public {
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getMarketPrice.selector, usdcMarketId),
            abi.encode(0)
        );

        vm.expectRevert(abi.encodeWithSelector(DolomitePositionViewLib.ZeroMarketPrice.selector, usdcMarketId));
        helper.collateralPriceInBorrowTokensInRay();
    }

    function testGetAvailablePoolLiquidity_returnsNonZero() public view {
        // Returns USDC balance held by DolomiteMargin — non-zero on mainnet
        uint256 liquidity = helper.getAvailablePoolLiquidity();
        assertGt(liquidity, 0, "DolomiteMargin should hold USDC");
    }

    function testGetBorrowRateInWad_returnsNonZero() public view {
        assertGt(helper.getBorrowRateInWad(), 0, "borrow rate should be > 0");
    }

    function testGetSupplyRateInWad_returnsNonNegative() public view {
        // Supply rate may be 0 if utilisation is zero; just verify it doesn't revert.
        helper.getSupplyRateInWad();
    }

    function testGetEarningsRate_returnsNonZero() public view {
        assertGt(helper.getEarningsRate(), 0, "earnings rate should be > 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. checkApprovals
    // ─────────────────────────────────────────────────────────────────────────

    function testCheckApprovals_reflectsOwnerApprovals() public {
        PositionApprovals memory before_ = helper.checkApprovals();
        assertFalse(before_.lenderCollateralApproved, "operator not set yet");
        assertFalse(before_.lenderDebtDelegated, "operator not set yet");
        assertFalse(before_.borrowTokenApproved, "USDC not approved yet");

        _setupOwnerApprovals();

        PositionApprovals memory after_ = helper.checkApprovals();
        assertTrue(after_.collateralTokenApproved, "WETH should be approved");
        assertTrue(after_.lenderCollateralApproved, "operator should be set (covers collateral)");
        assertTrue(after_.lenderDebtDelegated, "operator should be set (covers debt)");
        assertTrue(after_.borrowTokenApproved, "USDC should be approved");
        assertTrue(after_.vaultSharesApproved, "vault shares should be approved");
        assertTrue(after_.hasWithdrawalManagerRole, "helper should have WITHDRAWAL_MANAGER");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Scenario 1 — fresh deploy at 50% LTV
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev 100 WETH, $2,000/WETH, 50% LTV → ~100k USDC borrowed, deposited to vault.
    function testScenario1_freshDeploy() public {
        uint64 targetLtv = 500_000_000_000_000_000; // 50%

        _scenarioSetup();
        _deployAt50Pct();

        // Mock getCurrentLtvInWad to return exactly 50% for assertion
        // (mocked getAccountValues is already set in _scenarioSetup with 50% ratio)
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(targetLtv), 1e16, "LTV should be ~50%");
        assertApproxEqAbs(helper.getCollateralAmount(), 100 ether, 1e9, "collateral should be ~100 WETH");
        assertApproxEqAbs(helper.getDebtAmount(), 100_000e6, 1000, "debt should be ~100k USDC");
        assertGt(IERC20(address(targetVault)).balanceOf(positionOwner), 0, "positionOwner should hold vault shares");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. Scenario 2 — 20% price drop → rebalance to 50% LTV
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev t0: 100 WETH at $2,000, 50% LTV (~100k USDC).
    ///      t1: Price drops 20% to $1,600 → LTV rises to ~62.5%.
    ///          Request vault redemption for ~20k USDC.
    ///      t2: Epoch processed → claim → retract repays ~20k USDC → LTV ~50%.
    function testScenario2_priceDrop20pct_rebalance() public {
        // ── t0: initial position ─────────────────────────────────────────────
        _scenarioSetup();
        _deployAt50Pct();

        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), 500_000_000_000_000_000, 1e16, "t0: LTV ~50%");
        uint256 collateral0 = helper.getCollateralAmount();
        uint256 debt0 = helper.getDebtAmount();

        // ── t1: price drops 20% ─────────────────────────────────────────────
        // supplyValue = 100 WETH × $1,600 = $160k; borrowValue = $100k → LTV = 62.5%
        _mockPrices(1_600 * 1e18, 160_000e18, 100_000e18);

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        assertApproxEqAbs(uint256(ltvT1), 625_000_000_000_000_000, 1e16, "t1: LTV ~62.5%");
        assertGt(uint256(ltvT1), uint256(HEALTHY_LTV), "t1: LTV should exceed HEALTHY_LTV");

        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50%
        uint256 repayAmount = helper.calculateTargetRepayAmount(0, repayTargetLtv);
        assertGt(repayAmount, 0, "t1: should need to repay some USDC");
        // targetDebt = 100 WETH × $1,600 × 50% = 80k USDC → repay ≈ 20k USDC
        assertApproxEqAbs(repayAmount, 20_000e6, 1_000, "t1: repayAmount ~20k USDC");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        // ── t2: process epoch, claim, retract ────────────────────────────────
        _processCurrentEpoch();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;
        vm.prank(positionOwner);
        targetVault.claimWithdrawal(epochIds);

        assertGe(IERC20(USDC).balanceOf(positionOwner), repayAmount, "t2: enough USDC to repay");

        vm.prank(operator);
        helper.retract(repayAmount, 0, repayTargetLtv);

        // Update account values mock to reflect reduced debt after repay
        _mockPrices(1_600 * 1e18, 160_000e18, 80_000e18); // debt now ~80k → LTV = 50%
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 1e16, "t2: LTV ~50%");
        assertApproxEqAbs(helper.getCollateralAmount(), collateral0, 1e9, "t2: collateral unchanged");
        assertLt(helper.getDebtAmount(), debt0, "t2: debt decreased");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. Scenario 3 — price increase → deploy more capacity
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev t0: 100 WETH at $2,000, 50% LTV.
    ///      t1: Price rises 20% to $2,400 → LTV falls to ~41.7%.
    ///          Borrow delta to reach 60% (HEALTHY_LTV) and deposit to vault.
    function testScenario3_priceIncrease20pct_deployMoreCapacity() public {
        _scenarioSetup();
        _deployAt50Pct();
        uint256 debtT0 = helper.getDebtAmount();

        // ── t1: price rises 20% ─────────────────────────────────────────────
        // supplyValue = 100 WETH × $2,400 = $240k; borrowValue = $100k → LTV ≈ 41.7%
        _mockPrices(2_400 * 1e18, 240_000e18, 100_000e18);

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        assertApproxEqAbs(uint256(ltvT1), 416_666_666_666_666_666, 1e16, "t1: LTV ~41.7%");
        assertLt(uint256(ltvT1), uint256(HEALTHY_LTV), "t1: LTV below HEALTHY_LTV");

        // Additional borrow to reach HEALTHY_LTV (60%):
        // targetDebt = 100 WETH × $2,400 × 60% = 144k USDC → delta ≈ 44k USDC
        uint256 additionalBorrow = helper.calculateTargetRepayAmount(0, HEALTHY_LTV);
        // calculateTargetRepayAmount returns a negative sign here conceptually — borrow the
        // delta directly instead.
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        uint256 col = helper.getCollateralAmount();
        uint256 existingDebt = helper.getDebtAmount();
        uint256 targetDebt = col * price / RAY * HEALTHY_LTV / WAD;
        additionalBorrow = targetDebt > existingDebt ? targetDebt - existingDebt : 0;
        assertApproxEqAbs(additionalBorrow, 44_000e6, 1_000, "t1: additional borrow ~44k USDC");

        uint256 sharesBefore = IERC20(address(targetVault)).balanceOf(positionOwner);

        vm.prank(operator);
        helper.borrow(additionalBorrow);
        vm.prank(operator);
        helper.depositOnTarget(additionalBorrow);

        assertGt(IERC20(address(targetVault)).balanceOf(positionOwner), sharesBefore, "vault shares should increase");
        assertGt(helper.getDebtAmount(), debtT0, "debt should have increased");

        // Update mock to reflect new debt for LTV check
        _mockPrices(2_400 * 1e18, 240_000e18, 144_000e18); // new debt = 144k → LTV = 60%
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(HEALTHY_LTV), 1e16, "t1: LTV ~60% after deploy");

        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. Scenario 4 — WWL: 10% drop, withdraw collateral with loan repay
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev t0: 100 WETH at $2,000, 50% LTV.
    ///      t1: Price drops 10% to $1,800 → LTV ≈ 55.6%.
    ///          Need to withdraw ~27.78 WETH while repaying ~35k USDC.
    ///      t2: Claim + retract → positionOwner receives WETH, LTV back to 50%.
    function testScenario4_wwlPressure_withdrawCollateralWithRepay() public {
        _scenarioSetup();
        _deployAt50Pct();

        // ── t1: price drops 10% ─────────────────────────────────────────────
        // supplyValue = 100 × $1,800 = $180k; borrowValue = $100k → LTV ≈ 55.6%
        _mockPrices(1_800 * 1e18, 180_000e18, 100_000e18);

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        assertApproxEqAbs(uint256(ltvT1), 555_555_555_555_555_555, 1e16, "t1: LTV ~55.6%");

        // ~27.78 WETH @ $1,800 = $50,000 withdrawal
        uint256 requiredWeth = uint256(50_000) * 1e18 / 1800;
        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50%
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredWeth, repayTargetLtv);
        // repay = 100k − (100 − 27.78) × $1,800 × 50% = 100k − 65k = 35k USDC
        assertApproxEqAbs(repayAmount, 35_000e6, 1_000, "t1: repayAmount ~35k USDC");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);

        // ── t2: claim and retract ────────────────────────────────────────────
        _processCurrentEpoch();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;
        vm.prank(positionOwner);
        targetVault.claimWithdrawal(epochIds);

        uint64 maxPermissibleLtv = 650_000_000_000_000_000; // 65%
        vm.prank(operator);
        helper.retract(repayAmount, requiredWeth, maxPermissibleLtv);

        uint256 wethReceived = IERC20(WETH).balanceOf(positionOwner) - wethBefore;
        assertApproxEqAbs(wethReceived, requiredWeth, 1e15, "t2: positionOwner receives ~27.78 WETH");

        // Update mock: after repay 35k + withdraw ~27.78 WETH:
        // collateral ≈ 72.22 WETH × $1,800 = $130k; debt ≈ 65k → LTV = 50%
        _mockPrices(1_800 * 1e18, 130_000e18, 65_000e18);
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 1e16, "t2: LTV ~50% after WWL");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 13. retract — unit tests
    // ─────────────────────────────────────────────────────────────────────────

    function testRetract_withdrawsWithoutTouchingDebt() public {
        _scenarioSetup();
        _deployAt50Pct();

        // At 50% LTV: 100 WETH collateral, ~100k USDC debt @ $2,000.
        // Withdraw 10 WETH → 90 WETH remaining, LTV rises to ~55.6% < 60%.
        uint256 withdrawAmount = 10 ether;
        uint64 maxPermissibleLtv = 600_000_000_000_000_000; // 60%

        uint256 collateralBefore = helper.getCollateralAmount();
        uint256 debtBefore = helper.getDebtAmount();
        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);

        vm.prank(operator);
        helper.retract(0, withdrawAmount, maxPermissibleLtv);

        assertApproxEqAbs(helper.getCollateralAmount(), collateralBefore - withdrawAmount, 1e15, "collateral reduced");
        assertApproxEqAbs(helper.getDebtAmount(), debtBefore, 100, "debt unchanged");
        assertApproxEqAbs(
            IERC20(WETH).balanceOf(positionOwner), wethBefore + withdrawAmount, 1e15, "positionOwner received WETH"
        );
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    function testRetract_revertsWhenMaxPermissibleLtvExceedsLenderMax() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint64 tooHighLtv = 990_000_000_000_000_000; // 99%

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MaxPermissibleLtvExceedsLenderMaxLtv.selector);
        helper.retract(0, 0, tooHighLtv);
    }

    function testRetract_revertsWhenWithdrawalWouldBreachLtv() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Withdraw 99 WETH → nearly nothing left vs 100k USDC debt → LTV >> 60%.
        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.WithdrawalWouldBreachMaxPermissibleLtv.selector);
        helper.retract(0, 99 ether, 600_000_000_000_000_000);
    }

    function testRetract_revertsWhenCalledByNonOperator() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        helper.retract(0, 0, 500_000_000_000_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 14. claimAndRetract
    // ─────────────────────────────────────────────────────────────────────────

    function testClaimAndRetract_repaysDebtFromClaimedShares() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Drop price 20% → need ~20k USDC to land at 50%
        _mockPrices(1_600 * 1e18, 160_000e18, 100_000e18);
        uint256 repayAmount = helper.calculateTargetRepayAmount(0, 500_000_000_000_000_000);
        assertApproxEqAbs(repayAmount, 20_000e6, 1_000, "repayAmount ~20k");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);
        _processCurrentEpoch();

        uint256 debtBefore = helper.getDebtAmount();
        uint256 collateralBefore = helper.getCollateralAmount();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;

        vm.prank(operator);
        helper.claimAndRetract(epochIds, 0, 500_000_000_000_000_000);

        assertLt(helper.getDebtAmount(), debtBefore, "debt should decrease");
        assertApproxEqAbs(helper.getCollateralAmount(), collateralBefore, 1e9, "collateral unchanged");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 15. redeemAndRetract
    // ─────────────────────────────────────────────────────────────────────────

    function testRedeemAndRetract_revertsWhenQueueActive() public {
        assertTrue(targetVault.isQueueActive(), "queue should be active");

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.QueueIsActive.selector);
        helper.redeemAndRetract(1 ether, 0, 500_000_000_000_000_000);
    }

    function testRedeemAndRetract_atomicRepayWhenQueueInactive() public {
        _scenarioSetup();
        _deployAt50Pct();

        vm.prank(vaultManager);
        targetVault.toggleQueueActive();

        uint256 redeemUsdc = 10_000e6;
        uint256 sharesToRedeem = targetVault.convertToShares(redeemUsdc);

        uint256 debtBefore = helper.getDebtAmount();
        uint256 collateralBefore = helper.getCollateralAmount();

        vm.prank(operator);
        helper.redeemAndRetract(sharesToRedeem, 0, 500_000_000_000_000_000);

        assertApproxEqAbs(helper.getDebtAmount(), debtBefore - redeemUsdc, 100, "debt reduced by redeemed amount");
        assertApproxEqAbs(helper.getCollateralAmount(), collateralBefore, 1e9, "collateral unchanged");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 16. rescueFunds
    // ─────────────────────────────────────────────────────────────────────────

    function testRescueFunds_rescuesERC20() public {
        uint256 stuckAmount = 5 ether;
        deal(WETH, address(helper), stuckAmount);

        vm.expectEmit(true, true, false, true, address(helper));
        emit IPositionHelperBase.FundsRescued(WETH, admin, stuckAmount);

        vm.prank(admin);
        helper.rescueFunds(WETH, stuckAmount);

        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper should hold no WETH after rescue");
        assertEq(IERC20(WETH).balanceOf(admin), stuckAmount, "admin should receive WETH");
    }

    function testRescueFunds_revertsWhenTokenIsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.ZeroAddress.selector);
        helper.rescueFunds(address(0), 1 ether);
    }

    function testRescueFunds_revertsWhenCalledByNonAdmin() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        helper.rescueFunds(WETH, 1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 17. canLiquidate modifier
    // ─────────────────────────────────────────────────────────────────────────

    function testCanLiquidate_adminBypassesLtvCondition() public {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6); // well below liq threshold

        // Admin bypasses LTV gate — fails at flash module (no liquidity), not access control.
        vm.prank(admin);
        vm.expectRevert();
        helper.selfLiquidate(type(uint256).max, SELF_LIQ_BUFFER);
    }

    function testCanLiquidate_operatorRevertsWhenLtvBelowTrigger() public {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6); // tiny LTV, far below trigger

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.NeitherAdminNorOperatorWithinPermissibleLtv.selector, operator)
        );
        helper.selfLiquidate(type(uint256).max, SELF_LIQ_BUFFER);
    }

    function testCanLiquidate_strangerAlwaysReverts() public {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.NeitherAdminNorOperatorWithinPermissibleLtv.selector, stranger)
        );
        helper.selfLiquidate(type(uint256).max, SELF_LIQ_BUFFER);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 18. Dolomite-specific: transferToDefaultAccount / transferFromDefaultAccount
    // ─────────────────────────────────────────────────────────────────────────

    function testTransferBetweenAccounts_revertsOnInvalidMarketId() public {
        _setOperator();

        uint256 bogusMarket = 999;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PositionHelperDolomiteBase.InvalidMarketId.selector, bogusMarket));
        helper.transferFromDefaultAccount(bogusMarket, 1e18, 2);
    }

    function testTransferBetweenAccounts_revertsWhenSenderNeitherAdminNorOperator() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(PositionHelperDolomiteBase.SenderNeitherAdminNorOperator.selector, stranger)
        );
        helper.transferFromDefaultAccount(wethMarketId, 1e18, 2);
    }

    function testTransferBetweenAccounts_operatorRevertsWhenAccountLeftInSelfLiqZone() public {
        _setOperator();

        // Force the default account (0) into the self-liq danger zone via mocked LTV — independent
        // of real balances — which is enough to trigger the modifier's post-transfer safety check.
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(
                IDolomiteMargin.getAccountValues.selector, DolomiteAccount.Info({owner: positionOwner, number: 0})
            ),
            abi.encode(100e18, 99e18) // ~99% LTV, above any realistic liquidation threshold
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PositionHelperDolomiteBase.AccountLeftInSelfLiqZone.selector, operator));
        helper.transferFromDefaultAccount(wethMarketId, 0, 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 19. setDolomiteExchangeWrapper — admin-only
    // ─────────────────────────────────────────────────────────────────────────

    function testSetDolomiteExchangeWrapper_updatesWrapper() public {
        address newWrapper = makeAddr("newWrapper");

        vm.expectEmit(true, false, false, false, address(helper));
        emit PositionHelperDolomiteNative.DolomiteExchangeWrapperUpdated(newWrapper);

        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(newWrapper);

        assertEq(helper.dolomiteExchangeWrapper(), newWrapper, "wrapper should be updated");
    }

    function testSetDolomiteExchangeWrapper_revertsWhenCalledByNonAdmin() public {
        vm.prank(operator);
        vm.expectRevert();
        helper.setDolomiteExchangeWrapper(makeAddr("wrapper"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 20. selfLiquidationMaxSlippage — default, update, guards
    // ─────────────────────────────────────────────────────────────────────────

    function testSelfLiquidationSlippage_defaultAndUpdate() public {
        uint64 defaultCap = 100_000_000_000_000_000; // 10%
        assertEq(helper.maxSelfLiquidationSlippageInWad(), defaultCap, "default should be 10%");

        // Above cap: reverts before NoDebt check.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPositionHelperBase.MaxSlippageTooHigh.selector, uint64(110_000_000_000_000_000), defaultCap
            )
        );
        helper.selfLiquidate(0, 110_000_000_000_000_000);

        // At cap: passes slippage; hits NoDebt.
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.NoDebt.selector);
        helper.selfLiquidate(0, defaultCap);

        // Update cap.
        uint64 newCap = 50_000_000_000_000_000; // 5%
        vm.prank(admin);
        helper.setMaxSelfLiquidationSlippageInWad(newCap);
        assertEq(helper.maxSelfLiquidationSlippageInWad(), newCap, "cap should be updated");

        // Former cap now rejected.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.MaxSlippageTooHigh.selector, uint64(defaultCap), newCap)
        );
        helper.selfLiquidate(0, defaultCap);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 21. selfLiquidateDolomiteNative — guard tests
    // ─────────────────────────────────────────────────────────────────────────

    // Note on full execution: selfLiquidateDolomiteNative issues a single Dolomite-native
    // `Sell` action inside operate(), calling out to the configured exchange wrapper.
    // Unlike the old Liquidate+Sell design, Dolomite itself imposes no undercollateralization
    // precondition on a plain Sell — only this contract's own `canLiquidate` buffer check
    // gates the call. A full end-to-end execution test requires a real (or mocked) exchange
    // wrapper contract implementing Dolomite's IExchangeWrapper interface; the tests below
    // cover every reachable guard path in Solidity, plus confirm that Dolomite's own operate()
    // is reached once all guards are passed.

    function testSelfLiquidateDolomiteNative_revertsWhenWrapperNotSet() public {
        // No dolomiteExchangeWrapper configured (address(0) from init).
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.InvalidSwapModule.selector);
        helper.selfLiquidateDolomiteNative(1e6, new bytes(0));
    }

    function testSelfLiquidateDolomiteNative_revertsWhenDebtAmountIsZero() public {
        address wrapper = makeAddr("wrapper");
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(wrapper);

        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.NoDebt.selector);
        helper.selfLiquidateDolomiteNative(0, new bytes(0));
    }

    function testSelfLiquidateDolomiteNative_revertsWhenOperatorBelowLiqTrigger() public {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6); // well below liq threshold

        address wrapper = makeAddr("wrapper");
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(wrapper);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.NeitherAdminNorOperatorWithinPermissibleLtv.selector, operator)
        );
        helper.selfLiquidateDolomiteNative(1e6, new bytes(0));
    }

    function testSelfLiquidateDolomiteNative_adminBypassesLtvGateAndReachesDolomiteOperate() public {
        // Admin bypasses the canLiquidate LTV gate.  With no debt, the NoDebt guard
        // fires before operate() is ever called.  With debt present, admin passes every
        // Solidity guard and reaches Dolomite's operate(), which reverts because `wrapper`
        // has no code (not a real IExchangeWrapper).
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6); // healthy position, well below liq threshold

        address wrapper = makeAddr("wrapper");
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(wrapper);

        vm.prank(admin);
        vm.expectRevert();
        helper.selfLiquidateDolomiteNative(100e6, new bytes(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 22. selfLiquidateDolomiteNativeToLtv — guard tests
    // ─────────────────────────────────────────────────────────────────────────

    function testSelfLiquidateDolomiteNativeToLtv_revertsWhenWrapperNotSet() public {
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.InvalidSwapModule.selector);
        helper.selfLiquidateDolomiteNativeToLtv(500_000_000_000_000_000, new bytes(0));
    }

    function testSelfLiquidateDolomiteNativeToLtv_revertsWhenNoDebt() public {
        address wrapper = makeAddr("wrapper");
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(wrapper);

        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.NoDebt.selector);
        helper.selfLiquidateDolomiteNativeToLtv(500_000_000_000_000_000, new bytes(0));
    }

    function testSelfLiquidateDolomiteNativeToLtv_revertsWhenTargetLtvTooHigh() public {
        // Mocked prices: WETH=$2000, USDC=$1. Position at 50% LTV.
        _scenarioSetup();
        _deployAt50Pct();

        address wrapper = makeAddr("wrapper");
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(wrapper);

        // targetLtv (70%) > current LTV (50%) → TargetLtvTooHigh (nothing to sell).
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.TargetLtvTooHigh.selector);
        helper.selfLiquidateDolomiteNativeToLtv(700_000_000_000_000_000, new bytes(0));
    }

    function testSelfLiquidateDolomiteNativeToLtv_revertsWhenOperatorBelowLiqTrigger() public {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6);

        address wrapper = makeAddr("wrapper");
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(wrapper);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.NeitherAdminNorOperatorWithinPermissibleLtv.selector, operator)
        );
        helper.selfLiquidateDolomiteNativeToLtv(300_000_000_000_000_000, new bytes(0));
    }

    /// @dev End-to-end success path on the fork: a real `MockDolomiteExchangeWrapper` executes
    ///      DolomiteMargin's Sell action, and the resulting position LTV is verified to land at
    ///      (near) `targetLtvInWad` — not just that debt went down. This exercises
    ///      `PMHLib.sellAmountForTargetLtv`, which sizes the sell so collateral and debt shrink
    ///      together, unlike a debt-delta-only calculation that ignores the shrinking collateral
    ///      base and would under-sell relative to the target.
    function testSelfLiquidateDolomiteNativeToLtv_succeedsAndLandsAtTargetLtv() public {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6); // real fork price/LTV, well below liq threshold

        MockDolomiteExchangeWrapper wrapper = new MockDolomiteExchangeWrapper();
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(address(wrapper));

        uint256 currentDebt = helper.getDebtAmount();
        uint256 collateral = helper.getCollateralAmount();
        uint256 price = helper.collateralPriceInBorrowTokensInRay();

        uint256 collateralValueInBorrowTokens = collateral.mulDiv(price, RAY);
        uint64 currentLtvWad = uint64(currentDebt.mulDiv(WAD, collateralValueInBorrowTokens));
        uint64 targetLtvInWad = currentLtvWad / 2; // reachable target, strictly below current LTV

        uint256 collateralAmountToSell = PMHLib.sellAmountForTargetLtv(price, targetLtvInWad, collateral, currentDebt);
        assertTrue(collateralAmountToSell != 0 && collateralAmountToSell < collateral, "sanity: sell size in range");
        uint256 expectedProceeds = collateralAmountToSell.mulDiv(price, RAY);

        wrapper.setOutputAmount(expectedProceeds);
        deal(USDC, address(wrapper), expectedProceeds);

        vm.prank(admin);
        helper.selfLiquidateDolomiteNativeToLtv(targetLtvInWad, new bytes(0));

        uint256 newDebt = currentDebt - expectedProceeds;
        uint256 newCollateral = collateral - collateralAmountToSell;
        assertEq(helper.getDebtAmount(), newDebt, "debt should be reduced by exact proceeds");
        assertEq(helper.getCollateralAmount(), newCollateral, "collateral should be reduced by exact sell amount");

        uint256 resultingLtvWad = newDebt.mulDiv(WAD, newCollateral.mulDiv(price, RAY));
        assertApproxEqRel(resultingLtvWad, uint256(targetLtvInWad), 1e12, "resulting LTV should land at target");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 23. onlySingleCollateralPosition guard — Dolomite multi-market checks
    // ─────────────────────────────────────────────────────────────────────────

    function testOnlySingleCollateralPosition_revertsOnMultipleCollateralMarkets() public {
        DolomiteAccount.Info memory account = DolomiteAccount.Info({owner: positionOwner, number: ACCOUNT_NUMBER});

        // 2 markets hold a non-zero balance, none of them debt → 2 collateral markets.
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithBalances.selector, account),
            abi.encode(uint256(2))
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithDebt.selector, account),
            abi.encode(uint256(0))
        );

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.deploy(0, 0);
    }

    function testOnlySingleCollateralPosition_revertsOnMultipleDebtMarkets() public {
        DolomiteAccount.Info memory account = DolomiteAccount.Info({owner: positionOwner, number: ACCOUNT_NUMBER});

        // 3 markets hold a non-zero balance, 2 of them debt → 1 collateral market (WETH,
        // passes identity) + 2 debt markets (fails the single-debt-market check).
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithBalances.selector, account),
            abi.encode(uint256(3))
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithDebt.selector, account),
            abi.encode(uint256(2))
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountWei.selector, account, wethMarketId),
            abi.encode(true, 1 ether)
        );

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleDebtReservesDetected.selector);
        helper.deploy(0, 0);
    }

    function testOnlySingleCollateralPosition_passesWithNoBalances() public {
        // Fresh clone, no supply/borrow yet: both counts are 0 — the guard must not fire,
        // so `deploy` reaches its own body and reverts there instead (0 collateral, 0 target LTV
        // is a no-op deploy that returns cleanly — assert on the resulting state, not a revert).
        vm.prank(operator);
        helper.deploy(0, 0);

        assertEq(helper.getCollateralAmount(), 0, "no collateral expected");
        assertEq(helper.getDebtAmount(), 0, "no debt expected");
    }

    /// @dev `selfLiquidateDolomiteNative` must apply the same single-collateral/single-debt guard
    ///      as `selfLiquidate` — admin bypasses `_requireCanLiquidate` so this isolates the guard.
    function testSelfLiquidateDolomiteNative_revertsOnMultipleCollateralMarkets() public {
        DolomiteAccount.Info memory account = DolomiteAccount.Info({owner: positionOwner, number: ACCOUNT_NUMBER});

        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithBalances.selector, account),
            abi.encode(uint256(2))
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithDebt.selector, account),
            abi.encode(uint256(0))
        );

        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.selfLiquidateDolomiteNative(1e6, new bytes(0));
    }

    /// @dev Same guard, exercised via `selfLiquidateDolomiteNativeToLtv`.
    function testSelfLiquidateDolomiteNativeToLtv_revertsOnMultipleCollateralMarkets() public {
        DolomiteAccount.Info memory account = DolomiteAccount.Info({owner: positionOwner, number: ACCOUNT_NUMBER});

        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithBalances.selector, account),
            abi.encode(uint256(2))
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithDebt.selector, account),
            abi.encode(uint256(0))
        );

        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.selfLiquidateDolomiteNativeToLtv(500_000_000_000_000_000, new bytes(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 24. canTransfer / _isSafe — multi-market guard
    // ─────────────────────────────────────────────────────────────────────────

    function testCanTransfer_operatorRevertsWhenDefaultAccountHasExtraMarkets() public {
        _setOperator();

        DolomiteAccount.Info memory defaultAccount =
            DolomiteAccount.Info({owner: positionOwner, number: ACCOUNT_NUMBER});

        // Default account (0) holds 2 markets with a positive balance — an extra market beyond
        // COLLATERAL_MARKET_ID means its account-wide LTV can no longer be bounded by a threshold
        // derived only from COLLATERAL_MARKET_ID/BORROW_MARKET_ID's margin premiums, so `_isSafe`
        // must treat it as unsafe — even though the other account (2) is genuinely empty and safe,
        // and even though no LTV mock is needed to make this account "look" fine.
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithBalances.selector, defaultAccount),
            abi.encode(uint256(2))
        );
        vm.mockCall(
            DOLOMITE_MARGIN,
            abi.encodeWithSelector(IDolomiteMargin.getAccountNumberOfMarketsWithDebt.selector, defaultAccount),
            abi.encode(uint256(0))
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PositionHelperDolomiteBase.AccountLeftInSelfLiqZone.selector, operator));
        helper.transferFromDefaultAccount(wethMarketId, 0, 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 25. _selfLiquidateDolomiteNative — max-slippage enforcement
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Uses MockDolomiteExchangeWrapper, a real IExchangeWrapper-ABI-compatible contract deployed
    // on the fork, so DolomiteMargin's Sell action runs genuinely end-to-end: DolomiteMargin
    // transfers the collateral leg to the wrapper, calls `exchange`, then pulls back whatever
    // amount of borrow token the wrapper approves. The wrapper's payout is fully test-controlled
    // via `setOutputAmount`, decoupling `debtRepaid` from `expectedProceeds` so the slippage check
    // itself can be probed (zero slippage, within-cap slippage, over-cap slippage).

    /// @dev Opens a real (partial) debt position and returns the wrapper plus the exact
    ///      `expectedProceeds` the contract will compute internally for `debtAmountToRepay`, so
    ///      tests can derive precise boundary payouts instead of guessing at live fork prices.
    function _setupNativeSelfLiq(uint256 debtAmountToRepay)
        internal
        returns (MockDolomiteExchangeWrapper wrapper, uint256 expectedProceeds)
    {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6); // 100 USDC debt, well below liq threshold

        wrapper = new MockDolomiteExchangeWrapper();
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(address(wrapper));

        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        uint256 collateralAmountToSell = debtAmountToRepay.mulDiv(RAY, price, Math.Rounding.Ceil);
        expectedProceeds = collateralAmountToSell.mulDiv(price, RAY);
    }

    function testSelfLiquidateDolomiteNative_succeedsAtZeroSlippage() public {
        (MockDolomiteExchangeWrapper wrapper, uint256 expectedProceeds) = _setupNativeSelfLiq(50e6);
        wrapper.setOutputAmount(expectedProceeds);
        deal(USDC, address(wrapper), expectedProceeds);

        uint256 debtBefore = helper.getDebtAmount();

        vm.prank(admin);
        helper.selfLiquidateDolomiteNative(50e6, new bytes(0));

        assertEq(helper.getDebtAmount(), debtBefore - expectedProceeds, "debt should be reduced by exact proceeds");
    }

    function testSelfLiquidateDolomiteNative_succeedsWithinMaxSlippage() public {
        (MockDolomiteExchangeWrapper wrapper, uint256 expectedProceeds) = _setupNativeSelfLiq(50e6);
        uint64 maxSlippage = helper.maxSelfLiquidationSlippageInWad();

        // Half the allowed cap — comfortably within bound, but not zero slippage.
        uint256 actualProceeds = expectedProceeds - expectedProceeds.mulDiv(maxSlippage / 2, WAD);
        wrapper.setOutputAmount(actualProceeds);
        deal(USDC, address(wrapper), actualProceeds);

        uint256 debtBefore = helper.getDebtAmount();

        vm.prank(admin);
        helper.selfLiquidateDolomiteNative(50e6, new bytes(0));

        assertEq(helper.getDebtAmount(), debtBefore - actualProceeds, "debt should be reduced by realised proceeds");
    }

    function testSelfLiquidateDolomiteNative_revertsWhenSlippageExceedsMax() public {
        (MockDolomiteExchangeWrapper wrapper, uint256 expectedProceeds) = _setupNativeSelfLiq(50e6);
        uint64 maxSlippage = helper.maxSelfLiquidationSlippageInWad();

        // Twice the allowed cap.
        uint256 actualProceeds = expectedProceeds - expectedProceeds.mulDiv(uint256(maxSlippage) * 2, WAD);
        wrapper.setOutputAmount(actualProceeds);
        deal(USDC, address(wrapper), actualProceeds);

        uint256 minProceeds = expectedProceeds.mulDiv(WAD - maxSlippage, WAD);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(PositionHelperDolomiteNative.SlippageTooHigh.selector, actualProceeds, minProceeds)
        );
        helper.selfLiquidateDolomiteNative(50e6, new bytes(0));
    }

    /// @dev Exact-boundary check: `debtRepaid == minProceeds` must succeed rather than revert,
    ///      since the contract's check is `debtRepaid < minProceeds`, not `<=`.
    function testSelfLiquidateDolomiteNative_succeedsAtExactMaxSlippageBound() public {
        (MockDolomiteExchangeWrapper wrapper, uint256 expectedProceeds) = _setupNativeSelfLiq(50e6);
        uint64 maxSlippage = helper.maxSelfLiquidationSlippageInWad();

        uint256 minProceeds = expectedProceeds.mulDiv(WAD - maxSlippage, WAD);
        wrapper.setOutputAmount(minProceeds);
        deal(USDC, address(wrapper), minProceeds);

        uint256 debtBefore = helper.getDebtAmount();

        vm.prank(admin);
        helper.selfLiquidateDolomiteNative(50e6, new bytes(0));

        assertEq(helper.getDebtAmount(), debtBefore - minProceeds, "debt should be reduced by exact minProceeds");
    }

    /// @dev Mirror of the above, one wei below the boundary: `debtRepaid == minProceeds - 1` must
    ///      revert `SlippageTooHigh`, confirming the cap is enforced exactly rather than loosely.
    function testSelfLiquidateDolomiteNative_revertsOneWeiBelowMaxSlippageBound() public {
        (MockDolomiteExchangeWrapper wrapper, uint256 expectedProceeds) = _setupNativeSelfLiq(50e6);
        uint64 maxSlippage = helper.maxSelfLiquidationSlippageInWad();

        uint256 minProceeds = expectedProceeds.mulDiv(WAD - maxSlippage, WAD);
        uint256 actualProceeds = minProceeds - 1;
        wrapper.setOutputAmount(actualProceeds);
        deal(USDC, address(wrapper), actualProceeds);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(PositionHelperDolomiteNative.SlippageTooHigh.selector, actualProceeds, minProceeds)
        );
        helper.selfLiquidateDolomiteNative(50e6, new bytes(0));
    }

    /// @dev A *favourable* execution (wrapper pays out more than `expectedProceeds` — e.g. the
    ///      swap clears at a better price than the oracle-implied rate) must succeed rather than
    ///      revert: `debtRepaid` only needs to clear `minProceeds`, it has no upper bound.
    function testSelfLiquidateDolomiteNative_succeedsOnFavourableExecution() public {
        (MockDolomiteExchangeWrapper wrapper, uint256 expectedProceeds) = _setupNativeSelfLiq(50e6);

        uint256 actualProceeds = expectedProceeds + 1e6; // better than oracle-implied rate
        wrapper.setOutputAmount(actualProceeds);
        deal(USDC, address(wrapper), actualProceeds);

        uint256 debtBefore = helper.getDebtAmount();

        vm.prank(admin);
        helper.selfLiquidateDolomiteNative(50e6, new bytes(0));

        assertEq(helper.getDebtAmount(), debtBefore - actualProceeds, "debt should be reduced by realised proceeds");
    }

    /// @dev `debtAmount` at or above the position's outstanding debt (e.g. padded to guarantee a
    ///      full close despite interest accrual between quote and execution) must close the
    ///      position exactly rather than sell excess collateral into a surplus supply balance the
    ///      slippage check can't see — before the `currentDebt` cap, `debtRepaid` saturated at
    ///      `debtBefore` while `minProceeds` scaled with the full (padded) sell size, so even a
    ///      fairly priced swap would spuriously revert `SlippageTooHigh`.
    function testSelfLiquidateDolomiteNative_cappedDebtAmountAboveCurrentDebtClosesExactlyAtZeroSlippage() public {
        _setOperator();
        _supplyAndBorrow(5 ether, 100e6); // 100 USDC debt, well below liq threshold

        MockDolomiteExchangeWrapper wrapper = new MockDolomiteExchangeWrapper();
        vm.prank(admin);
        helper.setDolomiteExchangeWrapper(address(wrapper));

        uint256 currentDebt = helper.getDebtAmount();
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        // The sell size must be computed off the capped (currentDebt) amount, not the padded
        // request, else expectedProceeds/minProceeds would scale with the padded amount instead.
        uint256 collateralAmountToSell = currentDebt.mulDiv(RAY, price, Math.Rounding.Ceil);
        uint256 expectedProceeds = collateralAmountToSell.mulDiv(price, RAY);

        wrapper.setOutputAmount(expectedProceeds);
        deal(USDC, address(wrapper), expectedProceeds);

        vm.prank(admin);
        helper.selfLiquidateDolomiteNative(currentDebt * 2, new bytes(0)); // padded past current debt

        assertEq(helper.getDebtAmount(), 0, "position should be fully closed");
    }
}
