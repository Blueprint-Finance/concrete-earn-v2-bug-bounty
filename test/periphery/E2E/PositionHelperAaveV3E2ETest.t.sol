// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

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

// ── Subject under test ────────────────────────────────────────────────────────
import {PositionHelperAaveV3} from "../../../src/periphery/positionhelper/PositionHelperAaveV3.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";
import {MockFlashModule} from "../mock/MockFlashModule.sol";
import {MockSwapper} from "../mock/MockSwapper.sol";

/// @title  PositionHelperAaveV3E2ETest
/// @notice End-to-end test where `positionOwner` is itself a ConcreteAsyncVaultImpl
///         (WETH vault, called `outerVault`).  The test demonstrates the full WWL
///         cascade:
///           user redeems outerVault shares
///             → allocator requests stableVault redemption
///               → stableVault epoch processed → USDT back to outerVault
///                 → allocator retracts (Aave repay + WETH to outerVault)
///                   → outerVault epoch processed → user receives WETH
contract PositionHelperAaveV3E2ETest is Test {
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
    uint64 internal constant HEALTHY_LTV = 600_000_000_000_000_000; // 60%
    uint64 internal constant HEALTHY_LTV_DEVIATION = 50_000_000_000_000_000; // 5%
    uint64 internal constant SELF_LIQ_BUFFER = 50_000_000_000_000_000; // 5%
    uint64 internal constant TARGET_LTV = 500_000_000_000_000_000; // 50%
    uint64 internal constant MAX_PERMISSIBLE_LTV = 650_000_000_000_000_000; // 65%

    // ── Oracle prices ─────────────────────────────────────────────────────────
    uint256 internal constant WETH_PRICE_T0 = 2_000e8;
    uint256 internal constant WETH_PRICE_T1 = 1_800e8; // 10% drop
    uint256 internal constant USDT_PRICE = 1e8;

    // ── Contracts ─────────────────────────────────────────────────────────────
    PositionHelperAaveV3 internal implementation;
    PositionHelperAaveV3 internal helper;
    ConcreteAsyncVaultImpl internal outerVault; // WETH vault — positionOwner
    ConcreteAsyncVaultImpl internal stableVault; // USDT vault — helper target

    // ── Actors ────────────────────────────────────────────────────────────────
    address internal outerVaultAdmin;
    address internal outerVaultManager;
    address internal stableVaultAdmin;
    address internal stableVaultManager;
    address internal helperAdmin;
    address internal allocator; // POSITION_OPERATOR_ROLE on helper
    MockFlashModule internal flashModule;
    MockSwapper internal swapModule;
    address internal user; // deposits WETH into outerVault

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        // ── Actors ────────────────────────────────────────────────────────────
        outerVaultAdmin = makeAddr("e2e_outerVaultAdmin");
        outerVaultManager = makeAddr("e2e_outerVaultManager");
        stableVaultAdmin = makeAddr("e2e_stableVaultAdmin");
        stableVaultManager = makeAddr("e2e_stableVaultManager");
        helperAdmin = makeAddr("e2e_helperAdmin");
        allocator = makeAddr("e2e_allocator");
        flashModule = new MockFlashModule(makeAddr("e2e_flashModuleAdmin"), 0);
        swapModule = new MockSwapper(makeAddr("e2e_swapModuleAdmin"));
        user = makeAddr("e2e_user");

        // ── Deploy factory ────────────────────────────────────────────────────
        address factoryOwner = makeAddr("e2e_factoryOwner");
        address managementFeeRecipient = makeAddr("e2e_managementFeeRecipient");
        address performanceFeeRecipient = makeAddr("e2e_performanceFeeRecipient");
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

        // ── Deploy outerVault (WETH asset) ────────────────────────────────────
        outerVault = ConcreteAsyncVaultImpl(
            factory.create(
                vaultImpl,
                outerVaultAdmin,
                abi.encode(address(allocateModule), WETH, outerVaultManager, "E2E Outer WETH Vault", "e2eWETH")
            )
        );

        // ── Deploy stableVault (USDT asset) ───────────────────────────────────
        stableVault = ConcreteAsyncVaultImpl(
            factory.create(
                vaultImpl,
                stableVaultAdmin,
                abi.encode(address(allocateModule), USDT, stableVaultManager, "E2E Stable USDT Vault", "e2eUSDT")
            )
        );

        // ── Deploy PositionHelperAaveV3 implementation ────────────────────────
        implementation = new PositionHelperAaveV3(AAVE_DATA_PROVIDER);

        // ── Clone with outerVault as positionOwner ────────────────────────────
        bytes memory cloneArgs = abi.encodePacked(address(outerVault), WETH, USDT, WETH_DECIMALS, USDT_DECIMALS);
        helper = PositionHelperAaveV3(ClonesWithImmutableArgs.clone(address(implementation), cloneArgs));

        // ── Initialize clone ──────────────────────────────────────────────────
        helper.initialize(
            helperAdmin,
            allocator,
            address(stableVault),
            address(flashModule),
            address(swapModule),
            HEALTHY_LTV,
            HEALTHY_LTV_DEVIATION,
            SELF_LIQ_BUFFER
        );

        // ── Grant helper WITHDRAWAL_MANAGER on stableVault ────────────────────
        vm.prank(stableVaultManager);
        stableVault.grantRole(RolesLib.WITHDRAWAL_MANAGER, address(helper));

        // ── Approvals: outerVault → helper ────────────────────────────────────
        address pool = address(helper.POOL());
        address aToken = IPool(pool).getReserveData(WETH).aTokenAddress;
        address debtToken = IPool(pool).getReserveData(USDT).variableDebtTokenAddress;

        vm.startPrank(address(outerVault));
        IERC20(WETH).approve(address(helper), type(uint256).max);
        IERC20(aToken).approve(address(helper), type(uint256).max);
        IERC20(USDT).forceApprove(address(helper), type(uint256).max);
        ICreditDelegationToken(debtToken).approveDelegation(address(helper), type(uint256).max);
        IERC20(address(stableVault)).approve(address(helper), type(uint256).max);
        vm.stopPrank();

        // ── Labels ────────────────────────────────────────────────────────────
        vm.label(WETH, "WETH");
        vm.label(USDT, "USDT");
        vm.label(address(outerVault), "outerVault");
        vm.label(address(stableVault), "stableVault");
        vm.label(allocator, "allocator");
        vm.label(user, "user");
        vm.label(address(helper), "PositionHelper(e2e)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _mockPrices(uint256 wethPrice) internal {
        address oracle = address(helper.PRICE_ORACLE());
        vm.mockCall(
            oracle, abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, WETH), abi.encode(wethPrice)
        );
        vm.mockCall(
            oracle, abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, USDT), abi.encode(USDT_PRICE)
        );
    }

    function _grantWithdrawalManager(ConcreteAsyncVaultImpl vault, address vaultMgr, address account) internal {
        vm.prank(vaultMgr);
        vault.grantRole(RolesLib.WITHDRAWAL_MANAGER, account);
    }

    function _processEpoch(ConcreteAsyncVaultImpl vault, address vaultMgr) internal {
        _grantWithdrawalManager(vault, vaultMgr, vaultMgr);
        vm.prank(vaultMgr);
        vault.closeEpoch();
        vm.prank(vaultMgr);
        vault.processEpoch();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // E2E Test
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Full WWL cascade where outerVault is the positionOwner:
    ///       1. user deposits 100 WETH → outerVault
    ///       2. allocator deploys (supply WETH to Aave, borrow USDT, deposit to stableVault) at 50% LTV
    ///       3. price drops 10% (2000→1800), LTV rises to ~55.6%
    ///       4. user redeems ~27.78 WETH worth of outerVault shares (WWL on outerVault epoch 1)
    ///       5. allocator requests stableVault redemption for 35k USDT (WWL on stableVault epoch 1)
    ///       6. stableVault epoch 1 processed; outerVault claims 35k USDT
    ///       7. allocator retracts (repays 35k USDT to Aave, withdraws ~27.78 WETH to outerVault, maxLtv 65%), LTV ~50%
    ///       8. outerVault epoch 1 processed; user claims ~27.78 WETH
    function testE2E_wwlCascadesToStableVault() public {
        _mockPrices(WETH_PRICE_T0);

        // ── Step 1: user deposits 100 WETH into outerVault ───────────────────
        deal(WETH, user, 100 ether);
        vm.startPrank(user);
        IERC20(WETH).approve(address(outerVault), type(uint256).max);
        uint256 outerShares = outerVault.deposit(100 ether, user);
        vm.stopPrank();

        assertEq(outerShares, 100 ether, "s1: user should receive 100e18 outerVault shares");
        assertEq(IERC20(WETH).balanceOf(address(outerVault)), 100 ether, "s1: outerVault holds 100 WETH");

        // ── Step 2: allocator deploys (supply → borrow → stableVault deposit) at 50% LTV ──
        vm.prank(allocator);
        helper.deploy(100 ether, TARGET_LTV);

        assertApproxEqAbs(helper.getCollateralAmount(), 100 ether, 1e15, "s2: collateral ~100 WETH");
        assertApproxEqAbs(helper.getDebtAmount(), 100_000e6, 100, "s2: debt ~100k USDT");
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(TARGET_LTV), 1e16, "s2: LTV ~50%");
        assertGt(
            IERC20(address(stableVault)).balanceOf(address(outerVault)), 0, "s2: outerVault holds stableVault shares"
        );

        // ── Step 3: price drops 10% (2000→1800), LTV rises to ~55.6% ─────────
        _mockPrices(WETH_PRICE_T1);

        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), 555_555_555_555_555_555, 1e16, "s3: LTV ~55.6%");

        // ── Step 4: user redeems ~27.78 WETH worth of outerVault shares ───────
        // requiredCollateralWeth = $50,000 / $1,800 ≈ 27.78 WETH
        uint256 requiredCollateralWeth = uint256(50_000) * 1e18 / 1800;

        // At 1:1 share price (100 WETH deposited → 100e18 shares), share = WETH 1:1.
        vm.prank(user);
        outerVault.redeem(requiredCollateralWeth, user, user);

        // Shares burned immediately; redemption queued in outerVault epoch 1.
        assertEq(
            IERC20(address(outerVault)).balanceOf(user),
            outerShares - requiredCollateralWeth,
            "s4: user shares reduced by redeemed amount"
        );

        // ── Step 5: allocator requests stableVault redemption (35k USDT) ─────
        // repayAmount = debt − (collateral − R) × price × targetLtv
        //             = 100k − (100 − 27.78) × 1800 × 50% = 100k − 65k = 35k USDT
        uint256 repayAmount = helper.calculateTargetRepayAmount(requiredCollateralWeth, TARGET_LTV);
        assertApproxEqAbs(repayAmount, 35_000e6, 100, "s5: repayAmount ~35k USDT");

        uint256 stableShares = stableVault.convertToShares(repayAmount);
        vm.prank(allocator);
        helper.requestRedemptionFromTarget(stableShares);

        // ── Step 6: stableVault epoch 1 processed; outerVault claims USDT ─────
        _processEpoch(stableVault, stableVaultManager);

        uint256[] memory stableEpochIds = new uint256[](1);
        stableEpochIds[0] = 1;
        vm.prank(address(outerVault));
        stableVault.claimWithdrawal(stableEpochIds);

        assertGe(IERC20(USDT).balanceOf(address(outerVault)), repayAmount, "s6: outerVault holds USDT for repayment");

        // ── Step 7: allocator retracts → repay Aave debt, withdraw WETH to outerVault ──
        vm.prank(allocator);
        helper.retract(repayAmount, requiredCollateralWeth, MAX_PERMISSIBLE_LTV);

        assertApproxEqAbs(
            IERC20(WETH).balanceOf(address(outerVault)),
            requiredCollateralWeth,
            1e15,
            "s7: outerVault holds ~27.78 WETH"
        );
        assertApproxEqAbs(uint256(helper.getCurrentLtvInWad()), uint256(TARGET_LTV), 1e16, "s7: LTV ~50% after retract");

        // ── Step 8: outerVault epoch 1 processed; user claims WETH ───────────
        _processEpoch(outerVault, outerVaultManager);

        uint256 userWethBefore = IERC20(WETH).balanceOf(user);
        uint256[] memory outerEpochIds = new uint256[](1);
        outerEpochIds[0] = 1;
        vm.prank(user);
        outerVault.claimWithdrawal(outerEpochIds);

        uint256 userWethReceived = IERC20(WETH).balanceOf(user) - userWethBefore;
        assertApproxEqAbs(userWethReceived, requiredCollateralWeth, 1e15, "s8: user receives ~27.78 WETH");

        // Cascade complete — helper holds no residual tokens
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0, "helper must hold no WETH");
        assertEq(IERC20(USDT).balanceOf(address(helper)), 0, "helper must hold no USDT");
    }
}
