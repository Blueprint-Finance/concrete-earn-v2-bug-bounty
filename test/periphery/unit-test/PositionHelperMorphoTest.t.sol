// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

// ── Clone library ─────────────────────────────────────────────────────────────
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

// ── OpenZeppelin ──────────────────────────────────────────────────────────────
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

// ── Morpho Blue ───────────────────────────────────────────────────────────────
import {IMorpho, MarketParams, Id, Market, Position} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-org/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";

// ── Protocol ──────────────────────────────────────────────────────────────────
import {ConcreteFactory} from "../../../src/factory/ConcreteFactory.sol";
import {ConcreteAsyncVaultImpl} from "../../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {AllocateModule} from "../../../src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

// ── Test mocks ────────────────────────────────────────────────────────────────
import {MockFlashModule} from "../mock/MockFlashModule.sol";
import {MockSwapper} from "../mock/MockSwapper.sol";

// ── Subject under test ────────────────────────────────────────────────────────
import {PositionHelperMorpho} from "../../../src/periphery/positionhelper/PositionHelperMorpho.sol";
import {IPositionHelperBase, PositionApprovals} from "../../../src/periphery/interface/IPositionHelperBase.sol";
import {WAD, RAY} from "../../../src/periphery/lib/Constants.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

/// @dev Minimal IOracle mock; price is settable for scenario testing.
///      Morpho oracle price scale: collateral_value_in_loan = collateral * price / 1e36
contract MockMorphoOracle is IOracle {
    uint256 public price_;

    constructor(uint256 initialPrice) {
        price_ = initialPrice;
    }

    function price() external view returns (uint256) {
        return price_;
    }

    function setPrice(uint256 newPrice) external {
        price_ = newPrice;
    }
}

/// @title  PositionHelperMorphoTest
/// @notice Fork-based unit tests for PositionHelperMorpho using WETH as collateral
///         and USDC as borrow token against a freshly created Morpho Blue market.
///
/// @dev Setup overview:
///   • Mainnet fork at block 23_800_000.
///   • Oracle: MockMorphoOracle (1 WETH = 2000 USDC, price = 2000e24 in Morpho scale).
///   • Market: (WETH, USDC, mockOracle, AdaptiveCurveIrm, 86% LLTV) - created permissionlessly.
///   • Liquidity: 1M USDC seeded by `lender` so position can borrow.
///   • Vault: freshly deployed ConcreteAsyncVaultImpl with USDC as asset.
///   • PositionHelper: implementation deployed then cloned with
///       immutable args = [positionOwner | WETH | USDC | 18 | 6].
///   • positionOwner is a plain EOA; operator holds POSITION_OPERATOR_ROLE.
///
/// @dev Key Morpho vs Aave difference: a single `morpho.setAuthorization(helper, true)`
///      call grants withdraw + borrow rights - no separate aToken or debt-token approvals.
contract PositionHelperMorphoTest is Test {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    // ── Mainnet constants ─────────────────────────────────────────────────────

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Morpho Blue singleton on Ethereum mainnet.
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    /// @dev AdaptiveCurveIrm - already enabled on mainnet Morpho.
    address internal constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @dev LLTV 86% in WAD - enabled in the Morpho protocol.
    uint256 internal constant LLTV_86 = 860_000_000_000_000_000;

    uint256 internal constant FORK_BLOCK = 23_800_000;
    uint8 internal constant WETH_DECIMALS = 18;
    uint8 internal constant USDC_DECIMALS = 6;

    // ── Oracle price constants ─────────────────────────────────────────────────
    // Morpho oracle scale: collateral_value_in_loan = collateral * price / 1e36
    // 1 WETH (1e18) = 2000 USDC (2000e6):
    //   price = 2000e6 * 1e36 / 1e18 = 2000e24

    uint256 internal constant INITIAL_ORACLE_PRICE = 2_000e24; // 1 WETH = 2000 USDC

    // ── LTV parameters (WAD-scaled) ───────────────────────────────────────────

    uint64 internal constant HEALTHY_LTV = 600_000_000_000_000_000; // 60%
    uint64 internal constant HEALTHY_LTV_DEVIATION = 50_000_000_000_000_000; // 5%
    uint64 internal constant SELF_LIQ_BUFFER = 50_000_000_000_000_000; // 5%

    // ── Contracts ─────────────────────────────────────────────────────────────

    IMorpho internal morpho;
    MockMorphoOracle internal mockOracle;
    MarketParams internal marketParams;

    PositionHelperMorpho internal implementation;
    PositionHelperMorpho internal helper;
    ConcreteAsyncVaultImpl internal targetVault;

    // ── Actors ────────────────────────────────────────────────────────────────

    address internal positionOwner;
    address internal admin;
    address internal operator;
    address internal flashModule;
    address internal swapModule;
    address internal vaultAdmin;
    address internal vaultManager;
    address internal lender; // seeds USDC liquidity into the Morpho market

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        morpho = IMorpho(MORPHO_BLUE);

        // ── Actors ────────────────────────────────────────────────────────────
        positionOwner = makeAddr("positionOwner");
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        vaultAdmin = makeAddr("vaultAdmin");
        vaultManager = makeAddr("vaultManager");
        lender = makeAddr("lender");

        // ── Modules ───────────────────────────────────────────────────────────
        // This suite doesn't execute flash/swap flows, but the helper initializer requires
        // deployed contracts (non-zero code) for both modules.
        flashModule = address(new MockFlashModule(admin, 0));
        swapModule = address(new MockSwapper(admin));

        // ── Deploy mock oracle ────────────────────────────────────────────────
        mockOracle = new MockMorphoOracle(INITIAL_ORACLE_PRICE);

        // ── Build market params ───────────────────────────────────────────────
        marketParams = MarketParams({
            loanToken: USDC, collateralToken: WETH, oracle: address(mockOracle), irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_86
        });

        // ── Create the Morpho market (permissionless) ─────────────────────────
        morpho.createMarket(marketParams);

        // ── Seed 1M USDC liquidity so borrowers have funds to draw ────────────
        uint256 seedLiquidity = 1_000_000e6;
        deal(USDC, lender, seedLiquidity);
        vm.startPrank(lender);
        IERC20(USDC).approve(MORPHO_BLUE, type(uint256).max);
        morpho.supply(marketParams, seedLiquidity, 0, lender, "");
        vm.stopPrank();

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
                abi.encode(address(allocateModule), USDC, vaultManager, "Test Async USDC Vault", "taUSDC")
            )
        );

        // ── Deploy PositionHelperMorpho implementation ────────────────────────
        implementation = new PositionHelperMorpho(MORPHO_BLUE);

        // ── Clone with immutable args ─────────────────────────────────────────
        //    [positionOwner (20)][WETH (20)][USDC (20)][18 (1)][6 (1)]
        bytes memory cloneArgs = abi.encodePacked(positionOwner, WETH, USDC, WETH_DECIMALS, USDC_DECIMALS);
        helper = PositionHelperMorpho(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        // ── Initialize clone ──────────────────────────────────────────────────
        helper.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER,
            marketParams.id()
        );

        // ── Grant helper the WITHDRAWAL_MANAGER role on the vault ─────────────
        vm.startPrank(vaultManager);
        targetVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, address(helper));
        vm.stopPrank();

        // ── Labels ────────────────────────────────────────────────────────────
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(MORPHO_BLUE, "MorphoBlue");
        vm.label(positionOwner, "positionOwner");
        vm.label(admin, "admin");
        vm.label(operator, "operator");
        vm.label(address(helper), "PositionHelper(clone)");
        vm.label(address(implementation), "PositionHelper(impl)");
        vm.label(address(targetVault), "targetVault");
        vm.label(address(mockOracle), "mockOracle");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deals WETH to positionOwner, approves helper for WETH, and calls supply.
    function _supply(uint256 amount) internal {
        deal(WETH, positionOwner, amount);
        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        vm.prank(operator);
        helper.supply(amount);
    }

    /// @dev Supplies collateral, grants Morpho authorization, then borrows.
    function _supplyAndBorrow(uint256 collateral, uint256 borrowAmount) internal {
        _supply(collateral);
        vm.prank(positionOwner);
        morpho.setAuthorization(address(helper), true);
        vm.prank(operator);
        helper.borrow(borrowAmount);
    }

    /// @dev Sets every positionOwner approval required for the full helper surface.
    ///      In Morpho, a single setAuthorization covers both collateral withdrawal and borrow.
    function _setupOwnerApprovals() internal {
        vm.startPrank(positionOwner);
        // supply: collateralToken → helper
        IERC20(WETH).approve(address(helper), type(uint256).max);
        // withdraw + borrow: single Morpho authorization
        morpho.setAuthorization(address(helper), true);
        // repay: borrowToken → helper
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);
        // requestRedemptionFromTarget: vault shares → helper
        IERC20(address(targetVault)).approve(address(helper), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Resets oracle price and approves all helper surfaces.
    function _scenarioSetup() internal {
        mockOracle.setPrice(INITIAL_ORACLE_PRICE);
        _setupOwnerApprovals();
    }

    /// @dev Deploy 100 WETH at 50% LTV. Call _scenarioSetup() first.
    ///      Returns vault shares minted to positionOwner.
    function _deployAt50Pct() internal returns (uint256 shares) {
        deal(WETH, positionOwner, 100 ether);
        vm.prank(operator);
        helper.deploy(100 ether, 500_000_000_000_000_000); // 50%
        shares = IERC20(address(targetVault)).balanceOf(positionOwner);
    }

    function _grantWithdrawalManager(address account) internal {
        vm.prank(vaultManager);
        targetVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, account);
    }

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

    /// @dev Verifies all clone immutable args are encoded and decoded correctly.
    function testDeployment_verifyImmutables() public view {
        assertEq(helper.POSITION_OWNER(), positionOwner, "POSITION_OWNER mismatch");
        assertEq(helper.COLLATERAL_TOKEN(), WETH, "COLLATERAL_TOKEN mismatch");
        assertEq(helper.BORROW_TOKEN(), USDC, "BORROW_TOKEN mismatch");
        assertEq(helper.COLLATERAL_DECIMALS(), WETH_DECIMALS, "COLLATERAL_DECIMALS mismatch");
        assertEq(helper.BORROW_DECIMALS(), USDC_DECIMALS, "BORROW_DECIMALS mismatch");
        assertEq(address(helper.MORPHO()), MORPHO_BLUE, "MORPHO mismatch");
        uint64 id = uint64(IContractId(address(helper)).ID());
        // assertEq(id, 400210100);
    }

    /// @dev Verifies storage params written by initialize().
    function testDeployment_verifyInitParams() public view {
        assertEq(helper.yieldVault(), address(targetVault), "yieldVault mismatch");
        assertEq(helper.flashModule(), flashModule, "flashModule mismatch");
        assertEq(helper.swapModule(), swapModule, "swapModule mismatch");
        assertTrue(helper.hasRole(helper.POSITION_ADMIN_ROLE(), admin), "admin should have POSITION_ADMIN_ROLE");
        assertTrue(
            helper.hasRole(helper.POSITION_OPERATOR_ROLE(), operator), "operator should have POSITION_OPERATOR_ROLE"
        );
    }

    /// @dev Verifies that initialize() sets MAX allowances from helper to Morpho / target / modules.
    function testDeployment_verifyHelperTokenAllowances() public view {
        address target = address(targetVault);

        assertEq(
            IERC20(WETH).allowance(address(helper), MORPHO_BLUE),
            type(uint256).max,
            "WETH -> Morpho allowance must be MAX (for supplyCollateral)"
        );
        assertEq(
            IERC20(WETH).allowance(address(helper), swapModule),
            type(uint256).max,
            "WETH -> swapModule allowance must be MAX (for self-liq swap)"
        );
        assertEq(
            IERC20(USDC).allowance(address(helper), MORPHO_BLUE),
            type(uint256).max,
            "USDC -> Morpho allowance must be MAX (for repay)"
        );
        assertEq(
            IERC20(USDC).allowance(address(helper), target),
            type(uint256).max,
            "USDC -> target allowance must be MAX (for depositOnTarget)"
        );
        assertEq(
            IERC20(USDC).allowance(address(helper), flashModule),
            type(uint256).max,
            "USDC -> flashModule allowance must be MAX (for flash repayment)"
        );
        assertEq(
            IERC20(target).allowance(address(helper), target),
            type(uint256).max,
            "vaultShares -> target allowance must be MAX (for requestRedeem)"
        );
    }

    /// @dev Constructor reverts when morpho is address(0).
    function testDeployment_revertsWhenMorphoIsZero() public {
        vm.expectRevert(IPositionHelperBase.ZeroAddress.selector);
        new PositionHelperMorpho(address(0));
    }

    /// @dev initialize() reverts when the market ID has never been created in Morpho Blue.
    function testDeployment_revertsWhenMarketNotFound() public {
        bytes memory cloneArgs = abi.encodePacked(positionOwner, WETH, USDC, WETH_DECIMALS, USDC_DECIMALS);
        PositionHelperMorpho clone2 =
            PositionHelperMorpho(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        // Build a market ID for a market that has never been created.
        Id nonExistentId = MarketParams({
            loanToken: USDC, collateralToken: WETH, oracle: address(0xdead), irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_86
        }).id();

        vm.expectRevert(PositionHelperMorpho.MarketNotFound.selector);
        clone2.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER,
            nonExistentId
        );
    }

    /// @dev initialize() reverts when the market tokens do not match the clone's immutable args.
    function testDeployment_revertsWhenMarketTokenMismatch() public {
        // Create a new market with swapped tokens (collateral=USDC, loan=WETH) to trigger mismatch.
        MarketParams memory swappedParams = MarketParams({
            loanToken: WETH, collateralToken: USDC, oracle: address(mockOracle), irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_86
        });
        morpho.createMarket(swappedParams);

        // Clone encodes WETH as collateral and USDC as borrow — swapped market has it backwards.
        bytes memory cloneArgs = abi.encodePacked(positionOwner, WETH, USDC, WETH_DECIMALS, USDC_DECIMALS);
        PositionHelperMorpho clone2 =
            PositionHelperMorpho(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        vm.expectRevert(PositionHelperMorpho.MarketTokenMismatch.selector);
        clone2.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER,
            swappedParams.id()
        );
    }

    /// @dev initialize() cannot be called twice.
    function testDeployment_revertsOnDoubleInitialize() public {
        vm.expectRevert();
        helper.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER,
            marketParams.id()
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. supply
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev supply() transfers WETH from positionOwner to the helper then to Morpho as collateral.
    ///      In Morpho, collateral is tracked internally under positionOwner - no aToken equivalent.
    function testSupply_sendsWethFromOwnerToMorpho() public {
        uint256 supplyAmount = 2 ether;
        deal(WETH, positionOwner, supplyAmount);

        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Supplied(supplyAmount);

        vm.prank(operator);
        helper.supply(supplyAmount);

        // positionOwner's WETH is fully spent
        assertEq(IERC20(WETH).balanceOf(positionOwner), 0, "owner WETH should be spent");

        // Morpho registers collateral under positionOwner (exact, no rounding)
        assertEq(helper.getCollateralAmount(), supplyAmount, "getCollateralAmount mismatch");

        // helper holds no WETH at rest
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    /// @dev supply() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testSupply_revertsWhenCalledByNonOperator() public {
        deal(WETH, positionOwner, 1 ether);
        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);

        vm.expectRevert(); // AccessControl: missing role
        helper.supply(1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. borrow
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev borrow() borrows USDC on behalf of positionOwner and delivers it to positionOwner.
    ///      Requires: morpho.setAuthorization(helper, true) from positionOwner.
    function testBorrow_sendsUsdcToPositionOwner() public {
        _supply(5 ether);

        vm.prank(positionOwner);
        morpho.setAuthorization(address(helper), true);

        // 5 WETH at $2,000, 86% LLTV → max ~8,600 USDC; borrow 1,000 is safe
        uint256 borrowAmount = 1_000e6;

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Borrowed(borrowAmount);

        vm.prank(operator);
        helper.borrow(borrowAmount);

        assertEq(IERC20(USDC).balanceOf(positionOwner), borrowAmount, "positionOwner USDC balance mismatch");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");

        assertApproxEqAbs(helper.getDebtAmount(), borrowAmount, 1e3, "getDebtAmount mismatch");
        assertGt(helper.getCurrentLtvInWad(), 0, "LTV should be > 0 after borrow");
    }

    /// @dev borrow() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testBorrow_revertsWhenCalledByNonOperator() public {
        _supply(5 ether);
        vm.prank(positionOwner);
        morpho.setAuthorization(address(helper), true);

        vm.expectRevert();
        helper.borrow(100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. repay
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev repay() uses the shares-path for full repay, fully clearing the Morpho position.
    ///      Full repay in Morpho uses shares to avoid dust from share-rounding.
    function testRepay_fullRepay_clearsPositionOwnerDebt() public {
        _supplyAndBorrow(5 ether, 1_000e6);

        uint256 debtBefore = helper.getDebtAmount();
        assertGt(debtBefore, 0, "no debt to repay");

        deal(USDC, positionOwner, debtBefore + 1e6); // buffer for accrued interest

        vm.prank(positionOwner);
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Repaid(debtBefore);

        vm.prank(operator);
        helper.repay(debtBefore);

        assertEq(helper.getDebtAmount(), 0, "debt should be fully cleared");
        assertEq(helper.getCurrentLtvInWad(), 0, "LTV must be 0 after full repay");
        assertLe(IERC20(USDC).balanceOf(address(helper)), 1, "helper must hold no residual USDC");
    }

    /// @dev repay() uses the assets-path for partial repay, reducing debt proportionally.
    function testRepay_partialRepay_reducesDebt() public {
        _supplyAndBorrow(5 ether, 2_000e6);

        uint256 debtBefore = helper.getDebtAmount();
        uint256 repayAmount = 500e6;

        deal(USDC, positionOwner, repayAmount);
        vm.prank(positionOwner);
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);

        vm.prank(operator);
        helper.repay(repayAmount);

        assertApproxEqAbs(helper.getDebtAmount(), debtBefore - repayAmount, 1e3, "debt should decrease by repayAmount");
        assertGt(helper.getCurrentLtvInWad(), 0, "LTV should still be > 0");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    /// @dev repay() reverts with NoDebt when positionOwner has no borrow shares (borrowShares == 0 path).
    function testRepay_withNoBorrow_isNoOp() public {
        _supply(2 ether);

        // No borrow → borrowShares == 0; repay should revert with NoDebt.
        deal(USDC, positionOwner, 100e6);
        vm.prank(positionOwner);
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);

        vm.expectRevert(IPositionHelperBase.NoDebt.selector);

        vm.prank(operator);
        helper.repay(100e6);
    }

    /// @dev repay() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testRepay_revertsWhenCalledByNonOperator() public {
        deal(USDC, positionOwner, 100e6);
        vm.prank(positionOwner);
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);

        vm.expectRevert();
        helper.repay(100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. withdraw (and withdraw-with-loan)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev withdraw() calls Morpho.withdrawCollateral on behalf of positionOwner and
    ///      returns WETH to positionOwner; helper holds nothing at rest.
    ///      Requires: morpho.setAuthorization(helper, true) from positionOwner.
    function testWithdraw_returnsCollateralToPositionOwner() public {
        uint256 supplyAmount = 5 ether;
        uint256 withdrawAmount = supplyAmount / 2;
        _supply(supplyAmount);

        vm.prank(positionOwner);
        morpho.setAuthorization(address(helper), true);

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Withdrawn(withdrawAmount);

        vm.prank(operator);
        helper.withdraw(withdrawAmount);

        assertEq(IERC20(WETH).balanceOf(positionOwner), withdrawAmount, "positionOwner WETH balance mismatch");
        assertEq(helper.getCollateralAmount(), supplyAmount - withdrawAmount, "remaining collateral mismatch");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    /// @dev withdraw() succeeds with an outstanding borrow if health factor remains above 1.
    ///      Morpho enforces the HF check on-chain via its internal accounting.
    function testWithdrawWithLoan_partialWithdrawKeepsPositionHealthy() public {
        // 10 WETH at $2,000 = $20,000 collateral; 1,000 USDC borrow ≈ 5% LTV - well within 86% LLTV.
        _supplyAndBorrow(10 ether, 1_000e6);

        uint256 collateralBefore = helper.getCollateralAmount();
        uint256 withdrawAmount = 1 ether;

        vm.prank(operator);
        helper.withdraw(withdrawAmount);

        assertEq(
            helper.getCollateralAmount(),
            collateralBefore - withdrawAmount,
            "collateral should decrease by withdrawn amount"
        );
        assertGt(helper.getCurrentLtvInWad(), 0, "LTV should still reflect outstanding debt");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no residual WETH");
    }

    /// @dev withdraw() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testWithdraw_revertsWhenCalledByNonOperator() public {
        _supply(2 ether);
        vm.prank(positionOwner);
        morpho.setAuthorization(address(helper), true);

        vm.expectRevert();
        helper.withdraw(1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. deploy (high-level position flow)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev deploy() supplies collateral, borrows to targetLtv, and deposits borrowed
    ///      USDC into the target vault; positionOwner ends up with vault shares.
    function testDeploy_supplyBorrowDepositToTargetLtv() public {
        uint256 collateralAmount = 5 ether;
        uint64 targetLtvInWad = 500_000_000_000_000_000; // 50%

        deal(WETH, positionOwner, collateralAmount);
        _setupOwnerApprovals();

        vm.prank(operator);
        helper.deploy(collateralAmount, targetLtvInWad);

        // Collateral at Morpho under positionOwner
        assertEq(helper.getCollateralAmount(), collateralAmount, "collateral not supplied to Morpho");

        // Debt exists (borrow was triggered)
        assertGt(helper.getDebtAmount(), 0, "no debt after deploy - borrow step missed");

        // LTV approximates target (±2%)
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), uint256(targetLtvInWad), 2e16, "LTV should approximate targetLtv"
        );

        // Borrowed USDC was deposited into vault - positionOwner holds shares
        assertGt(
            IERC20(address(targetVault)).balanceOf(positionOwner),
            0,
            "positionOwner should hold target vault shares after deploy"
        );

        // Helper is clean
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    /// @dev deploy() with targetLtv = 0 only supplies; borrow and deposit are skipped.
    function testDeploy_skipsWhenTargetLtvIsZero() public {
        uint256 collateralAmount = 3 ether;
        deal(WETH, positionOwner, collateralAmount);
        _setupOwnerApprovals();

        vm.prank(operator);
        helper.deploy(collateralAmount, 0);

        assertEq(helper.getCollateralAmount(), collateralAmount, "collateral should be supplied");
        assertEq(helper.getDebtAmount(), 0, "no debt expected when targetLtv = 0");
        assertEq(IERC20(address(targetVault)).balanceOf(positionOwner), 0, "no vault shares expected without borrow");
    }

    /// @dev deploy() reverts when targetLtvInWad exceeds the market's LLTV.
    function testDeploy_revertsWhenTargetLtvExceedsMaxLtv() public {
        uint64 tooHighLtv = helper.getMaxLtvInWad() + 1;

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.TargetLtvExceedsMaxLtv.selector);
        helper.deploy(1 ether, tooHighLtv);
    }

    /// @dev deploy() with collateralAmount = 0 borrows against existing collateral to reach targetLtv.
    function testDeploy_withZeroCollateral_borrowsToTargetLtv() public {
        _scenarioSetup();

        uint256 collateralAmount = 5 ether;
        deal(WETH, positionOwner, collateralAmount);

        // First deploy: supply 5 WETH and borrow to 30% LTV
        vm.prank(operator);
        helper.deploy(collateralAmount, 300_000_000_000_000_000); // 30%

        uint256 collateralAfterFirst = helper.getCollateralAmount();
        uint256 debtAfterFirst = helper.getDebtAmount();
        assertGt(debtAfterFirst, 0, "debt should exist after initial deploy");

        // Second deploy: 0 collateral, increase to 50% LTV
        vm.prank(operator);
        helper.deploy(0, 500_000_000_000_000_000); // 50%

        assertEq(helper.getCollateralAmount(), collateralAfterFirst, "collateral should be unchanged");
        assertGt(helper.getDebtAmount(), debtAfterFirst, "debt should have increased");
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(500_000_000_000_000_000),
            2e16,
            "LTV should approximate 50% after zero-collateral deploy"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. View / position data
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Fresh clone reports zero position before any activity.
    function testGetPosition_returnsZeroBeforeAnyActivity() public view {
        (uint256 col, uint256 debt) = helper.getPosition();
        assertEq(col, 0, "collateral should be 0 initially");
        assertEq(debt, 0, "debt should be 0 initially");
        assertEq(helper.getCurrentLtvInWad(), 0, "LTV should be 0 initially");
    }

    /// @dev getMaxLtvInWad() returns the configured LLTV - Morpho uses a single threshold.
    function testGetMaxLtvInWad_returnsConfiguredLltv() public view {
        uint64 maxLtv = helper.getMaxLtvInWad();
        assertEq(uint256(maxLtv), LLTV_86, "max LTV must equal configured LLTV (86%)");
    }

    /// @dev getLiquidationThresholdInWad() equals getMaxLtvInWad() in Morpho Blue.
    ///      Morpho has a single LLTV that serves as both max borrow LTV and liquidation threshold.
    function testGetLiquidationThresholdInWad_equalsMaxLtv() public view {
        assertEq(
            helper.getLiquidationThresholdInWad(),
            helper.getMaxLtvInWad(),
            "liquidation threshold must equal max LTV in Morpho Blue"
        );
    }

    /// @dev getBorrowRateInWad() returns a positive annualised rate from the AdaptiveCurveIrm.
    function testGetBorrowRateInWad_returnsPositiveRate() public {
        _supplyAndBorrow(5 ether, 1_000e6);
        uint64 rate = helper.getBorrowRateInWad();
        assertGt(rate, 0, "borrow rate should be > 0 after borrowing");
        assertLt(rate, WAD, "borrow rate should be < 100% (sanity check)");
    }

    /// @dev getSupplyRateInWad() always returns 0 - collateral in Morpho earns no yield.
    function testGetSupplyRateInWad_alwaysZero() public view {
        assertEq(helper.getSupplyRateInWad(), 0, "supply rate must always be 0 in Morpho Blue");
    }

    /// @dev collateralPriceInBorrowTokensInRay() converts Morpho oracle price to RAY.
    ///      Formula: rayPrice = oraclePrice * RAY / ORACLE_PRICE_SCALE (1e36)
    function testCollateralPrice_returnsCorrectWethUsdcPrice() public view {
        uint256 expectedPrice = INITIAL_ORACLE_PRICE * RAY / 1e36;
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        assertEq(price, expectedPrice, "collateral price in RAY mismatch");
        assertGt(price, 0, "price should be > 0");
    }

    /// @dev getAvailablePoolLiquidity() returns the USDC available for borrowing in the market.
    function testGetAvailablePoolLiquidity_returnsSeededLiquidity() public view {
        uint256 liquidity = helper.getAvailablePoolLiquidity();
        // 1M USDC seeded, no borrows yet - allow 1 USDC rounding
        assertApproxEqAbs(liquidity, 1_000_000e6, 1e6, "market should have ~1M USDC available");
    }

    /// @dev getAvailablePoolLiquidity() decreases after a borrow.
    function testGetAvailablePoolLiquidity_decreasesAfterBorrow() public {
        uint256 liquidityBefore = helper.getAvailablePoolLiquidity();
        _supplyAndBorrow(5 ether, 1_000e6);
        uint256 liquidityAfter = helper.getAvailablePoolLiquidity();
        assertLt(liquidityAfter, liquidityBefore, "liquidity should decrease after borrow");
    }

    /// @dev getFullPosition() returns collateral, debt, LTV, and price consistently.
    function testGetFullPosition_returnsConsistentValues() public {
        _supplyAndBorrow(5 ether, 1_000e6);
        (uint256 col, uint256 debt, uint64 ltv, uint256 priceInRay) = helper.getFullPosition();
        assertEq(col, helper.getCollateralAmount(), "col mismatch with getCollateralAmount");
        assertApproxEqAbs(debt, helper.getDebtAmount(), 1, "debt mismatch with getDebtAmount");
        assertEq(ltv, helper.getCurrentLtvInWad(), "ltv mismatch with getCurrentLtvInWad");
        assertEq(priceInRay, helper.collateralPriceInBorrowTokensInRay(), "price mismatch");
    }

    /// @dev getCurrentLtvInWad() returns 0 when collateral is zero.
    function testGetCurrentLtvInWad_returnsZeroWhenNoCollateral() public view {
        assertEq(helper.getCurrentLtvInWad(), 0, "LTV must be 0 with no collateral");
    }

    /// @dev getCurrentLtvInWad() rejects a zero oracle price when a live position exists.
    function testGetCurrentLtvInWad_revertsWhenOraclePriceIsZeroForLivePosition() public {
        _supplyAndBorrow(5 ether, 1_000e6);
        mockOracle.setPrice(0);

        vm.expectRevert(abi.encodeWithSelector(PositionHelperMorpho.InvalidOraclePrice.selector, 0));
        helper.getCurrentLtvInWad();
    }

    /// @dev getCurrentLtvInWad() rejects prices that round collateral value down to zero.
    function testGetCurrentLtvInWad_revertsWhenCollateralValueRoundsToZero() public {
        _supplyAndBorrow(5 ether, 1_000e6);
        mockOracle.setPrice(1);

        vm.expectRevert(abi.encodeWithSelector(PositionHelperMorpho.InvalidOraclePrice.selector, 1));
        helper.getCurrentLtvInWad();
    }

    /// @dev getCurrentLtvInWad() saturates the bounded public output instead of overflowing uint64.
    function testGetCurrentLtvInWad_saturatesWhenRatioExceedsUint64() public {
        _supplyAndBorrow(5 ether, 1_000e6);
        mockOracle.setPrice(2e17);

        assertEq(helper.getCurrentLtvInWad(), type(uint64).max, "LTV should saturate");
    }

    /// @dev collateralPriceInBorrowTokensInRay() rejects a zero raw oracle price.
    function testCollateralPrice_revertsWhenOraclePriceIsZero() public {
        mockOracle.setPrice(0);

        vm.expectRevert(abi.encodeWithSelector(PositionHelperMorpho.InvalidOraclePrice.selector, 0));
        helper.collateralPriceInBorrowTokensInRay();
    }

    /// @dev collateralPriceInBorrowTokensInRay() rejects prices that round to zero in RAY.
    function testCollateralPrice_revertsWhenRayPriceRoundsToZero() public {
        mockOracle.setPrice(1);

        vm.expectRevert(abi.encodeWithSelector(PositionHelperMorpho.InvalidOraclePrice.selector, 1));
        helper.collateralPriceInBorrowTokensInRay();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. checkApprovals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev checkApprovals() accurately reflects missing and present positionOwner approvals.
    ///      In Morpho, lenderCollateralApproved and lenderDebtDelegated both reflect
    ///      morpho.isAuthorized(positionOwner, helper).
    function testCheckApprovals_reflectsOwnerApprovals() public {
        _supply(2 ether); // so positionOwner has collateral in Morpho

        // Before any approvals - lender fields must be false
        PositionApprovals memory before = helper.checkApprovals();
        assertFalse(before.lenderCollateralApproved, "Morpho not authorized yet");
        assertFalse(before.lenderDebtDelegated, "Morpho not authorized yet");
        assertFalse(before.borrowTokenApproved, "borrow token not approved yet");
        assertFalse(before.vaultSharesApproved, "vault shares not approved yet");

        // Grant all approvals
        _setupOwnerApprovals();

        PositionApprovals memory after_ = helper.checkApprovals();
        assertTrue(after_.collateralTokenApproved, "collateral token should be approved");
        // Single setAuthorization covers both fields in Morpho
        assertTrue(after_.lenderCollateralApproved, "Morpho should be authorized (collateral)");
        assertTrue(after_.lenderDebtDelegated, "Morpho should be authorized (debt)");
        assertTrue(after_.borrowTokenApproved, "borrow token should be approved");
        assertTrue(after_.vaultSharesApproved, "vault shares should be approved");
        // WITHDRAWAL_MANAGER_ROLE was granted in setUp()
        assertTrue(after_.hasWithdrawalManagerRole, "helper should have WITHDRAWAL_MANAGER on vault");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Scenario 1 - fresh deploy
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 1:
    ///   positionOwner receives 100 WETH (at $2,000/WETH).
    ///   deploy(100 WETH, 50% LTV) supplies collateral, borrows ~100k USDC, and
    ///   deposits that USDC into the target vault so positionOwner receives shares.
    function testScenario1_freshDeploy_suppliesBorrowsDepositsToVault() public {
        uint64 targetLtv = 500_000_000_000_000_000; // 50%

        _scenarioSetup();
        deal(WETH, positionOwner, 100 ether);
        vm.prank(operator);
        helper.deploy(100 ether, targetLtv);

        // Collateral: exactly 100 WETH (Morpho stores raw token units)
        assertEq(helper.getCollateralAmount(), 100 ether, "collateral should be 100 WETH");

        // Debt: ~100k USDC (100 WETH × $2,000 × 50%)
        uint256 debt = helper.getDebtAmount();
        assertApproxEqAbs(debt, 100_000e6, 10, "debt should be ~100k USDC");

        // LTV ≈ 50%
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(targetLtv), 2e16, "LTV should be ~50%");

        // positionOwner received vault shares
        assertGt(IERC20(address(targetVault)).balanceOf(positionOwner), 0, "positionOwner should hold vault shares");

        // Helper is clean
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. Scenario 2 - 20% price drop → rebalance to 50% LTV
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 2:
    ///
    ///   t0  100 WETH deployed at $2,000 (50% LTV → ~100k USDC borrowed).
    ///
    ///   t1  Price drops 20% to $1,600.
    ///       LTV rises to ~62.5%, above the configured healthyLtv (60%).
    ///       calculateTargetRepayAmount(0, 50%) = ~20k USDC.
    ///       Operator requests redemption of matching vault shares.
    ///
    ///   t2  Vault epoch is processed; positionOwner claims USDC.
    ///       Operator calls retract(20k, 0, 50%) - repays debt, no withdrawal.
    function testScenario2_priceDrop20pct_rebalanceToTargetLtv() public {
        // t0: initial position
        _scenarioSetup();
        _deployAt50Pct();

        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), 500_000_000_000_000_000, 2e16, "t0: LTV ~50%");
        uint256 collateral0 = helper.getCollateralAmount();
        uint256 debt0 = helper.getDebtAmount();

        // t1: price drops 20% - $2,000 → $1,600
        // newPrice = 1600 * 1e6 * 1e36 / 1e18 = 1600e24
        mockOracle.setPrice(1_600e24);

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        // Expected: 50% × (2000/1600) = 62.5%
        assertApproxEqAbs(uint256(ltvT1), 625_000_000_000_000_000, 2e16, "t1: LTV should be ~62.5%");
        assertGt(uint256(ltvT1), uint256(HEALTHY_LTV), "t1: LTV should exceed healthyLtv (60%)");

        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50%
        uint256 repayAmount = helper.calculateTargetRepayAmount(0, repayTargetLtv);
        assertGt(repayAmount, 0, "t1: should need to repay some USDC");
        // targetDebt = 100 WETH × $1,600 × 50% = 80k → repay 20k USDC
        assertApproxEqAbs(repayAmount, 20_000e6, 10, "t1: repayAmount should be ~20k USDC");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        uint256 epochId = 1;
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        // t2: process epoch, claim, repay
        _processCurrentEpoch();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = epochId;
        vm.prank(positionOwner);
        targetVault.claimWithdrawal(epochIds);

        assertGe(IERC20(USDC).balanceOf(positionOwner), repayAmount, "t2: positionOwner should have USDC to repay");

        vm.prank(operator);
        helper.retract(repayAmount, 0, repayTargetLtv);

        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 2e16, "t2: LTV should be ~50% after repay"
        );
        assertEq(helper.getCollateralAmount(), collateral0, "t2: collateral should be unchanged");
        assertLt(helper.getDebtAmount(), debt0, "t2: debt should have decreased");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. Scenario 3 - 20% price increase → deploy more capacity
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 3:
    ///
    ///   t0  Same as Scenario 2 t0 (100 WETH, $2,000, 50% LTV, ~100k USDC debt).
    ///
    ///   t1  Price rises 20% to $2,400.
    ///       LTV falls to ~41.7% (underleveraged relative to 60% healthyLtv).
    ///       Operator borrows the delta required to reach healthyLtv and deposits to vault.
    function testScenario3_priceIncrease20pct_deployMoreCapacity() public {
        _scenarioSetup();
        _deployAt50Pct();
        uint256 debtT0 = helper.getDebtAmount();

        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), 500_000_000_000_000_000, 2e16, "t0: LTV ~50%");

        // t1: price rises 20% - $2,000 → $2,400
        mockOracle.setPrice(2_400e24);

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        // Expected: 50% × (2000/2400) ≈ 41.7%
        assertApproxEqAbs(uint256(ltvT1), 416_666_666_666_666_666, 2e16, "t1: LTV should be ~41.7%");
        assertLt(uint256(ltvT1), uint256(HEALTHY_LTV), "t1: LTV should be below healthyLtv (60%)");

        // Calculate additional borrow to reach HEALTHY_LTV
        // targetDebt = 100 WETH × $2,400 × 60% = 144k USDC; delta = 144k − 100k = 44k
        uint256 collateral = helper.getCollateralAmount();
        uint256 existingDebt = helper.getDebtAmount();
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        uint256 targetDebt = collateral * price / 1e27 * HEALTHY_LTV / WAD;
        uint256 additionalBorrow = targetDebt > existingDebt ? targetDebt - existingDebt : 0;
        assertApproxEqAbs(additionalBorrow, 44_000e6, 10, "t1: additional borrow should be ~44k USDC");

        uint256 sharesBeforeDeploy = IERC20(address(targetVault)).balanceOf(positionOwner);

        vm.prank(operator);
        helper.borrow(additionalBorrow); // USDC sent to positionOwner

        vm.prank(operator);
        helper.depositOnTarget(additionalBorrow); // pulls USDC from positionOwner → vault

        assertGt(
            IERC20(address(targetVault)).balanceOf(positionOwner),
            sharesBeforeDeploy,
            "t1: vault shares should have increased"
        );

        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), uint256(HEALTHY_LTV), 2e16, "t1: LTV should be ~60% (healthyLtv)"
        );

        assertApproxEqAbs(
            helper.getDebtAmount(), debtT0 + additionalBorrow, 1e3, "t1: debt should have increased by additionalBorrow"
        );

        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. Scenario 4 - WWL pressure: 10% drop, withdraw collateral with loan
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 4:
    ///
    ///   t0  Same as Scenario 2 t0 (100 WETH, $2,000, 50% LTV, ~100k USDC debt).
    ///
    ///   t1  Price drops 10% to $1,800. LTV rises to ~55.6%.
    ///       positionOwner wants collateral worth ~$50k (~27.78 WETH at $1,800).
    ///       calculateTargetRepayAmount(~27.78 WETH, 50%) = ~35k USDC.
    ///
    ///   t2  Epoch processed; claim ~35k USDC; retract(35k, 27.78 WETH, 65%).
    ///       positionOwner receives WETH; LTV lands at ~50%.
    function testScenario4_wwlPressure_withdrawCollateralWithLoanRepay() public {
        _scenarioSetup();
        _deployAt50Pct();

        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), 500_000_000_000_000_000, 2e16, "t0: LTV ~50%");

        // t1: price drops 10% - $2,000 → $1,800
        mockOracle.setPrice(1_800e24);

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        // Expected: 50% × (2000/1800) ≈ 55.6%
        assertApproxEqAbs(uint256(ltvT1), 555_555_555_555_555_555, 2e16, "t1: LTV should be ~55.6%");

        // positionOwner wants collateral worth ~$50k at $1,800 → ~27.78 WETH
        uint256 requiredCollateralWeth = uint256(50_000) * 1e18 / 1800;

        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50%
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredCollateralWeth, repayTargetLtv);
        // repay = debt − (collateral − R) × price × targetLtv
        //       = 100k − (100 − 27.78) × $1,800 × 50% = 100k − 65k = 35k USDC
        assertApproxEqAbs(repayAmount, 35_000e6, 10, "t1: repayAmount should be ~35k USDC");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        uint256 epochId = 1;
        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(positionOwner);

        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        // t2: process epoch, claim USDC, retract with withdrawal
        _processCurrentEpoch();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = epochId;
        vm.prank(positionOwner);
        targetVault.claimWithdrawal(epochIds);

        assertGe(IERC20(USDC).balanceOf(positionOwner), repayAmount, "t2: positionOwner should have USDC");

        uint64 maxPermissibleLtv = 650_000_000_000_000_000; // 65%
        vm.prank(operator);
        helper.retract(repayAmount, requiredCollateralWeth, maxPermissibleLtv);

        uint256 wethReceived = IERC20(WETH).balanceOf(positionOwner) - wethBalanceBefore;
        assertApproxEqAbs(wethReceived, requiredCollateralWeth, 1e15, "t2: positionOwner should receive ~27.78 WETH");

        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 2e16, "t2: LTV should be ~50% after WWL"
        );

        assertApproxEqAbs(
            helper.getCollateralAmount(),
            100 ether - requiredCollateralWeth,
            1e15,
            "t2: remaining collateral should be ~72.22 WETH"
        );

        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 13. retract - unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev retract(0, withdrawalAmount, maxLtv) withdraws collateral to positionOwner
    ///      without touching debt when repayAmount is zero.
    function testRetract_whenRepayAmountIsZero() public {
        _scenarioSetup();
        _deployAt50Pct();

        // At 50% LTV: 100 WETH collateral, ~100k USDC debt @ $2,000.
        // Withdraw 10 WETH → 90 WETH, LTV ≈ 100k / 180k ≈ 55.6% < 60%
        uint256 withdrawAmount = 10 ether;
        uint64 maxPermissibleLtv = 600_000_000_000_000_000; // 60%

        uint256 collateralBefore = helper.getCollateralAmount();
        uint256 debtBefore = helper.getDebtAmount();
        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);

        vm.prank(operator);
        helper.retract(0, withdrawAmount, maxPermissibleLtv);

        assertEq(helper.getCollateralAmount(), collateralBefore - withdrawAmount, "collateral should decrease");
        assertApproxEqAbs(helper.getDebtAmount(), debtBefore, 1e3, "debt should be unchanged");
        assertEq(
            IERC20(WETH).balanceOf(positionOwner), wethBefore + withdrawAmount, "positionOwner should receive WETH"
        );
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    /// @dev retract() reverts when maxPermissibleLtv exceeds the market LLTV.
    function testRetract_revertsWhenMaxPermissibleLtvExceedsLenderMax() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint64 tooHighLtv = 950_000_000_000_000_000; // 95% - market LLTV is 86%

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MaxPermissibleLtvExceedsLenderMaxLtv.selector);
        helper.retract(0, 0, tooHighLtv);
    }

    /// @dev retract() reverts when the requested withdrawal would push LTV above maxPermissibleLtv.
    function testRetract_revertsWhenWithdrawalWouldBreachLtv() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Withdraw 80 WETH → 20 WETH remaining vs ~100k USDC debt → LTV >> 60%
        uint256 tooMuchWithdrawal = 80 ether;
        uint64 maxPermissibleLtv = 600_000_000_000_000_000; // 60%

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.WithdrawalWouldBreachMaxPermissibleLtv.selector);
        helper.retract(0, tooMuchWithdrawal, maxPermissibleLtv);
    }

    /// @dev retract() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testRetract_revertsWhenCalledByNonOperator() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        helper.retract(0, 0, 500_000_000_000_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 14. claimAndRetract - unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev claimAndRetract() claims fulfilled vault redemptions and repays Aave debt;
    ///      collateral is untouched when withdrawalAmount is zero.
    function testClaimAndRetract_repaysDebtFromClaimedShares() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Price drops 20% → LTV ≈ 62.5%; repay ~20k USDC to land at 50%
        mockOracle.setPrice(1_600e24);

        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50%
        uint256 repayAmount = helper.calculateTargetRepayAmount(0, repayTargetLtv);
        assertApproxEqAbs(repayAmount, 20_000e6, 10, "repayAmount should be ~20k USDC");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        _processCurrentEpoch();

        uint256 debtBefore = helper.getDebtAmount();
        uint256 collateralBefore = helper.getCollateralAmount();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;

        vm.prank(operator);
        helper.claimAndRetract(epochIds, 0, repayTargetLtv);

        assertLt(helper.getDebtAmount(), debtBefore, "debt should have decreased");
        assertEq(helper.getCollateralAmount(), collateralBefore, "collateral should be unchanged");
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 2e16, "LTV should be ~50%");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    /// @dev claimAndRetract() with withdrawalAmount > 0 repays debt and withdraws collateral.
    function testClaimAndRetract_repaysAndWithdrawsCollateral() public {
        _scenarioSetup();
        _deployAt50Pct();

        mockOracle.setPrice(1_800e24); // price drops 10%

        uint256 requiredCollateralWeth = uint256(50_000) * 1e18 / 1800;
        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50%
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredCollateralWeth, repayTargetLtv);
        assertApproxEqAbs(repayAmount, 35_000e6, 10, "repayAmount should be ~35k USDC");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        _processCurrentEpoch();

        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;

        uint64 maxPermissibleLtv = 650_000_000_000_000_000; // 65%
        vm.prank(operator);
        helper.claimAndRetract(epochIds, requiredCollateralWeth, maxPermissibleLtv);

        assertApproxEqAbs(
            IERC20(WETH).balanceOf(positionOwner) - wethBefore,
            requiredCollateralWeth,
            1e15,
            "positionOwner should receive ~27.78 WETH"
        );
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 2e16, "LTV should be ~50%");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 15. redeemAndRetract - unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev redeemAndRetract() reverts with QueueIsActive when the target vault queue is on.
    function testRedeemAndRetract_revertsWhenQueueActive() public {
        assertTrue(targetVault.isQueueActive(), "queue should be active by default");

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.QueueIsActive.selector);
        helper.redeemAndRetract(1 ether, 0, 500_000_000_000_000_000);
    }

    /// @dev redeemAndRetract() synchronously redeems vault shares and repays Morpho debt
    ///      when the target vault queue is inactive (no collateral withdrawn).
    function testRedeemAndRetract_atomicRepayWhenQueueInactive() public {
        _scenarioSetup();
        _deployAt50Pct(); // ~100k USDC debt, 100 WETH collateral

        vm.prank(vaultManager);
        targetVault.toggleQueueActive();

        uint256 redeemUsdc = 10_000e6;
        uint256 sharesToRedeem = targetVault.convertToShares(redeemUsdc);

        uint256 debtBefore = helper.getDebtAmount();
        uint256 collateralBefore = helper.getCollateralAmount();

        vm.prank(operator);
        helper.redeemAndRetract(sharesToRedeem, 0, 500_000_000_000_000_000);

        assertApproxEqAbs(
            helper.getDebtAmount(), debtBefore - redeemUsdc, 1e3, "debt should decrease by redeemed amount"
        );
        assertEq(helper.getCollateralAmount(), collateralBefore, "collateral should be unchanged");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    /// @dev redeemAndRetract() repays debt and withdraws collateral atomically when queue is inactive.
    function testRedeemAndRetract_atomicRepayAndWithdrawWhenQueueInactive() public {
        _scenarioSetup();
        _deployAt50Pct();

        mockOracle.setPrice(1_800e24); // price drops 10%

        vm.prank(vaultManager);
        targetVault.toggleQueueActive();

        uint256 requiredCollateralWeth = uint256(50_000) * 1e18 / 1800;
        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50%
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredCollateralWeth, repayTargetLtv);
        assertApproxEqAbs(repayAmount, 35_000e6, 10, "repayAmount should be ~35k USDC");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);

        uint64 maxPermissibleLtv = 650_000_000_000_000_000; // 65%
        vm.prank(operator);
        helper.redeemAndRetract(sharesToRedeem, requiredCollateralWeth, maxPermissibleLtv);

        assertApproxEqAbs(
            IERC20(WETH).balanceOf(positionOwner) - wethBefore,
            requiredCollateralWeth,
            1e15,
            "positionOwner should receive ~27.78 WETH"
        );
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 2e16, "LTV should be ~50%");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper must hold no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 16. rescueFunds - unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev rescueFunds() transfers a stuck ERC-20 token to the calling admin.
    function testRescueFunds_rescuesERC20() public {
        uint256 stuckAmount = 5 ether;
        deal(WETH, address(helper), stuckAmount);

        vm.expectEmit(true, true, false, true, address(helper));
        emit IPositionHelperBase.FundsRescued(WETH, admin, stuckAmount);

        vm.prank(admin);
        helper.rescueFunds(WETH, stuckAmount);

        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper should hold no WETH after rescue");
        assertEq(IERC20(WETH).balanceOf(admin), stuckAmount, "admin should receive stuck WETH");
    }

    /// @dev rescueFunds() reverts when token is address(0).
    function testRescueFunds_revertsWhenTokenIsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.ZeroAddress.selector);
        helper.rescueFunds(address(0), 1 ether);
    }

    /// @dev rescueFunds() reverts when called by a non-admin address.
    function testRescueFunds_revertsWhenCalledByNonAdmin() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        helper.rescueFunds(WETH, 1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 17. updateRedemptionRequestFromTarget - unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev updateRedemptionRequestFromTarget() cancels an existing epoch request and replaces it.
    ///      For ConcreteAsyncVaultImpl, request IDs are epoch IDs.
    function testUpdateRedemptionRequestFromTarget_replacesEpochRequestShares() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 epochId = 1;

        uint256 oldShares = targetVault.convertToShares(10_000e6);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(oldShares);

        assertEq(
            targetVault.getUserEpochRequest(positionOwner, epochId), oldShares, "pre: expected old epoch request shares"
        );

        uint256 newShares = targetVault.convertToShares(7_000e6);
        vm.prank(operator);
        helper.updateRedemptionRequestFromTarget(epochId, newShares);

        assertEq(
            targetVault.getUserEpochRequest(positionOwner, epochId),
            newShares,
            "post: expected epoch request shares to be replaced with new amount"
        );
    }

    /// @dev updateRedemptionRequestFromTarget() reverts when there is no existing request to cancel.
    function testUpdateRedemptionRequestFromTarget_revertsWhenNoExistingRequest() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 newShares = targetVault.convertToShares(1_000e6);

        vm.prank(operator);
        vm.expectRevert(); // ConcreteAsyncVaultImpl: no requesting shares for this epoch
        helper.updateRedemptionRequestFromTarget(1, newShares);
    }

    /// @dev updateRedemptionRequestFromTarget() reverts when newSharesAmount is zero.
    function testUpdateRedemptionRequestFromTarget_revertsWhenNewSharesIsZero() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 oldShares = targetVault.convertToShares(1_000e6);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(oldShares);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.ZeroShares.selector);
        helper.updateRedemptionRequestFromTarget(1, 0);
    }

    /// @dev updateRedemptionRequestFromTarget() reverts when called by non-operator.
    function testUpdateRedemptionRequestFromTarget_revertsWhenCalledByNonOperator() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 oldShares = targetVault.convertToShares(1_000e6);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(oldShares);

        uint256 newShares = targetVault.convertToShares(500e6);
        vm.expectRevert();
        helper.updateRedemptionRequestFromTarget(1, newShares);
    }
}
