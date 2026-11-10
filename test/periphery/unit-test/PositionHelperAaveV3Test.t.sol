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

// ── Aave V3 ───────────────────────────────────────────────────────────────────
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {ICreditDelegationToken} from "@aave/core-v3/contracts/interfaces/ICreditDelegationToken.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";

// ── Protocol ──────────────────────────────────────────────────────────────────
import {ConcreteFactory} from "../../../src/factory/ConcreteFactory.sol";
import {ConcreteAsyncVaultImpl} from "../../../src/implementation/ConcreteAsyncVaultImpl.sol";
import {AllocateModule} from "../../../src/module/AllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";

// ── Test mocks ────────────────────────────────────────────────────────────────
import {MockFlashModule} from "../mock/MockFlashModule.sol";
import {MockSwapper} from "../mock/MockSwapper.sol";

// ── Subject under test ────────────────────────────────────────────────────────
import {PositionHelperAaveV3} from "../../../src/periphery/positionhelper/PositionHelperAaveV3.sol";
import {IPositionHelperBase, PositionApprovals} from "../../../src/periphery/interface/IPositionHelperBase.sol";
import {WAD, RAY} from "../../../src/periphery/lib/Constants.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

/// @title  PositionHelperAaveV3Test
/// @notice Fork-based unit tests for PositionHelperAaveV3 using WETH as collateral
///         and USDT as borrow token against a live Aave V3 mainnet deployment.
///
/// @dev Setup overview:
///   • Mainnet fork at block 23_800_000.
///   • Lender: Aave V3 mainnet (DATA_PROVIDER address, variable-rate mode).
///   • Vault: freshly deployed ConcreteAsyncVaultImpl with USDT as asset.
///   • PositionHelper: implementation deployed then cloned with
///       immutable args = [positionOwner | WETH | USDT | 18 | 6].
///   • positionOwner is a plain EOA; operator holds POSITION_OPERATOR_ROLE.
contract PositionHelperAaveV3Test is Test {
    using SafeERC20 for IERC20;
    // ── Mainnet constants ─────────────────────────────────────────────────────

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant AAVE_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;

    uint256 internal constant FORK_BLOCK = 23_800_000;
    uint256 internal constant VARIABLE_RATE = 2;
    uint8 internal constant WETH_DECIMALS = 18;
    uint8 internal constant USDT_DECIMALS = 6;

    // ── LTV parameters (WAD-scaled) ───────────────────────────────────────────
    // 0.60e18 = 60%, 0.05e18 = 5%

    uint64 internal constant HEALTHY_LTV = 600_000_000_000_000_000; // 60% in WAD
    uint64 internal constant HEALTHY_LTV_DEVIATION = 50_000_000_000_000_000; // 5%  in WAD
    uint64 internal constant SELF_LIQ_BUFFER = 50_000_000_000_000_000; // 5%  in WAD

    // ── Contracts ─────────────────────────────────────────────────────────────

    PositionHelperAaveV3 internal implementation;
    PositionHelperAaveV3 internal helper;
    ConcreteAsyncVaultImpl internal targetVault;

    // ── Actors ────────────────────────────────────────────────────────────────

    address internal positionOwner;
    address internal admin;
    address internal operator;
    address internal flashModule; // placeholder; flash ops not tested here
    address internal swapModule; // placeholder; swap ops not tested here
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
        // This suite doesn't execute flash/swap flows, but the helper initializer requires
        // deployed contracts (non-zero code) for both modules.
        flashModule = address(new MockFlashModule(admin, 0));
        swapModule = address(new MockSwapper(admin));

        // ── Deploy ConcreteAsyncVaultImpl as target vault (USDT asset) ────────
        //    Uses the same factory-deployment pattern as ConcreteAsyncVaultImplBaseSetup.
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
                abi.encode(address(allocateModule), USDT, vaultManager, "Test Async USDT Vault", "taUSDT")
            )
        );

        // ── Deploy PositionHelperAaveV3 implementation ────────────────────────
        //    Constructor calls _disableInitializers(); clones must call initialize().
        implementation = new PositionHelperAaveV3(AAVE_DATA_PROVIDER);

        // ── Clone with immutable args ─────────────────────────────────────────
        //    Encoding: [positionOwner (20)] [WETH (20)] [USDT (20)] [18 (1)] [6 (1)]
        bytes memory cloneArgs = abi.encodePacked(positionOwner, WETH, USDT, WETH_DECIMALS, USDT_DECIMALS);
        helper = PositionHelperAaveV3(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        // ── Initialize clone ──────────────────────────────────────────────────
        helper.initialize(
            admin,
            operator,
            address(targetVault),
            flashModule,
            swapModule,
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );

        // ── Grant helper the WITHDRAWAL_MANAGER role on the vault ─────────────
        //    Required for cancelRedemptionRequestFromTarget / claimRedemptionFromTarget.
        vm.startPrank(vaultManager);
        targetVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, address(helper));
        vm.stopPrank();

        // ── Labels ────────────────────────────────────────────────────────────
        vm.label(WETH, "WETH");
        vm.label(USDT, "USDT");
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

    /// @dev Returns the Aave aToken address for WETH on mainnet.
    function _aToken() internal view returns (address) {
        return IPool(helper.POOL()).getReserveData(WETH).aTokenAddress;
    }

    /// @dev Returns the Aave variable-debt token address for USDT on mainnet.
    function _debtToken() internal view returns (address) {
        return IPool(helper.POOL()).getReserveData(USDT).variableDebtTokenAddress;
    }

    /// @dev Deals WETH to positionOwner, approves helper for WETH, and calls supply.
    function _supply(uint256 amount) internal {
        deal(WETH, positionOwner, amount);
        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        vm.prank(operator);
        helper.supply(amount);
    }

    /// @dev Supplies collateral then borrows from Aave via the helper.
    function _supplyAndBorrow(uint256 collateral, uint256 borrowAmount) internal {
        _supply(collateral);
        address debtToken_ = _debtToken(); // cache before vm.prank — _debtToken() is an external call
        vm.prank(positionOwner);
        ICreditDelegationToken(debtToken_).approveDelegation(address(helper), type(uint256).max);
        vm.prank(operator);
        helper.borrow(borrowAmount);
    }

    /// @dev Sets every positionOwner approval required for the full helper surface.
    function _setupOwnerApprovals() internal {
        vm.startPrank(positionOwner);
        // supply
        IERC20(WETH).approve(address(helper), type(uint256).max);
        // withdraw (aToken)
        IERC20(_aToken()).approve(address(helper), type(uint256).max);
        // repay
        IERC20(USDT).forceApprove(address(helper), type(uint256).max);
        // borrow (credit delegation)
        ICreditDelegationToken(_debtToken()).approveDelegation(address(helper), type(uint256).max);
        // requestRedemptionFromTarget (vault shares)
        IERC20(address(targetVault)).approve(address(helper), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Deployment & init
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Verifies all clone immutable args are encoded and decoded correctly.
    function testDeployment_verifyImmutables() public view {
        assertEq(helper.POSITION_OWNER(), positionOwner, "POSITION_OWNER mismatch");
        assertEq(helper.COLLATERAL_TOKEN(), WETH, "COLLATERAL_TOKEN mismatch");
        assertEq(helper.BORROW_TOKEN(), USDT, "BORROW_TOKEN mismatch");
        assertEq(helper.COLLATERAL_DECIMALS(), WETH_DECIMALS, "COLLATERAL_DECIMALS mismatch");
        assertEq(helper.BORROW_DECIMALS(), USDT_DECIMALS, "BORROW_DECIMALS mismatch");
        assertEq(address(helper.DATA_PROVIDER()), AAVE_DATA_PROVIDER, "DATA_PROVIDER mismatch");
        assertEq(helper.INTEREST_RATE_MODE(), VARIABLE_RATE, "INTEREST_RATE_MODE mismatch");
        uint64 id = uint64(IContractId(address(helper)).ID());
        // assertEq(id, 400110100);
        assertTrue(address(helper.POOL()) != address(0), "POOL must be non-zero");
        assertTrue(address(helper.PRICE_ORACLE()) != address(0), "PRICE_ORACLE must be non-zero");
    }

    /// @dev Verifies storage params written by initialize().
    function testDeployment_verifyInitParams() public view {
        assertEq(helper.yieldVault(), address(targetVault), "target mismatch");
        assertEq(helper.flashModule(), flashModule, "flashModule mismatch");
        assertEq(helper.swapModule(), swapModule, "swapModule mismatch");

        assertTrue(helper.hasRole(helper.POSITION_ADMIN_ROLE(), admin), "admin should have POSITION_ADMIN_ROLE");
        assertTrue(
            helper.hasRole(helper.POSITION_OPERATOR_ROLE(), operator), "operator should have POSITION_OPERATOR_ROLE"
        );
    }

    /// @dev Verifies that initialize() sets MAX allowances from helper to Aave pool / target.
    function testDeployment_verifyHelperTokenAllowances() public view {
        address pool = address(helper.POOL());
        address target = address(targetVault);

        assertEq(
            IERC20(WETH).allowance(address(helper), pool),
            type(uint256).max,
            "WETH -> pool allowance must be MAX (for supply)"
        );
        assertEq(
            IERC20(USDT).allowance(address(helper), pool),
            type(uint256).max,
            "USDT -> pool allowance must be MAX (for repay)"
        );
        assertEq(
            IERC20(USDT).allowance(address(helper), target),
            type(uint256).max,
            "USDT -> target allowance must be MAX (for depositOnTarget)"
        );
        assertEq(
            IERC20(USDT).allowance(address(helper), flashModule),
            type(uint256).max,
            "USDT -> flashModule allowance must be MAX"
        );
    }

    function testSelfLiquidationMaxSlippage_defaultUpdateAndGuards() public {
        uint64 defaultCap = 100_000_000_000_000_000; // 10%
        assertEq(helper.maxSelfLiquidationSlippageInWad(), defaultCap, "default max slippage should be 10%");

        // Use admin for all slippage checks — admin bypasses the canLiquidate LTV guard,
        // so these calls reach the slippage / NoDebt checks as intended.

        // Above cap: should revert before the NoDebt check (circuit breaker).
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPositionHelperBase.MaxSlippageTooHigh.selector,
                uint64(110_000_000_000_000_000), // 11%
                defaultCap
            )
        );
        helper.selfLiquidate(0, 110_000_000_000_000_000);

        // At cap: passes slippage guard; hits NoDebt (no debt position is set up in this unit test).
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.NoDebt.selector);
        helper.selfLiquidate(0, defaultCap);

        // Update cap as admin.
        uint64 newCap = 50_000_000_000_000_000; // 5%
        vm.prank(admin);
        helper.setMaxSelfLiquidationSlippageInWad(newCap);
        assertEq(helper.maxSelfLiquidationSlippageInWad(), newCap, "max slippage should update");

        // Now 6% should revert with the new cap.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPositionHelperBase.MaxSlippageTooHigh.selector, uint64(60_000_000_000_000_000), newCap
            )
        );
        helper.selfLiquidate(0, 60_000_000_000_000_000);

        // And 5% should pass slippage guard (still NoDebt).
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.NoDebt.selector);
        helper.selfLiquidate(0, newCap);

        // Setter guards are covered elsewhere.
    }

    /// @dev Constructor reverts when dataProvider is address(0).
    function testDeployment_revertsWhenDataProviderIsZero() public {
        vm.expectRevert(IPositionHelperBase.ZeroAddress.selector);
        new PositionHelperAaveV3(address(0));
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
            SELF_LIQ_BUFFER
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. supply
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev supply() transfers WETH from positionOwner through the helper to Aave;
    ///      aTokens are minted directly to positionOwner; helper holds nothing at rest.
    function testSupply_sendsWethFromOwnerThroughHelperToAave() public {
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

        // positionOwner received aWETH from Aave (≈ 1:1, tiny rounding possible)
        assertApproxEqAbs(
            IERC20(_aToken()).balanceOf(positionOwner), supplyAmount, 1e9, "positionOwner aToken balance mismatch"
        );

        // helper is clean — no residual WETH or aTokens
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(_aToken()).balanceOf(address(helper)), 0, "helper must hold no aTokens");

        // Aave reports the collateral position
        assertApproxEqAbs(helper.getCollateralAmount(), supplyAmount, 1e9, "getCollateralAmount mismatch");
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

    /// @dev borrow() borrows USDT on behalf of positionOwner and sends it directly
    ///      to positionOwner; positionOwner accumulates variable debt at Aave.
    function testBorrow_sendsUsdtToPositionOwner() public {
        _supply(5 ether);

        address debtToken_ = _debtToken();
        vm.prank(positionOwner);
        ICreditDelegationToken(debtToken_).approveDelegation(address(helper), type(uint256).max);

        uint256 borrowAmount = 100e6; // 100 USDT

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Borrowed(borrowAmount);

        vm.prank(operator);
        helper.borrow(borrowAmount);

        assertEq(IERC20(USDT).balanceOf(positionOwner), borrowAmount, "positionOwner USDT balance mismatch");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");

        // Aave registers debt under positionOwner
        assertApproxEqAbs(helper.getDebtAmount(), borrowAmount, 1e9, "getDebtAmount mismatch");
        assertGt(helper.getCurrentLtvInWad(), 0, "LTV should be > 0 after borrow");
    }

    /// @dev borrow() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testBorrow_revertsWhenCalledByNonOperator() public {
        _supply(5 ether);
        address debtToken_ = _debtToken();
        vm.prank(positionOwner);
        ICreditDelegationToken(debtToken_).approveDelegation(address(helper), type(uint256).max);

        vm.expectRevert();
        helper.borrow(10e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. repay
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev repay() transfers USDT from positionOwner through the helper to Aave
    ///      and clears the debt; helper holds nothing at rest.
    function testRepay_clearsPositionOwnerDebt() public {
        _supplyAndBorrow(5 ether, 200e6);

        uint256 debtBefore = helper.getDebtAmount();
        assertGt(debtBefore, 0, "no debt to repay");

        // Extra buffer for interest that may have accrued
        uint256 repayAmount = debtBefore;
        deal(USDT, positionOwner, repayAmount);

        vm.prank(positionOwner);
        IERC20(USDT).forceApprove(address(helper), type(uint256).max);

        // The Repaid event carries the amount Aave actually debited, which is the true debt
        // without the REPAY_RAY_ROUNDING_BUFFER that getDebtAmount() adds. Don't check data.
        vm.expectEmit(false, false, false, false, address(helper));
        emit IPositionHelperBase.Repaid(0);

        vm.prank(operator);
        helper.repay(repayAmount);
        console.log("helper usdt balance after repay", IERC20(USDT).balanceOf(address(helper)));
        assertLe(helper.getDebtAmount(), 2, "debt should be fully cleared");
        assertEq(helper.getCurrentLtvInWad(), 0, "LTV must be 0 after full repay");
        assertLe(IERC20(USDT).balanceOf(address(helper)), 2, "helper must hold no USDT");
    }

    /// @dev repay() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testRepay_revertsWhenCalledByNonOperator() public {
        deal(USDT, positionOwner, 100e6);
        vm.prank(positionOwner);
        IERC20(USDT).forceApprove(address(helper), type(uint256).max);

        vm.expectRevert();
        helper.repay(100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. withdraw (and withdraw-with-loan)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev withdraw() pulls aTokens from positionOwner, redeems via Aave pool,
    ///      and returns WETH to positionOwner; helper holds nothing at rest.
    function testWithdraw_returnsCollateralToPositionOwner() public {
        uint256 supplyAmount = 5 ether;
        uint256 withdrawAmount = supplyAmount / 2;
        _supply(supplyAmount);

        // positionOwner must approve aToken transfer to the helper
        address aToken_ = _aToken();
        vm.prank(positionOwner);
        IERC20(aToken_).approve(address(helper), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.Withdrawn(withdrawAmount);

        vm.prank(operator);
        helper.withdraw(withdrawAmount);

        assertApproxEqAbs(
            IERC20(WETH).balanceOf(positionOwner), withdrawAmount, 1e9, "positionOwner WETH balance mismatch"
        );
        assertApproxEqAbs(
            helper.getCollateralAmount(), supplyAmount - withdrawAmount, 1e9, "remaining collateral mismatch"
        );
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    /// @dev withdraw() still works when a small debt exists, as long as health factor
    ///      permits the withdrawal. (withdraw-with-loan / WWL scenario)
    ///
    /// @dev NOTE: Aave's health-factor check fires at the aToken safeTransferFrom.
    ///      The withdrawal amount is kept small to guarantee the position stays healthy.
    function testWithdrawWithLoan_partialWithdrawKeepsPositionHealthy() public {
        // Supply 10 WETH, take a small USDT loan (~3% LTV), then withdraw 1 WETH.
        // With WETH ~$2 500 and 10 WETH collateral, 100 USDT ≈ 0.04% LTV — well within limits.
        _supplyAndBorrow(10 ether, 100e6);

        uint256 collateralBefore = helper.getCollateralAmount();
        uint256 withdrawAmount = 1 ether;

        address aToken_ = _aToken();
        vm.prank(positionOwner);
        IERC20(aToken_).approve(address(helper), type(uint256).max);

        vm.prank(operator);
        helper.withdraw(withdrawAmount);

        assertApproxEqAbs(
            helper.getCollateralAmount(),
            collateralBefore - withdrawAmount,
            1e9,
            "collateral should decrease by withdrawn amount"
        );
        assertGt(helper.getCurrentLtvInWad(), 0, "LTV should still reflect outstanding debt");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no residual WETH");
    }

    /// @dev withdraw() reverts when called by an address without POSITION_OPERATOR_ROLE.
    function testWithdraw_revertsWhenCalledByNonOperator() public {
        _supply(2 ether);
        address aToken_ = _aToken();
        vm.prank(positionOwner);
        IERC20(aToken_).approve(address(helper), type(uint256).max);

        vm.expectRevert();
        helper.withdraw(1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. deploy (high-level position flow)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev deploy() supplies collateral, borrows to targetLtv, and deposits borrowed
    ///      USDT into the target vault; positionOwner ends up with vault shares.
    function testDeploy_supplyBorrowDepositToTargetLtv() public {
        uint256 collateralAmount = 5 ether;
        uint64 targetLtvInWad = 500_000_000_000_000_000; // 50% in WAD

        deal(WETH, positionOwner, collateralAmount);

        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);

        address debtToken_ = _debtToken();
        vm.prank(positionOwner);
        ICreditDelegationToken(debtToken_).approveDelegation(address(helper), type(uint256).max);

        vm.prank(operator);
        helper.deploy(collateralAmount, targetLtvInWad);

        // Collateral is at Aave under positionOwner
        assertApproxEqAbs(helper.getCollateralAmount(), collateralAmount, 1e9, "collateral not supplied to Aave");

        // Debt exists (borrow was triggered)
        assertGt(helper.getDebtAmount(), 0, "no debt after deploy - borrow step missed");

        // LTV approximates the target (±1%)
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(targetLtvInWad),
            1e16, // 1% tolerance
            "LTV should approximate targetLtv after deploy"
        );

        // Borrowed USDT was deposited into the target vault — positionOwner holds shares
        assertGt(
            IERC20(address(targetVault)).balanceOf(positionOwner),
            0,
            "positionOwner should hold target vault shares after deploy"
        );

        // Helper is clean
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }

    /// @dev deploy() with targetLtv = 0 only supplies; borrow and deposit are skipped.
    function testDeploy_skipsWhenTargetLtvIsZero() public {
        uint256 collateralAmount = 3 ether;
        deal(WETH, positionOwner, collateralAmount);

        vm.prank(positionOwner);
        IERC20(WETH).approve(address(helper), type(uint256).max);

        vm.prank(operator);
        helper.deploy(collateralAmount, 0);

        assertApproxEqAbs(helper.getCollateralAmount(), collateralAmount, 1e9, "collateral should be supplied");
        assertEq(helper.getDebtAmount(), 0, "no debt expected when targetLtv = 0");
        assertEq(IERC20(address(targetVault)).balanceOf(positionOwner), 0, "no vault shares expected without borrow");
    }

    /// @dev deploy() reverts when targetLtvInWad exceeds the collateral asset's protocol max LTV.
    function testDeploy_revertsWhenTargetLtvExceedsMaxLtv() public {
        uint64 tooHighLtv = helper.getMaxLtvInWad() + 1;

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.TargetLtvExceedsMaxLtv.selector);
        helper.deploy(1 ether, tooHighLtv);
    }

    /// @dev When pool borrow liquidity is below the computed borrowAmount, deploy() caps the
    ///      borrow to available liquidity; position lands below targetLtv.
    function testDeploy_partialBorrowWhenPoolLiquidityInsufficient() public {
        _mockWethPrice(WETH_ORACLE_PRICE);
        _mockUsdtPrice(USDT_ORACLE_PRICE);
        _setupOwnerApprovals();

        uint256 collateralAmount = 5 ether;
        uint64 targetLtvInWad = 500_000_000_000_000_000; // 50%
        deal(WETH, positionOwner, collateralAmount);

        // 5 WETH at $2,000 targeting 50% LTV requires 5,000 USDT.
        // Cap pool liquidity to 100 USDT so the borrow is partially filled.
        uint256 cappedLiquidity = 100e6;
        address aUsdtAddress = IPool(helper.POOL()).getReserveData(USDT).aTokenAddress;
        vm.mockCall(USDT, abi.encodeWithSelector(IERC20.balanceOf.selector, aUsdtAddress), abi.encode(cappedLiquidity));

        vm.prank(operator);
        helper.deploy(collateralAmount, targetLtvInWad);

        // Some debt exists but LTV is well below target due to the liquidity cap.
        assertGt(helper.getDebtAmount(), 0, "debt should exist after partial borrow");
        assertLt(
            uint256(helper.getCurrentLtvInWad()),
            uint256(targetLtvInWad),
            "LTV should be below target when pool liquidity was insufficient"
        );
        // Capped borrow was still deposited into the target vault.
        assertGt(
            IERC20(address(targetVault)).balanceOf(positionOwner), 0, "vault shares should exist after partial borrow"
        );
    }

    /// @dev deploy() with collateralAmount = 0 skips supply and borrows against existing
    ///      collateral to reach a higher targetLtv.
    function testDeploy_withZeroCollateral_borrowsToTargetLtv() public {
        _scenarioSetup();

        uint256 collateralAmount = 5 ether;
        deal(WETH, positionOwner, collateralAmount);

        // First deploy: supply 5 WETH and borrow to 30% LTV.
        vm.prank(operator);
        helper.deploy(collateralAmount, 300_000_000_000_000_000); // 30%

        uint256 collateralAfterFirst = helper.getCollateralAmount();
        uint256 debtAfterFirst = helper.getDebtAmount();
        assertGt(debtAfterFirst, 0, "debt should exist after initial deploy");

        // Second deploy: 0 collateral, increase leverage to 50% LTV.
        vm.prank(operator);
        helper.deploy(0, 500_000_000_000_000_000); // 50%

        // Collateral is unchanged — no supply occurred.
        assertApproxEqAbs(helper.getCollateralAmount(), collateralAfterFirst, 1e9, "collateral should be unchanged");
        // Additional borrowing occurred.
        assertGt(helper.getDebtAmount(), debtAfterFirst, "debt should have increased");
        // LTV now approximates the new target (±1%).
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(500_000_000_000_000_000),
            1e16,
            "LTV should approximate 50% after zero-collateral deploy"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. View / position data
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Fresh clone reports zero position.
    function testGetPosition_returnsZeroBeforeAnyActivity() public view {
        (uint256 col, uint256 debt) = helper.getPosition();
        assertEq(col, 0, "collateral should be 0 initially");
        assertEq(debt, 0, "debt should be 0 initially");
        assertEq(helper.getCurrentLtvInWad(), 0, "LTV should be 0 initially");
    }

    /// @dev getMaxLtvInWad() returns the Aave-configured max LTV for WETH.
    function testGetMaxLtvInWad_returnsAaveConfigValue() public view {
        uint64 maxLtv = helper.getMaxLtvInWad();
        assertGt(maxLtv, 0, "max LTV for WETH should be > 0 on mainnet");
        assertLt(maxLtv, WAD, "max LTV should be < 100%");
    }

    /// @dev getLiquidationThresholdInWad() is above max LTV (standard Aave V3 invariant).
    function testGetLiquidationThresholdInWad_isAboveMaxLtv() public view {
        uint64 liqThr = helper.getLiquidationThresholdInWad();
        assertGt(liqThr, 0, "liquidation threshold should be > 0");
        assertLt(liqThr, WAD, "liquidation threshold should be < 100%");
        assertGt(liqThr, helper.getMaxLtvInWad(), "liq threshold should exceed max LTV");
    }

    /// @dev collateralPriceInBorrowTokensInRay() returns a plausible WETH/USDT price.
    ///      At block 23_800_000 WETH is ~$2 500–$4 000 → at minimum > 1 000 USDT in RAY.
    function testCollateralPrice_returnsReasonableWethUsdtPrice() public view {
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        assertGt(price, 0, "WETH/USDT price in RAY should be > 0");
        // 1 WETH > 1 000 USDT → price (in RAY per WETH, scaled by USDT 6-dec) > 1_000e6 * RAY / 1e18
        assertGt(price, 1_000e6 * RAY / 1e18, "WETH price sanity check failed");
    }

    /// @dev getAvailablePoolLiquidity() returns the live USDT liquidity in Aave pool.
    function testGetAvailablePoolLiquidity_returnsNonZero() public view {
        uint256 liquidity = helper.getAvailablePoolLiquidity();
        assertGt(liquidity, 0, "Aave pool should have USDT liquidity on mainnet");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. checkApprovals
    // ─────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario helpers (shared by sections 9–12)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Aave oracle prices used for deterministic scenario math.
    ///      The oracle returns USD values with 8 decimals (1e8 = $1).
    uint256 internal constant WETH_ORACLE_PRICE = 2_000e8; // $2,000 / WETH
    uint256 internal constant USDT_ORACLE_PRICE = 1e8; // $1     / USDT

    /// @dev Mock the Aave oracle price for WETH (8-decimal USD, same format the pool uses).
    function _mockWethPrice(uint256 priceInOracle) internal {
        vm.mockCall(
            address(helper.PRICE_ORACLE()),
            abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, WETH),
            abi.encode(priceInOracle)
        );
    }

    /// @dev Mock the Aave oracle price for USDT.
    function _mockUsdtPrice(uint256 priceInOracle) internal {
        vm.mockCall(
            address(helper.PRICE_ORACLE()),
            abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, USDT),
            abi.encode(priceInOracle)
        );
    }

    /// @dev Set deterministic prices for both tokens and approve all helper surfaces.
    function _scenarioSetup() internal {
        _mockWethPrice(WETH_ORACLE_PRICE);
        _mockUsdtPrice(USDT_ORACLE_PRICE);
        _setupOwnerApprovals();
    }

    /// @dev Deploy 100 WETH at 50 % LTV. Returns the vault shares minted to positionOwner.
    ///      Call _scenarioSetup() (or at minimum deal WETH + set approvals) before this.
    function _deployAt50Pct() internal returns (uint256 shares) {
        deal(WETH, positionOwner, 100 ether);
        vm.prank(operator);
        helper.deploy(100 ether, 500_000_000_000_000_000); // 50 % in WAD
        shares = IERC20(address(targetVault)).balanceOf(positionOwner);
    }

    /// @dev Grant WITHDRAWAL_MANAGER to an address via the vaultManager
    ///      (who holds WITHDRAWAL_MANAGER_ADMIN from vault initialization).
    function _grantWithdrawalManager(address account) internal {
        vm.prank(vaultManager);
        targetVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, account);
    }

    /// @dev Close the current epoch and process it so queued redemptions become claimable.
    ///      Grants vaultManager the WITHDRAWAL_MANAGER role if not already held.
    function _processCurrentEpoch() internal {
        _grantWithdrawalManager(vaultManager);
        vm.prank(vaultManager);
        targetVault.closeEpoch();
        vm.prank(vaultManager);
        targetVault.processEpoch();
    }

    /// @dev checkApprovals() accurately reflects missing and present positionOwner approvals.
    function testCheckApprovals_reflectsOwnerApprovals() public {
        // Supply first so positionOwner holds aTokens (needed for lenderCollateralApproved check)
        _supply(2 ether);

        // Before any approvals are set — every field should be false
        PositionApprovals memory before = helper.checkApprovals();
        // assertFalse(before.collateralTokenApproved, "collateral not approved yet");
        assertFalse(before.lenderCollateralApproved, "aToken not approved yet");
        assertFalse(before.lenderDebtDelegated, "debt not delegated yet");
        assertFalse(before.borrowTokenApproved, "borrow token not approved yet");
        assertFalse(before.vaultSharesApproved, "vault shares not approved yet");

        // Grant all approvals
        _setupOwnerApprovals();

        PositionApprovals memory after_ = helper.checkApprovals();
        assertTrue(after_.collateralTokenApproved, "collateral token should be approved");
        assertTrue(after_.lenderCollateralApproved, "aToken should be approved");
        assertTrue(after_.lenderDebtDelegated, "debt should be delegated");
        assertTrue(after_.borrowTokenApproved, "borrow token should be approved");
        assertTrue(after_.vaultSharesApproved, "vault shares should be approved");

        // WITHDRAWAL_MANAGER role was granted in setUp()
        assertTrue(after_.hasWithdrawalManagerRole, "helper should have WITHDRAWAL_MANAGER on vault");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Scenario 1 — fresh deploy
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 1:
    ///   positionOwner receives 100 WETH (at $2,000/WETH).
    ///   deploy(100 WETH, 50 % LTV) supplies collateral, borrows ~100 k USDT, and
    ///   deposits that USDT into the target vault so positionOwner receives shares.
    function testScenario1_freshDeploy_suppliesBorrowsDepositsToVault() public {
        uint64 targetLtv = 500_000_000_000_000_000; // 50 %

        _scenarioSetup();
        uint256 sharesBefore = IERC20(address(targetVault)).balanceOf(positionOwner);

        deal(WETH, positionOwner, 100 ether);
        vm.prank(operator);
        helper.deploy(100 ether, targetLtv);

        // Collateral supplied to Aave under positionOwner (~100 WETH)
        assertApproxEqAbs(helper.getCollateralAmount(), 100 ether, 1e9, "collateral should be ~100 WETH");

        // Debt is ~100 k USDT  (100 WETH × $2,000 × 50 %)
        uint256 debt = helper.getDebtAmount();
        assertApproxEqAbs(debt, 100_000e6, 10, "debt should be ~100 k USDT");

        // LTV ≈ 50 %
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(targetLtv), 1e16, "LTV should be ~50 %");

        // positionOwner received vault shares
        uint256 sharesAfter = IERC20(address(targetVault)).balanceOf(positionOwner);
        assertGt(sharesAfter, sharesBefore, "positionOwner should hold vault shares after deploy");

        // Helper is clean (no residual tokens)
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. Scenario 2 — 20 % price drop → rebalance to 50 % LTV
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 2:
    ///
    ///   t0  100 WETH deployed at $2,000 (50 % LTV → ~100 k USDT borrowed).
    ///
    ///   t1  Price drops 20 % to $1,600.
    ///       LTV rises to ~62.5 %, above the configured healthyLtv (60 %).
    ///       calculateTargetRepayAmount(0, 50 %) gives the USDT needed to land at 50 %.
    ///       Operator requests redemption of the matching vault shares.
    ///
    ///   t2  Vault epoch is processed; positionOwner claims USDT.
    ///       Operator calls retract(repayAmount, 0, 50 %) — repays debt, no withdrawal.
    function testScenario2_priceDrop20pct_rebalanceToTargetLtv() public {
        // ── t0: initial position ─────────────────────────────────────────────
        _scenarioSetup();
        _deployAt50Pct();

        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), 500_000_000_000_000_000, 1e16, "t0: LTV should be ~50 %"
        );
        uint256 collateral0 = helper.getCollateralAmount();
        uint256 debt0 = helper.getDebtAmount();

        // ── t1: price drops 20 % ─────────────────────────────────────────────
        _mockWethPrice(1_600e8); // $2,000 → $1,600

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        // Expected: 50 % / 80 % = 62.5 %
        assertApproxEqAbs(uint256(ltvT1), 625_000_000_000_000_000, 1e16, "t1: LTV should be ~62.5 %");
        assertGt(uint256(ltvT1), uint256(HEALTHY_LTV), "t1: LTV should exceed configured healthyLtv (60 %)");

        // Repayment amount required to land at 50 % with 0 collateral withdrawn
        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50 %
        uint256 repayAmount = helper.calculateTargetRepayAmount(0, repayTargetLtv);
        assertGt(repayAmount, 0, "t1: should need to repay some USDT");
        // Approx: targetDebt = 100 WETH × $1,600 × 50 % = 80 k USDT → repay 20 k USDT
        assertApproxEqAbs(repayAmount, 20_000e6, 10, "t1: repayAmount should be ~20 k USDT");

        // Request redemption of matching shares from the vault (1:1 ratio, no yield accrued)
        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        uint256 epochId = 1; // initial epoch from StateInitLib

        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        // ── t2: price stays same; process epoch, claim, repay ────────────────
        // Price stays at $1,600 — no mock change needed.

        // Vault epoch lifecycle: close → process
        _processCurrentEpoch();

        // positionOwner claims their USDT directly from the vault
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = epochId;
        vm.prank(positionOwner);
        targetVault.claimWithdrawal(epochIds);

        assertGe(
            IERC20(USDT).balanceOf(positionOwner), repayAmount, "t2: positionOwner should hold enough USDT to repay"
        );

        // Repay debt via retract (pulls from positionOwner, repays at Aave; no collateral withdrawn)
        vm.prank(operator);
        helper.retract(repayAmount, 0, repayTargetLtv);

        // LTV should now be ~50 %
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), uint256(repayTargetLtv), 1e16, "t2: LTV should be ~50 % after repay"
        );

        // Collateral unchanged; debt reduced
        assertApproxEqAbs(helper.getCollateralAmount(), collateral0, 1e9, "t2: collateral unchanged");
        assertLt(helper.getDebtAmount(), debt0, "t2: debt should have decreased");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. Scenario 3 — 20 % price increase → deploy more capacity
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 3:
    ///
    ///   t0  Same as Scenario 2 t0 (100 WETH, $2,000, 50 % LTV, ~100 k USDT debt).
    ///
    ///   t1  Price rises 20 % to $2,400.
    ///       LTV falls to ~41.7 % (Floor — underleveraged relative to 60 % target).
    ///       Operator borrows the delta required to reach healthyLtv (60 %) and
    ///       deposits it into the target vault (no new collateral supplied).
    function testScenario3_priceIncrease20pct_deployMoreCapacity() public {
        // ── t0: initial position ─────────────────────────────────────────────
        _scenarioSetup();
        _deployAt50Pct();
        uint256 debtT0 = helper.getDebtAmount();

        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), 500_000_000_000_000_000, 1e16, "t0: LTV should be ~50 %"
        );

        // ── t1: price rises 20 % ─────────────────────────────────────────────
        _mockWethPrice(2_400e8); // $2,000 → $2,400

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        // Expected: 50 % × (2000/2400) ≈ 41.7 %
        assertApproxEqAbs(uint256(ltvT1), 416_666_666_666_666_666, 1e16, "t1: LTV should be ~41.7 %");
        assertLt(uint256(ltvT1), uint256(HEALTHY_LTV), "t1: LTV should be below healthyLtv (60 %)");

        // Calculate additional borrow to reach HEALTHY_LTV (60 %)
        // targetDebt = 100 WETH × $2,400 × 60 % = 144 k USDT
        // additionalBorrow = 144 k − 100 k = 44 k USDT
        uint256 collateral = helper.getCollateralAmount();
        uint256 existingDebt = helper.getDebtAmount();
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        uint256 targetDebt = collateral * price / 1e27 * HEALTHY_LTV / WAD;
        uint256 additionalBorrow = targetDebt > existingDebt ? targetDebt - existingDebt : 0;
        assertApproxEqAbs(additionalBorrow, 44_000e6, 10, "t1: additional borrow should be ~44 k USDT");

        uint256 sharesBeforeDeploy = IERC20(address(targetVault)).balanceOf(positionOwner);

        // Borrow the delta and deposit into the vault (no new collateral)
        vm.prank(operator);
        helper.borrow(additionalBorrow); // USDT sent to positionOwner

        vm.prank(operator);
        helper.depositOnTarget(additionalBorrow); // pulls USDT from positionOwner → vault

        // Vault shares increased
        uint256 sharesAfterDeploy = IERC20(address(targetVault)).balanceOf(positionOwner);
        assertGt(sharesAfterDeploy, sharesBeforeDeploy, "t1: vault shares should have increased");

        // LTV ≈ 60 % (HEALTHY_LTV)
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(HEALTHY_LTV),
            1e16,
            "t1: LTV should be ~60 % after deploying more capacity"
        );

        // Debt increased by additionalBorrow
        assertApproxEqAbs(
            helper.getDebtAmount(), debtT0 + additionalBorrow, 10, "t1: debt should have increased by additionalBorrow"
        );

        // Helper holds no residual tokens
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. Scenario 4 — WWL pressure: 10 % drop, withdraw collateral with loan
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Scenario 4:
    ///
    ///   t0  Same as Scenario 2 t0 (100 WETH, $2,000, 50 % LTV, ~100 k USDT debt).
    ///
    ///   t1  Price drops 10 % to $1,800.
    ///       LTV rises to ~55.6 % (above healthyLtv+deviation band).
    ///       positionOwner wants to withdraw collateral worth ~$50 k
    ///       (~27.78 WETH at the new price) while keeping LTV at 50 %.
    ///       calculateTargetRepayAmount(requiredCollateral, 50 %) = ~35 k USDT.
    ///       Operator requests redemption of matching vault shares.
    ///
    ///   t2  Epoch processed; positionOwner claims ~35 k USDT.
    ///       Operator calls retract(35 k, requiredCollateral, 65 %).
    ///       positionOwner receives ~27.78 WETH back; LTV lands at ~50 %.
    function testScenario4_wwlPressure_withdrawCollateralWithLoanRepay() public {
        // ── t0: initial position ─────────────────────────────────────────────
        _scenarioSetup();
        _deployAt50Pct();

        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()), 500_000_000_000_000_000, 1e16, "t0: LTV should be ~50 %"
        );

        // ── t1: price drops 10 % ─────────────────────────────────────────────
        uint256 newWethPrice = 1_800e8; // $2,000 → $1,800
        _mockWethPrice(newWethPrice);

        uint64 ltvT1 = helper.getCurrentLtvInWad();
        // Expected: 50 % × (2000/1800) ≈ 55.6 %
        assertApproxEqAbs(uint256(ltvT1), 555_555_555_555_555_555, 1e16, "t1: LTV should be ~55.6 %");
        // Above HEALTHY_LTV (60%)? No – 55.6% < 60%. But it IS above healthyLower (60%-5%=55%).
        assertGt(
            uint256(ltvT1), uint256(HEALTHY_LTV) - uint256(HEALTHY_LTV_DEVIATION), "t1: LTV should exceed healthyLower"
        );

        // positionOwner wants to withdraw collateral worth ~$50 k at the new price
        // requiredCollateral = $50,000 / $1,800 ≈ 27.78 WETH
        uint256 requiredCollateralWeth = uint256(50_000) * 1e18 / 1800; // ≈ 27.78 WETH

        // Repayment needed to maintain 50 % LTV after withdrawing requiredCollateralWeth
        // Formula: repay = debt − (collateral − R) × price × targetLtv
        //        = 100 k − (100 − 27.78) × $1,800 × 50 % = 100 k − 65 k = 35 k USDT
        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50 %
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredCollateralWeth, repayTargetLtv);
        assertApproxEqAbs(repayAmount, 35_000e6, 10, "t1: repayAmount should be ~35 k USDT");

        // Request redemption of the exact shares needed for repayment (1:1 vault, no yield)
        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        uint256 epochId = 1;

        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(positionOwner);

        // ── t2: process epoch, claim, retract with WWL ───────────────────────
        _processCurrentEpoch();

        // positionOwner claims USDT from the vault
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = epochId;
        vm.prank(positionOwner);
        targetVault.claimWithdrawal(epochIds);

        assertGe(
            IERC20(USDT).balanceOf(positionOwner), repayAmount, "t2: positionOwner should have USDT to cover repayment"
        );

        // Retract: repay debt and withdraw requiredCollateralWeth to positionOwner
        uint64 maxPermissibleLtv = 650_000_000_000_000_000; // 65 %
        vm.prank(operator);
        helper.retract(repayAmount, requiredCollateralWeth, maxPermissibleLtv);

        // positionOwner received ~27.78 WETH (collateral withdrawn)
        uint256 wethReceived = IERC20(WETH).balanceOf(positionOwner) - wethBalanceBefore;
        assertApproxEqAbs(wethReceived, requiredCollateralWeth, 1e15, "t2: positionOwner should receive ~27.78 WETH");

        // LTV should be ~50 % after repay + withdrawal
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(repayTargetLtv),
            1e16,
            "t2: LTV should be ~50 % after WWL retract"
        );

        // Remaining collateral ≈ 100 − 27.78 = 72.22 WETH
        assertApproxEqAbs(
            helper.getCollateralAmount(),
            100 ether - requiredCollateralWeth,
            1e15,
            "t2: remaining collateral should be ~72.22 WETH"
        );

        // Helper holds no residual tokens
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 13. retract — unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev retract(0, withdrawalAmount, maxLtv) withdraws collateral to positionOwner
    ///      without touching debt when repayAmount is zero.
    function testRetract_whenRepayAmountIsZero() public {
        _scenarioSetup();
        _deployAt50Pct();

        // At 50 % LTV: 100 WETH collateral, ~100 k USDT debt @ $2,000.
        // Withdraw 10 WETH → new collateral = 90 WETH, LTV ≈ 100k / 180k ≈ 55.6 % < 60 %.
        uint256 withdrawAmount = 10 ether;
        uint64 maxPermissibleLtv = 600_000_000_000_000_000; // 60 %

        uint256 collateralBefore = helper.getCollateralAmount();
        uint256 debtBefore = helper.getDebtAmount();
        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);

        vm.prank(operator);
        helper.retract(0, withdrawAmount, maxPermissibleLtv);

        assertApproxEqAbs(
            helper.getCollateralAmount(),
            collateralBefore - withdrawAmount,
            1e15,
            "collateral should decrease by withdrawAmount"
        );
        assertApproxEqAbs(helper.getDebtAmount(), debtBefore, 10, "debt should be unchanged");
        assertApproxEqAbs(
            IERC20(WETH).balanceOf(positionOwner),
            wethBefore + withdrawAmount,
            1e15,
            "positionOwner should receive WETH"
        );
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    /// @dev retract() reverts when maxPermissibleLtv exceeds the lender's protocol cap.
    function testRetract_revertsWhenMaxPermissibleLtvExceedsLenderMax() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint64 tooHighLtv = 950_000_000_000_000_000; // 95 % — Aave WETH max is ~80 %

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MaxPermissibleLtvExceedsLenderMaxLtv.selector);
        helper.retract(0, 0, tooHighLtv);
    }

    /// @dev retract() reverts when the requested withdrawal would push LTV above maxPermissibleLtv.
    function testRetract_revertsWhenWithdrawalWouldBreachLtv() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Withdraw 80 WETH → 20 WETH remaining vs 100 k USDT debt → LTV ≈ 250 % >> 60 %.
        uint256 tooMuchWithdrawal = 80 ether;
        uint64 maxPermissibleLtv = 600_000_000_000_000_000; // 60 %

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
    // 14. claimAndRetract — unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev claimAndRetract() claims fulfilled vault redemption, pulls USDT from positionOwner,
    ///      and repays Aave debt — collateral is untouched when withdrawalAmount is zero.
    function testClaimAndRetract_repaysDebtFromClaimedShares() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Price drops 20 % → LTV ≈ 62.5 %; repay ~20 k USDT to land at 50 %.
        _mockWethPrice(1_600e8);

        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50 %
        uint256 repayAmount = helper.calculateTargetRepayAmount(0, repayTargetLtv);
        assertApproxEqAbs(repayAmount, 20_000e6, 10, "repayAmount should be ~20 k USDT");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        _processCurrentEpoch(); // epoch 1: USDT claimable for positionOwner

        uint256 debtBefore = helper.getDebtAmount();
        uint256 collateralBefore = helper.getCollateralAmount();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;

        vm.prank(operator);
        helper.claimAndRetract(epochIds, 0, repayTargetLtv);

        assertLt(helper.getDebtAmount(), debtBefore, "debt should have decreased");
        assertApproxEqAbs(helper.getCollateralAmount(), collateralBefore, 1e9, "collateral should be unchanged");
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(repayTargetLtv),
            1e16,
            "LTV should be ~50 % after claimAndRetract"
        );
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }

    /// @dev claimAndRetract() with withdrawalAmount > 0 repays debt and withdraws
    ///      collateral to positionOwner atomically.
    function testClaimAndRetract_repaysAndWithdrawsCollateral() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Price drops 10 % → LTV ≈ 55.6 %.
        _mockWethPrice(1_800e8);

        // positionOwner wants ~27.78 WETH (@$1,800); needs ~35 k USDT repaid.
        uint256 requiredCollateralWeth = uint256(50_000) * 1e18 / 1800;
        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50 %
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredCollateralWeth, repayTargetLtv);
        assertApproxEqAbs(repayAmount, 35_000e6, 10, "repayAmount should be ~35 k USDT");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(sharesToRedeem);

        _processCurrentEpoch(); // epoch 1: USDT claimable for positionOwner

        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 1;

        uint64 maxPermissibleLtv = 650_000_000_000_000_000; // 65 %
        vm.prank(operator);
        helper.claimAndRetract(epochIds, requiredCollateralWeth, maxPermissibleLtv);

        // positionOwner received ~27.78 WETH
        assertApproxEqAbs(
            IERC20(WETH).balanceOf(positionOwner) - wethBefore,
            requiredCollateralWeth,
            1e15,
            "positionOwner should receive ~27.78 WETH"
        );
        // LTV ≈ 50 %
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(repayTargetLtv),
            1e16,
            "LTV should be ~50 % after claimAndRetract with withdrawal"
        );
        // Helper holds no residual tokens
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 15. redeemAndRetract — unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev redeemAndRetract() reverts with QueueIsActive when the target vault queue is on.
    function testRedeemAndRetract_revertsWhenQueueActive() public {
        assertTrue(targetVault.isQueueActive(), "queue should be active by default");

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.QueueIsActive.selector);
        helper.redeemAndRetract(1 ether, 0, 500_000_000_000_000_000);
    }

    /// @dev redeemAndRetract() synchronously redeems vault shares and repays Aave debt
    ///      when the target vault queue is inactive.
    function testRedeemAndRetract_atomicRepayWhenQueueInactive() public {
        _scenarioSetup();
        _deployAt50Pct(); // positionOwner holds vault shares; 100 WETH collateral, ~100 k USDT debt

        // Disable queue → redeem() becomes synchronous.
        vm.prank(vaultManager);
        targetVault.toggleQueueActive();

        // Redeem shares worth ~10 k USDT and repay debt — no collateral withdrawn.
        uint256 redeemUsdt = 10_000e6;
        uint256 sharesToRedeem = targetVault.convertToShares(redeemUsdt);

        uint256 debtBefore = helper.getDebtAmount();
        uint256 collateralBefore = helper.getCollateralAmount();

        vm.prank(operator);
        helper.redeemAndRetract(sharesToRedeem, 0, 500_000_000_000_000_000);

        assertApproxEqAbs(
            helper.getDebtAmount(), debtBefore - redeemUsdt, 10, "debt should decrease by redeemed amount"
        );
        assertApproxEqAbs(helper.getCollateralAmount(), collateralBefore, 1e9, "collateral should be unchanged");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
    }

    /// @dev redeemAndRetract() repays debt and withdraws collateral atomically when queue is inactive.
    function testRedeemAndRetract_atomicRepayAndWithdrawWhenQueueInactive() public {
        _scenarioSetup();
        _deployAt50Pct();

        // Price drops 10 % → LTV ≈ 55.6 %.
        _mockWethPrice(1_800e8);

        // Disable queue for synchronous redemption.
        vm.prank(vaultManager);
        targetVault.toggleQueueActive();

        // Repay amount + withdrawal identical to Scenario 4 (35 k USDT, ~27.78 WETH).
        uint256 requiredCollateralWeth = uint256(50_000) * 1e18 / 1800;
        uint64 repayTargetLtv = 500_000_000_000_000_000; // 50 %
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredCollateralWeth, repayTargetLtv);
        assertApproxEqAbs(repayAmount, 35_000e6, 10, "repayAmount should be ~35 k USDT");

        uint256 sharesToRedeem = targetVault.convertToShares(repayAmount);
        uint256 wethBefore = IERC20(WETH).balanceOf(positionOwner);

        uint64 maxPermissibleLtv = 650_000_000_000_000_000; // 65 %
        vm.prank(operator);
        helper.redeemAndRetract(sharesToRedeem, requiredCollateralWeth, maxPermissibleLtv);

        // positionOwner received ~27.78 WETH
        assertApproxEqAbs(
            IERC20(WETH).balanceOf(positionOwner) - wethBefore,
            requiredCollateralWeth,
            1e15,
            "positionOwner should receive ~27.78 WETH"
        );
        // LTV ≈ 50 %
        assertApproxEqAbs(
            uint256(helper.getCurrentLtvInWad()),
            uint256(repayTargetLtv),
            1e16,
            "LTV should be ~50 % after redeemAndRetract"
        );
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 16. rescueFunds — unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev rescueFunds() transfers a stuck ERC-20 token to the calling admin (msg.sender).
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

    /// @dev rescueFunds() reverts when token is address(0) (ETH rescue not supported).
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
    // 17. updateRedemptionRequestFromTarget — unit tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev updateRedemptionRequestFromTarget() cancels an existing epoch request and replaces it with a new one.
    ///      For ConcreteAsyncVaultImpl, request IDs are epoch IDs.
    function testUpdateRedemptionRequestFromTarget_replacesEpochRequestShares() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 epochId = 1;

        uint256 oldRedeemUsdt = 10_000e6;
        uint256 oldShares = targetVault.convertToShares(oldRedeemUsdt);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(oldShares);

        assertEq(
            targetVault.getUserEpochRequest(positionOwner, epochId), oldShares, "pre: expected old epoch request shares"
        );

        uint256 newRedeemUsdt = 7_000e6;
        uint256 newShares = targetVault.convertToShares(newRedeemUsdt);

        vm.prank(operator);
        helper.updateRedemptionRequestFromTarget(epochId, newShares);

        // If cancel didn't fully clear, we'd see oldShares + newShares (same epoch).
        assertEq(
            targetVault.getUserEpochRequest(positionOwner, epochId),
            newShares,
            "post: expected epoch request shares to be replaced"
        );
    }

    /// @dev updateRedemptionRequestFromTarget() reverts when there is no existing request to cancel.
    function testUpdateRedemptionRequestFromTarget_revertsWhenNoExistingRequest() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 epochId = 1;
        uint256 newShares = targetVault.convertToShares(1_000e6);

        vm.prank(operator);
        vm.expectRevert(); // ConcreteAsyncVaultImpl.NoRequestingShares()
        helper.updateRedemptionRequestFromTarget(epochId, newShares);
    }

    /// @dev updateRedemptionRequestFromTarget() reverts when newSharesAmount is zero.
    function testUpdateRedemptionRequestFromTarget_revertsWhenNewSharesIsZero() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 epochId = 1;
        uint256 oldShares = targetVault.convertToShares(1_000e6);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(oldShares);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.ZeroShares.selector);
        helper.updateRedemptionRequestFromTarget(epochId, 0);
    }

    /// @dev updateRedemptionRequestFromTarget() reverts when called by non-operator.
    function testUpdateRedemptionRequestFromTarget_revertsWhenCalledByNonOperator() public {
        _scenarioSetup();
        _deployAt50Pct();

        uint256 epochId = 1;
        uint256 oldShares = targetVault.convertToShares(1_000e6);
        vm.prank(operator);
        helper.requestRedemptionFromTarget(oldShares);

        uint256 newShares = targetVault.convertToShares(500e6);
        vm.expectRevert();
        helper.updateRedemptionRequestFromTarget(epochId, newShares);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // canLiquidate modifier — access control and LTV gate
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Admin may call selfLiquidate even when the LTV is well below the
    ///      (liqThreshold − selfLiqThrBuffer) trigger. The canLiquidate guard is
    ///      bypassed entirely for POSITION_ADMIN_ROLE. The call proceeds past the
    ///      guard and then fails at the flash module (no liquidity configured),
    ///      proving the guard did not revert.
    function testCanLiquidate_adminBypassesLtvCondition() public {
        _supplyAndBorrow(5 ether, 200e6); // LTV ≈ 60%, well below trigger

        // Verify the operator condition would NOT be met at this LTV.
        uint64 liqThr = helper.getLiquidationThresholdInWad();
        assertLt(
            uint256(helper.getCurrentLtvInWad()) + SELF_LIQ_BUFFER,
            liqThr,
            "test precondition: LTV should be below canLiquidate trigger"
        );

        // Admin passes the guard; fails at flash module (no liquidity cap set).
        // Use bare expectRevert — FlashAmountExceedsLiquidity carries parameters so a
        // selector-only match doesn't work in current Foundry.
        vm.prank(admin);
        vm.expectRevert();
        helper.selfLiquidate(type(uint256).max, SELF_LIQ_BUFFER);
    }

    /// @dev Operator is rejected when the current LTV is below the
    ///      (liqThreshold − selfLiqThrBuffer) trigger.
    function testCanLiquidate_operatorRevertsWhenLtvBelowTrigger() public {
        _supplyAndBorrow(5 ether, 200e6); // LTV ≈ 60%, well below trigger

        uint64 liqThr = helper.getLiquidationThresholdInWad();
        assertLt(
            uint256(helper.getCurrentLtvInWad()) + SELF_LIQ_BUFFER,
            liqThr,
            "test precondition: LTV should be below canLiquidate trigger"
        );

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.NeitherAdminNorOperatorWithinPermissibleLtv.selector, operator)
        );
        helper.selfLiquidate(type(uint256).max, SELF_LIQ_BUFFER);
    }

    /// @dev Operator may call selfLiquidate when the LTV is at or above the
    ///      (liqThreshold − selfLiqThrBuffer) trigger. The call proceeds past the
    ///      guard and fails at the flash module, proving the guard passed.
    function testCanLiquidate_operatorAllowedWhenLtvAboveTrigger() public {
        // Borrow up to (liqThreshold − buffer + 0.5%) to sit just above the trigger.
        uint64 liqThr = helper.getLiquidationThresholdInWad();
        uint256 targetLtvInWad = uint256(liqThr) - SELF_LIQ_BUFFER + 5e15; // +0.5%

        uint256 supplyAmount = 10 ether;
        uint256 price = helper.collateralPriceInBorrowTokensInRay();
        uint256 collateralValue = (supplyAmount * price) / RAY;
        uint256 borrowAmount = (collateralValue * targetLtvInWad) / WAD;

        deal(WETH, positionOwner, supplyAmount);
        _setupOwnerApprovals();
        _supplyAndBorrow(supplyAmount, borrowAmount);

        // Verify the LTV condition is now met.
        assertGe(
            uint256(helper.getCurrentLtvInWad()) + SELF_LIQ_BUFFER,
            liqThr,
            "test precondition: LTV should be at or above canLiquidate trigger"
        );

        // Operator passes the guard; fails at flash module (no liquidity cap set).
        vm.prank(operator);
        vm.expectRevert();
        helper.selfLiquidate(type(uint256).max, SELF_LIQ_BUFFER);
    }

    /// @dev Any address holding neither POSITION_ADMIN_ROLE nor POSITION_OPERATOR_ROLE
    ///      is always rejected by the canLiquidate guard regardless of LTV.
    function testCanLiquidate_strangerAlwaysReverts() public {
        _supplyAndBorrow(5 ether, 200e6);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionHelperBase.NeitherAdminNorOperatorWithinPermissibleLtv.selector, stranger)
        );
        helper.selfLiquidate(type(uint256).max, SELF_LIQ_BUFFER);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 18. LTV parameter setters
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev setHealthyLtvInWad() updates storage and emits HealthyLtvUpdated.
    function testSetHealthyLtvInWad_updatesStorageAndEmitsEvent() public {
        assertEq(helper.healthyLtvInWad(), HEALTHY_LTV, "initial healthyLtvInWad should match setUp value");

        uint64 newValue = 700_000_000_000_000_000; // 70%

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.HealthyLtvUpdated(HEALTHY_LTV, newValue);

        vm.prank(admin);
        helper.setHealthyLtvInWad(newValue);

        assertEq(helper.healthyLtvInWad(), newValue, "healthyLtvInWad should reflect new value");
    }

    /// @dev setHealthyLtvInWad() reverts when caller lacks admin role.
    function testSetHealthyLtvInWad_revertsOnInvalidInputs() public {
        vm.expectRevert(); // AccessControl: missing role
        helper.setHealthyLtvInWad(500_000_000_000_000_000);
    }

    /// @dev setHealthyLtvDeviationInWad() updates storage and emits HealthyLtvDeviationUpdated.
    function testSetHealthyLtvDeviationInWad_updatesStorageAndEmitsEvent() public {
        assertEq(
            helper.healthyLtvDeviationInWad(),
            HEALTHY_LTV_DEVIATION,
            "initial healthyLtvDeviationInWad should match setUp value"
        );

        uint64 newValue = 30_000_000_000_000_000; // 3%

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.HealthyLtvDeviationUpdated(HEALTHY_LTV_DEVIATION, newValue);

        vm.prank(admin);
        helper.setHealthyLtvDeviationInWad(newValue);

        assertEq(helper.healthyLtvDeviationInWad(), newValue, "healthyLtvDeviationInWad should reflect new value");
    }

    /// @dev setHealthyLtvDeviationInWad() reverts when caller lacks admin role.
    function testSetHealthyLtvDeviationInWad_revertsOnInvalidInputs() public {
        vm.expectRevert(); // AccessControl: missing role
        helper.setHealthyLtvDeviationInWad(30_000_000_000_000_000);
    }

    /// @dev setSelfLiqThrBufferInWad() updates storage and emits SelfLiqThrBufferUpdated.
    function testSetSelfLiqThrBufferInWad_updatesStorageAndEmitsEvent() public {
        assertEq(
            helper.selfLiqThrBufferInWad(), SELF_LIQ_BUFFER, "initial selfLiqThrBufferInWad should match setUp value"
        );

        uint64 newValue = 20_000_000_000_000_000; // 2%

        vm.expectEmit(false, false, false, true, address(helper));
        emit IPositionHelperBase.SelfLiqThrBufferUpdated(SELF_LIQ_BUFFER, newValue);

        vm.prank(admin);
        helper.setSelfLiqThrBufferInWad(newValue);

        assertEq(helper.selfLiqThrBufferInWad(), newValue, "selfLiqThrBufferInWad should reflect new value");
    }

    /// @dev setSelfLiqThrBufferInWad() reverts when caller lacks admin role.
    function testSetSelfLiqThrBufferInWad_revertsOnInvalidInputs() public {
        vm.expectRevert(); // AccessControl: missing role
        helper.setSelfLiqThrBufferInWad(20_000_000_000_000_000);
    }

    /// @dev setSelfLiqThrBufferInWad(0) reverts with InvalidSelfLiqThrBufferInWad: a positive
    ///      self-liquidation buffer is required so the operator keeps a preemptive margin below
    ///      the lender liquidation threshold.
    function testSetSelfLiqThrBufferInWad_revertsWhenZero() public {
        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.InvalidSelfLiqThrBufferInWad.selector);
        helper.setSelfLiqThrBufferInWad(0);

        assertEq(helper.selfLiqThrBufferInWad(), SELF_LIQ_BUFFER, "buffer must remain unchanged after revert");
    }

    /// @dev setHealthyLtvDeviationInWad(0) reverts with InvalidLtvRange carrying all four params.
    function testSetHealthyLtvDeviationInWad_revertsWhenZero() public {
        uint64 liqThr = helper.getLiquidationThresholdInWad();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPositionHelperBase.InvalidLtvRange.selector, HEALTHY_LTV, uint64(0), SELF_LIQ_BUFFER, liqThr
            )
        );
        helper.setHealthyLtvDeviationInWad(0);
    }

    /// @dev setHealthyLtvInWad() reverts with InvalidLtvRange when the new healthy LTV pushes
    ///      the upper band (healthyLtv + deviation + buffer) to meet the lender liq threshold.
    function testSetHealthyLtvInWad_revertsOnCollisionWithLiqThreshold() public {
        uint64 liqThr = helper.getLiquidationThresholdInWad();
        // At this value: healthyLtv + deviation + buffer == liqThr, so selfLiqThreshold == healthyUpper.
        uint64 collidingLtv = uint64(uint256(liqThr) - HEALTHY_LTV_DEVIATION - SELF_LIQ_BUFFER);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPositionHelperBase.InvalidLtvRange.selector,
                collidingLtv,
                HEALTHY_LTV_DEVIATION,
                SELF_LIQ_BUFFER,
                liqThr
            )
        );
        helper.setHealthyLtvInWad(collidingLtv);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // onlySingleCollateralPosition guard — multi-collateral / multi-debt
    // ─────────────────────────────────────────────────────────────────────────

    // Second collateral/debt reserves used purely to exercise the guard — distinct from
    // COLLATERAL_TOKEN (WETH) and BORROW_TOKEN (USDT).
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Supplies `amount` of `token` directly to Aave on behalf of `user`, bypassing the
    ///      helper entirely — models positionOwner holding an out-of-band Aave position.
    function _supplyDirectlyToAave(address token, address user, uint256 amount) internal {
        deal(token, user, amount);
        vm.startPrank(user);
        IERC20(token).forceApprove(address(helper.POOL()), amount);
        IPool(address(helper.POOL())).supply(token, amount, user, 0);
        vm.stopPrank();
    }

    /// @dev Borrows `amount` of `token` directly from Aave on behalf of `user`, bypassing the
    ///      helper. No credit delegation is needed since onBehalfOf == msg.sender.
    function _borrowDirectlyFromAave(address token, address user, uint256 amount) internal {
        address pool = address(helper.POOL()); // cache before vm.prank — helper.POOL() is an external call
        vm.prank(user);
        IPool(pool).borrow(token, amount, VARIABLE_RATE, 0, user);
    }

    /// @dev deploy() reverts once positionOwner has a second active Aave collateral reserve
    ///      (supplied directly, outside the helper) alongside WETH.
    function testDeploy_revertsWhenPositionOwnerHasMultipleCollateralReserves() public {
        _supply(1 ether);
        _supplyDirectlyToAave(WBTC, positionOwner, 1e8);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.deploy(0, HEALTHY_LTV);
    }

    /// @dev deploy() reverts when positionOwner's sole active collateral reserve is not
    ///      COLLATERAL_TOKEN (reserve count == 1, but wrong identity).
    function testDeploy_revertsWhenSoleCollateralReserveIsNotCollateralToken() public {
        _supplyDirectlyToAave(WBTC, positionOwner, 1e8);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.deploy(0, HEALTHY_LTV);
    }

    /// @dev deploy() reverts once positionOwner is borrowing a second Aave asset directly,
    ///      alongside USDT.
    function testDeploy_revertsWhenPositionOwnerHasMultipleDebtReserves() public {
        _supplyAndBorrow(100 ether, 10_000e6);
        _borrowDirectlyFromAave(USDC, positionOwner, 1_000e6);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleDebtReservesDetected.selector);
        helper.deploy(0, HEALTHY_LTV);
    }

    /// @dev deploy() reverts when positionOwner's sole active debt reserve is not
    ///      BORROW_TOKEN (reserve count == 1, but wrong identity).
    function testDeploy_revertsWhenSoleDebtReserveIsNotBorrowToken() public {
        _supply(100 ether);
        _borrowDirectlyFromAave(USDC, positionOwner, 1_000e6);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleDebtReservesDetected.selector);
        helper.deploy(0, HEALTHY_LTV);
    }

    /// @dev retract() reverts once a second collateral reserve is active alongside WETH.
    function testRetract_revertsWhenPositionOwnerHasMultipleCollateralReserves() public {
        _scenarioSetup();
        _deployAt50Pct();
        _supplyDirectlyToAave(WBTC, positionOwner, 1e8);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.retract(0, 0, HEALTHY_LTV);
    }

    /// @dev claimAndRetract() reverts once a second collateral reserve is active — the guard
    ///      fires before any redemption claim is attempted.
    function testClaimAndRetract_revertsWhenPositionOwnerHasMultipleCollateralReserves() public {
        _scenarioSetup();
        _deployAt50Pct();
        _supplyDirectlyToAave(WBTC, positionOwner, 1e8);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.claimAndRetract(new uint256[](0), 0, HEALTHY_LTV);
    }

    /// @dev redeemAndRetract() reverts once a second collateral reserve is active — the guard
    ///      fires before the QueueIsActive check.
    function testRedeemAndRetract_revertsWhenPositionOwnerHasMultipleCollateralReserves() public {
        _scenarioSetup();
        _deployAt50Pct();
        _supplyDirectlyToAave(WBTC, positionOwner, 1e8);

        vm.prank(operator);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.redeemAndRetract(1, 0, HEALTHY_LTV);
    }

    /// @dev selfLiquidate() reverts once a second collateral reserve is active — the guard
    ///      fires before the NoDebt check. Uses admin to bypass the canLiquidate LTV gate.
    function testSelfLiquidate_revertsWhenPositionOwnerHasMultipleCollateralReserves() public {
        _scenarioSetup();
        _deployAt50Pct();
        _supplyDirectlyToAave(WBTC, positionOwner, 1e8);

        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.selfLiquidate(0, SELF_LIQ_BUFFER);
    }

    /// @dev selfLiquidateToLtv() reverts once a second collateral reserve is active — the guard
    ///      fires before the NoDebt / TargetLtvTooHigh checks. Uses admin to bypass canLiquidate.
    function testSelfLiquidateToLtv_revertsWhenPositionOwnerHasMultipleCollateralReserves() public {
        _scenarioSetup();
        _deployAt50Pct();
        _supplyDirectlyToAave(WBTC, positionOwner, 1e8);

        vm.prank(admin);
        vm.expectRevert(IPositionHelperBase.MultipleCollateralReservesDetected.selector);
        helper.selfLiquidateToLtv(400_000_000_000_000_000, SELF_LIQ_BUFFER);
    }
}
