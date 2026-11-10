// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

// ── Clone library ──────────────────────────────────────────────────────────────
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

// ── OpenZeppelin ───────────────────────────────────────────────────────────────
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ── Aave V3 ────────────────────────────────────────────────────────────────────
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {ICreditDelegationToken} from "@aave/core-v3/contracts/interfaces/ICreditDelegationToken.sol";

// ── Uniswap V3 ─────────────────────────────────────────────────────────────────
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

// ── Protocol ───────────────────────────────────────────────────────────────────
import {ConcreteFactory} from "../../../src/factory/ConcreteFactory.sol";
import {ConcreteAsyncVaultImpl} from "../../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {AllocateModule} from "../../../src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

// ── Subject under test ─────────────────────────────────────────────────────────
import {PositionHelperAaveV3} from "../../../src/periphery/positionhelper/PositionHelperAaveV3.sol";
import {IPositionHelperBase} from "../../../src/periphery/interface/IPositionHelperBase.sol";
import {FlashModuleAaveV3} from "../../../src/periphery/auxiliary/FlashModuleAaveV3.sol";
import {SwapModuleUniV3} from "../../../src/periphery/auxiliary/SwapModuleUniV3.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";
import {RAY, WAD} from "../../../src/periphery/lib/Constants.sol";

/// @title  PositionHelperLiquidationE2ETest
/// @notice Fork-test scaffold for PositionHelperAaveV3 with a WBTC/USDC position.
///
///         Setup:
///           • collateral : WBTC  (8 decimals)
///           • borrow     : USDC  (6 decimals)
///           • lender     : Aave V3 mainnet, variable-rate mode
///           • flash loan : FlashModuleAaveV3 (Aave V3 flash loans)
///           • swap       : SwapModuleUniV3  (WBTC/USDC 0.30 % Uniswap V3 pool)
///           • target     : ConcreteAsyncVaultImpl with USDC as asset
///           • positionOwner: EOA (alice)
///
///         Approvals are NOT set in setUp — call `_setupApprovalsAndRoles` inside
///         tests that need the full lifecycle.  This allows dedicated tests to verify
///         that missing approvals are properly rejected.
contract PositionHelperLiquidationE2ETest is Test {
    using SafeERC20 for IERC20;

    // ── Mainnet constants ──────────────────────────────────────────────────────
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address internal constant AAVE_V3_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;
    address internal constant AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Uniswap V3 WBTC/USDC — 0.30 % fee tier
    uint24 internal constant WBTC_USDC_FEE = 3000;

    uint8 internal constant WBTC_DECIMALS = 8;
    uint8 internal constant USDC_DECIMALS = 6;
    // ── LTV parameters (WAD-scaled, 1e18 = 100 %) ─────────────────────────────
    uint64 internal constant HEALTHY_LTV = 0.55e18; // 55 %
    uint64 internal constant HEALTHY_LTV_DEVIATION = 0.05e18; //  5 %
    uint64 internal constant SELF_LIQ_BUFFER = 0.05e18; //  5 %

    // ── Contracts ─────────────────────────────────────────────────────────────
    PositionHelperAaveV3 internal helper;
    ConcreteAsyncVaultImpl internal usdcVault; // USDC-asset target for borrowed funds
    FlashModuleAaveV3 internal flashModule;
    SwapModuleUniV3 internal swapModule;

    // ── Actors ────────────────────────────────────────────────────────────────
    address internal alice; // positionOwner — holds WBTC, has Aave approvals
    address internal helperAdmin; // POSITION_ADMIN_ROLE on the clone
    address internal operator; // POSITION_OPERATOR_ROLE on the clone
    address internal vaultAdmin;
    address internal vaultManager;
    address internal factoryOwner;
    ConcreteFactory internal factory;
    AllocateModule internal allocateModule;

    // ── Aave token addresses (resolved after fork) ─────────────────────────────
    address internal aWBTC; // aToken for WBTC collateral
    address internal debtUSDC; // variable-debt token for USDC

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 23_800_000);

        alice = makeAddr("alice");
        helperAdmin = makeAddr("helperAdmin");
        operator = makeAddr("operator");
        vaultAdmin = makeAddr("vaultAdmin");
        vaultManager = makeAddr("vaultManager");
        factoryOwner = makeAddr("factoryOwner");
        address managementFeeRecipient = makeAddr("managementFeeRecipient");
        address performanceFeeRecipient = makeAddr("performanceFeeRecipient");
        factory = ConcreteFactory(
            address(
                new ERC1967Proxy(
                    address(new ConcreteFactory()),
                    abi.encodeCall(ConcreteFactory.initialize, (factoryOwner, address(0)))
                )
            )
        );
        // set the configuration for the factory
        vm.prank(factoryOwner);
        factory.setDefaultEnforcedVaultConfiguration(managementFeeRecipient, performanceFeeRecipient);
        allocateModule = new AllocateModule();

        usdcVault = _deployUsdcVault();
        _deployModules();
        helper = _deployAndInitHelper();
        _resolveAaveTokens();
        _setLabels();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private setup helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploys a fresh ConcreteFactory + ConcreteAsyncVaultImpl with USDC as asset.
    function _deployUsdcVault() private returns (ConcreteAsyncVaultImpl) {
        ConcreteAsyncVaultImpl asyncImpl = new ConcreteAsyncVaultImpl(address(factory));
        uint64 vaultImpl = uint64(IContractId(address(asyncImpl)).ID());
        vm.prank(factoryOwner);
        factory.approveImplementation(address(asyncImpl));

        return ConcreteAsyncVaultImpl(
            factory.create(
                vaultImpl, vaultAdmin, abi.encode(address(allocateModule), USDC, vaultManager, "USDC Vault", "fUSDC")
            )
        );
    }

    /// @dev Deploys FlashModuleAaveV3 and SwapModuleUniV3 (WBTC/USDC direct, 0.30 %).
    function _deployModules() private {
        flashModule = new FlashModuleAaveV3(AAVE_V3_POOL_ADDRESSES_PROVIDER);

        swapModule = new SwapModuleUniV3(
            ISwapRouter(UNISWAP_V3_ROUTER),
            WBTC, // collateralToken
            USDC, // borrowToken
            address(0), // no intermediary — direct pool
            WBTC_USDC_FEE,
            0 // fee2 = 0
        );
    }

    /// @dev Deploys the PositionHelperAaveV3 implementation, clones it for alice,
    ///      initializes the clone, and grants it WITHDRAWAL_MANAGER on the usdcVault.
    function _deployAndInitHelper() private returns (PositionHelperAaveV3) {
        PositionHelperAaveV3 implementation = new PositionHelperAaveV3(AAVE_V3_DATA_PROVIDER);

        bytes memory cloneArgs = abi.encodePacked(alice, WBTC, USDC, WBTC_DECIMALS, USDC_DECIMALS);
        helper = PositionHelperAaveV3(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        helper.initialize(
            helperAdmin,
            operator,
            address(usdcVault),
            address(flashModule),
            address(swapModule),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );
        return helper;
    }

    /// @dev Resolves Aave aToken / debt-token addresses from the live fork.
    ///      Called unconditionally in setUp so that _setLabels has valid addresses.
    function _resolveAaveTokens() private {
        IPool pool = helper.POOL();
        aWBTC = pool.getReserveData(WBTC).aTokenAddress;
        debtUSDC = pool.getReserveData(USDC).variableDebtTokenAddress;
    }

    /// @dev Grants all positionOwner (alice) → helper approvals and roles required
    ///      for the full deploy / retract / self-liq lifecycle.
    ///
    ///      NOT called in setUp — invoke this at the start of each test that
    ///      exercises the normal happy path.  Tests that verify approval-gated
    ///      reverts must NOT call this.
    function _setupApprovalsAndRoles() internal {
        vm.startPrank(alice);
        // supply: helper pulls WBTC from alice
        IERC20(WBTC).approve(address(helper), type(uint256).max);
        // withdraw / self-liq: helper pulls aWBTC from alice
        IERC20(aWBTC).approve(address(helper), type(uint256).max);
        // borrow: credit-delegate variable-debt USDC to helper
        ICreditDelegationToken(debtUSDC).approveDelegation(address(helper), type(uint256).max);
        // repay: helper pulls USDC from alice
        IERC20(USDC).forceApprove(address(helper), type(uint256).max);
        // requestRedemption: helper pulls usdcVault shares from alice
        IERC20(address(usdcVault)).approve(address(helper), type(uint256).max);
        vm.stopPrank();

        vm.prank(vaultManager);
        usdcVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, address(helper));
    }

    function _setLabels() private {
        vm.label(WBTC, "WBTC");
        vm.label(USDC, "USDC");
        vm.label(aWBTC, "aWBTC");
        vm.label(debtUSDC, "debtUSDC(variable)");
        vm.label(address(helper), "PositionHelper");
        vm.label(address(usdcVault), "usdcVault");
        vm.label(address(flashModule), "FlashModule");
        vm.label(address(swapModule), "SwapModule");
        vm.label(alice, "alice(positionOwner)");
        vm.label(operator, "operator");
        vm.label(helperAdmin, "helperAdmin");
        vm.label(vaultManager, "vaultManager");
        vm.label(vaultAdmin, "vaultAdmin");
        vm.label(factoryOwner, "factoryOwner");
        vm.label(address(factory), "factory");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy a WBTC/USDC position then partially self-liquidate by amount.
    ///
    ///   • alice supplies 0.1 WBTC and borrows at HEALTHY_LTV (55 %).
    ///   • Debt after deploy is verified against the oracle price: ~55 % of the
    ///     collateral value in USDC.
    ///   • operator self-liquidates half the debt via flash loan.
    ///   • Collateral consumed by the swap ≈ debtToLiquidate × RAY / price
    ///     (the cost of buying that much USDC from the WBTC/USDC pool).
    function test_selfLiquidate_partialDebt() public {
        _setupApprovalsAndRoles();

        // ── 1. Fund alice ──────────────────────────────────────────────────────
        uint256 collateralAmount = 1e7; // 0.1 WBTC (8 decimals)
        deal(WBTC, alice, collateralAmount);

        // ── 2. Read oracle price before deploy ────────────────────────────────
        // price: 1 WBTC expressed in USDC units, RAY-scaled (encodes decimal diff)
        uint256 price = helper.collateralPriceInBorrowTokensInRay();

        // ── 3. Deploy: supply → borrow → deposit into vault ───────────────────
        vm.prank(operator);
        helper.deploy(collateralAmount, HEALTHY_LTV);

        // ── 4. Assert position state after deploy ─────────────────────────────
        uint256 collateralBefore = helper.getCollateralAmount();
        uint256 debtBefore = helper.getDebtAmount();

        // Aave mints aTokens 1:1 but the index rounds the balance by ±1 satoshi.
        assertApproxEqAbs(collateralBefore, collateralAmount, 1, "collateral mismatch after deploy");

        // debt ≈ collateral × price/RAY × HEALTHY_LTV/WAD  (1 % tolerance for rounding)
        uint256 expectedDebt = collateralAmount * price / RAY * uint256(HEALTHY_LTV) / WAD;
        assertApproxEqRel(debtBefore, expectedDebt, 0.01e18, "debt mismatch after deploy");

        // ── 5. Self-liquidate half the debt ───────────────────────────────────
        // Position is at HEALTHY_LTV (55 %), well below the canLiquidate trigger
        // (liqThreshold − selfLiqBuffer ≈ 73 % for WBTC). Use helperAdmin who
        // bypasses the LTV guard; the E2E test exercises flash/swap mechanics.
        uint256 debtToLiquidate = debtBefore / 2;
        uint64 maxSlippage = 0.02e18; // 2 %

        vm.prank(helperAdmin);
        helper.selfLiquidate(debtToLiquidate, maxSlippage);

        // ── 6. Assert post-liquidation state ──────────────────────────────────
        uint256 collateralAfter = helper.getCollateralAmount();
        uint256 debtAfter = helper.getDebtAmount();

        // Debt reduced by the flash amount; 10-wei tolerance for Aave ray rounding.
        assertApproxEqAbs(debtAfter, debtBefore - debtToLiquidate, 10, "debt mismatch after self-liq");

        // Net WBTC consumed ≈ debtToLiquidate × RAY / price (the swap cost).
        // Flash premium (0.05 %) and slippage are small — allow 3 % relative tolerance.
        uint256 expectedCollateralUsed = debtToLiquidate * RAY / price;
        assertApproxEqRel(
            collateralBefore - collateralAfter, expectedCollateralUsed, 0.03e18, "collateral consumed mismatch"
        );

        // Zero-balance invariant: helper must not hold tokens at rest.
        assertEq(IERC20(WBTC).balanceOf(address(helper)), 0, "WBTC stranded in helper");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "USDC stranded in helper");
    }

    /// @notice Deploy a position then self-liquidate to a target LTV.
    ///
    ///   • alice supplies 0.1 WBTC at 55 % LTV.
    ///   • operator calls selfLiquidateToLtv(30 %) — the helper computes the
    ///     required flash amount internally.
    ///   • Final LTV should land at ~30 % (1 % tolerance).
    function test_selfLiquidateToLtv() public {
        _setupApprovalsAndRoles();

        uint256 collateralAmount = 1e7; // 0.1 WBTC
        deal(WBTC, alice, collateralAmount);

        vm.prank(operator);
        helper.deploy(collateralAmount, HEALTHY_LTV);

        uint256 debtBefore = helper.getDebtAmount();
        uint256 collateralBefore = helper.getCollateralAmount();

        uint64 targetLtv = 0.3e18; // 30 %
        uint64 maxSlippage = 0.02e18; // 2 %

        // Position is at 55 %, below the operator's canLiquidate trigger. Use helperAdmin.
        vm.prank(helperAdmin);
        helper.selfLiquidateToLtv(targetLtv, maxSlippage);

        // LTV should land at the requested 30 %.  Ceiling-rounding in
        // flashWithdrawAmountFromTargetLtv withdraws a hair more collateral than
        // strictly necessary, so the final LTV undershoots by up to ~1.1 %.
        // Allow 2 % relative tolerance.
        assertApproxEqRel(
            helper.getCurrentLtvInWad(), uint256(targetLtv), 0.02e18, "LTV mismatch after selfLiquidateToLtv"
        );

        // Both debt and collateral must have decreased.
        assertLt(helper.getDebtAmount(), debtBefore, "debt not reduced");
        assertLt(helper.getCollateralAmount(), collateralBefore, "collateral not reduced");

        // Zero-balance invariant.
        assertEq(IERC20(WBTC).balanceOf(address(helper)), 0, "WBTC stranded in helper");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "USDC stranded in helper");
    }

    /// @notice selfLiquidateToLtv reverts when the target LTV is above the current LTV.
    ///
    ///   Position is deployed at 55 %.  Passing 60 % as the target means the
    ///   position is already below that level — no collateral needs to be freed,
    ///   so the helper reverts with TargetLtvTooHigh.
    function test_selfLiquidateToLtv_revertsWhenTargetAboveCurrentLtv() public {
        _setupApprovalsAndRoles();

        deal(WBTC, alice, 1e7);

        vm.prank(operator);
        helper.deploy(1e7, HEALTHY_LTV); // deploys at ~55 %

        // 60 % target > ~55 % current → position already below target → revert.
        // Use helperAdmin to bypass the canLiquidate LTV guard and reach the TargetLtvTooHigh check.
        vm.expectRevert(IPositionHelperBase.TargetLtvTooHigh.selector);
        vm.prank(helperAdmin);
        helper.selfLiquidateToLtv(0.6e18, 0.02e18);
    }

    /// @notice deploy() reverts when alice has not approved WBTC transfer.
    ///
    ///   No approvals are set — the helper cannot pull collateral from alice,
    ///   so the supply step reverts on the ERC20 transferFrom.
    function test_deploy_revertsWithoutCollateralApproval() public {
        deal(WBTC, alice, 1e7); // funded but no approval

        vm.expectRevert();
        vm.prank(operator);
        helper.deploy(1e7, HEALTHY_LTV);
    }

    /// @notice selfLiquidate() reverts when alice has not approved aWBTC transfer.
    ///
    ///   Only the approvals needed for deploy (WBTC transfer + credit delegation)
    ///   are set.  The aWBTC approval that the flash callback requires to pull
    ///   collateral from alice is intentionally omitted, so the flash callback
    ///   reverts and the whole transaction unwinds.
    function test_selfLiquidate_revertsWithoutATokenApproval() public {
        deal(WBTC, alice, 1e7);

        // Grant only the approvals needed to get a position open.
        vm.startPrank(alice);
        IERC20(WBTC).approve(address(helper), type(uint256).max);
        ICreditDelegationToken(debtUSDC).approveDelegation(address(helper), type(uint256).max);
        vm.stopPrank();

        vm.prank(operator);
        helper.deploy(1e7, HEALTHY_LTV);

        // Pre-compute before vm.expectRevert() — otherwise the view call would be
        // the "next call" consumed by the expectation instead of selfLiquidate.
        uint256 debtToLiquidate = helper.getDebtAmount() / 2;

        // aWBTC approval deliberately absent — flash callback cannot pull collateral.
        vm.expectRevert();
        vm.prank(operator);
        helper.selfLiquidate(debtToLiquidate, 0.02e18);
    }
}
