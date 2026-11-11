// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AddStrategyWithDeallocationOrder} from "../../common/AddStrategyWithDeallocationOrder.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAllocateModule} from "../../../src/interface/IAllocateModule.sol";
import {LenderModuleAaveV3} from "../../../src/periphery/auxiliary/LenderModuleAaveV3.sol";
import {FlashModuleAaveV3} from "../../../src/periphery/auxiliary/FlashModuleAaveV3.sol";
import {SwapModuleUniV3} from "../../../src/periphery/auxiliary/SwapModuleUniV3.sol";
import {ConcreteStandardLoopingStrategy} from "../../../src/periphery/strategies/ConcreteStandardLoopingStrategy.sol";
// Concrete standard vault implementation
import {ConcreteStandardVaultImpl} from "../../../src/implementation/ConcreteStandardVaultImpl.sol";
// concrete factory implementation
import {ConcreteFactory} from "../../../src/factory/ConcreteFactory.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../../src/lib/Roles.sol";
import {console2 as console} from "forge-std/console2.sol";
import {WAD, RAY} from "../../../src/periphery/lib/Constants.sol";
import {IFlashModule} from "../../../src/periphery/interface/IFlashModule.sol";
import {LoopingPrimitiveLib} from "../../../src/periphery/lib/Looping/LoopingPrimitiveLib.sol";
import {ILenderModule} from "../../../src/periphery/interface/ILenderModule.sol";
import {IBaseLoopingStrategy, PreviewOperationResult} from "../../../src/periphery/interface/IBaseLoopingStrategy.sol";
import {LeverageData} from "../../../src/periphery/interface/ILoopingPrimitive.sol";
import {LeverageOperation} from "../../../src/periphery/lib/Looping/LoopModalityLib.sol";

contract LoopingStrategyE2EForkTest is Test, AddStrategyWithDeallocationOrder {
    //     // ======== mainnet addresses ========
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant AAVE_V3_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;
    address internal constant AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant WETH_USDC_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;
    address internal constant FACTORY = 0x0265d73a8E61F698d8EB0dfeb91Ddce55516844C;
    address internal constant ALLOCATE_MODULE = 0x14A905158aebcb44451857603006a7dc23B0D014;

    address public vaultadmin;
    address public alice;
    SwapModuleUniV3 public swapper;
    FlashModuleAaveV3 public flashModule;
    LenderModuleAaveV3 public lenderModule;
    ConcreteStandardVaultImpl public vault;
    ConcreteFactory public factory;
    ConcreteStandardLoopingStrategy public strategy;
    uint8 public constant STABLE_RATE_MODE = 1;
    uint8 public constant VARIABLE_RATE_MODE = 2;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, 23800000);
        vm.selectFork(forkId);

        vaultadmin = makeAddr("admin");
        alice = address(0xa11ce);
        swapper = new SwapModuleUniV3(ISwapRouter(UNISWAP_V3_ROUTER), WETH, USDC, address(0), 100, 0); // 0xe0554a476a092703abdb3ef35c80e0d76d32939f
        flashModule = new FlashModuleAaveV3(AAVE_V3_POOL_ADDRESSES_PROVIDER);
        address lenderModuleImpl = address(new LenderModuleAaveV3(WETH, USDC, AAVE_V3_DATA_PROVIDER));
        lenderModule = LenderModuleAaveV3(
            address(
                new ERC1967Proxy(
                    lenderModuleImpl,
                    abi.encodeWithSelector(LenderModuleAaveV3.initialize.selector, address(this), VARIABLE_RATE_MODE)
                )
            )
        );
        factory = ConcreteFactory(FACTORY);
        vault = ConcreteStandardVaultImpl(
            factory.create(
                1,
                vaultadmin,
                abi.encode(ALLOCATE_MODULE, WETH, vaultadmin, "Concrete Looping Strategy Vault", "CLSVault")
            )
        );
        address loopingStrategyImpl = address(new ConcreteStandardLoopingStrategy());
        // update the
        strategy = ConcreteStandardLoopingStrategy(
            address(
                new ERC1967Proxy(
                    loopingStrategyImpl,
                    abi.encodeWithSelector(
                        ConcreteStandardLoopingStrategy.initialize.selector,
                        address(this),
                        address(vault),
                        address(lenderModule),
                        address(0) // timelock_ (no timelock at deploy time)
                    )
                )
            )
        );
        // add strategy to lender module
        lenderModule.setStrategy(address(strategy));
        // add strategy to vault and grant roles to address(this)
        vm.startPrank(vaultadmin);
        vault.grantRole(RolesLib.ALLOCATOR, address(this));
        vault.grantRole(RolesLib.STRATEGY_MANAGER, address(this));
        vm.stopPrank();
        addStrategyWithDeallocationOrder(address(strategy), address(vault), address(this), address(this));

        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(vaultadmin, "vaultadmin");
        vm.label(alice, "alice");
        vm.label(address(swapper), "SwapModuleUniV3");
        vm.label(address(UNISWAP_V3_ROUTER), "UniswapV3Router");
        vm.label(WETH_USDC_POOL, "WETH_USDC_POOL");
        vm.label(address(strategy), "ConcreteStandardLoopingStrategy");
        vm.label(address(lenderModule), "LenderModuleAaveV3");
        vm.label(address(flashModule), "FlashModuleAaveV3");
        vm.label(address(vault), "ConcreteStandardVaultImpl");
        vm.label(address(factory), "ConcreteFactory");
        vm.label(address(ALLOCATE_MODULE), "AllocateModule");
    }

    function testPriceOracle() public {
        // lenderModule.collateralPriceInBorrowTokensInRay()
        uint256 price = lenderModule.collateralPriceInBorrowTokensInRay();
        console.log("Price of WETH in USDC in RAY", price);
        console.log("Price of WETH in USDC in USD", price / RAY);
    }

    function testE2ELoopingAllocateFundsAndDeallocateFunds() public {
        // deal some weth to alice
        deal(WETH, alice, 10 ether);
        _depositAsUser(alice, 10 ether);
        // allocate funds into strategy
        _allocateToStrategy(address(this), address(strategy), 10 ether);
        assertApproxEqAbs(
            strategy.totalAllocatedValue(), 10 ether, 10, "total allocated value mismatch after allocation"
        );
        assertApproxEqAbs(vault.totalAssets(), 10 ether, 10, "total assets mismatch after allocation");
        assertEq(vault.totalSupply(), 10 ether, "total supply mismatch after allocation");

        // deallocate max
        _deallocateFromStrategy(address(this), address(strategy), type(uint256).max);
        assertEq(strategy.totalAllocatedValue(), 0, "total allocated value mismatch after deallocation");
        assertApproxEqAbs(vault.totalAssets(), 10 ether, 10, "total assets mismatch after deallocation");
        assertEq(vault.totalSupply(), 10 ether, "total supply mismatch after deallocation");
    }

    function testE2ELoopingEnableLoopingAndWindUpPosition() public {
        deal(WETH, alice, 10 ether);
        _depositAsUser(alice, 10 ether);
        // allocate funds into strategy
        _allocateToStrategy(address(this), address(strategy), 10 ether);
        // enable looping
        uint64 targetLtvInWad = uint64(5 * WAD / 10); // = 50%
        uint256 flashCollateralEpsilon = 0.00001 ether; // 0.1 ether = 300 USD, 0.01 ether = 30 USD, 0.001 ether = 3 USD, 0.0001 ether = 0.3 USD, 0.00001 ether = 0.03 USD
        uint64 ltvAdditiveDeviationInWad = uint64(3 * WAD / 100); // = 3%
        uint64 maxSlippageInWad = uint64(2 * WAD / 10000); // = 0.02%
        bool permissionedLtvAdjustment = false;
        strategy.enableLooping(
            address(flashModule),
            address(swapper),
            targetLtvInWad,
            flashCollateralEpsilon,
            ltvAdditiveDeviationInWad,
            maxSlippageInWad,
            permissionedLtvAdjustment
        );

        // assert that looping is enabled
        assertEq(strategy.loopingIsEnabled(), true, "looping is not enabled");
        assertEq(uint256(strategy.getTargetLtvInWad()), uint256(targetLtvInWad), "target ltv mismatch");
        assertEq(
            uint256(strategy.getLtvAdditiveDeviationInWad()),
            uint256(ltvAdditiveDeviationInWad),
            "ltv additive deviation mismatch"
        );
        assertEq(uint256(strategy.getMaxSlippageInWad()), uint256(maxSlippageInWad), "max slippage mismatch");
    }

    function testE2EfirstEnableLoopingAndWindUpAndDeallocateMax() public {
        deal(WETH, alice, 10 ether);
        _depositAsUser(alice, 10 ether);
        _allocateToStrategy(address(this), address(strategy), 10 ether);

        // enable looping
        uint64 targetLtvInWad = uint64(5 * WAD / 10); // = 50%
        uint256 flashCollateralEpsilon = 0.00001 ether; // 0.1 ether = 300 USD, 0.01 ether = 30 USD, 0.001 ether = 3 USD, 0.0001 ether = 0.3 USD, 0.00001 ether = 0.03 USD
        uint64 ltvAdditiveDeviationInWad = uint64(3 * WAD / 100); // = 3%
        uint64 maxSlippageInWad = uint64(80 * WAD / 10000); // = 0.8%
        strategy.enableLooping(
            address(flashModule),
            address(swapper),
            targetLtvInWad,
            flashCollateralEpsilon,
            ltvAdditiveDeviationInWad,
            maxSlippageInWad,
            false // permissionedLtvAdjustment = false
        );
        uint256 positionValue = strategy.totalAllocatedValue();
        // preview the flash quote
        (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        ) = strategy.previewOperation(0, true, targetLtvInWad, maxSlippageInWad);

        console.log("cost", result.maximumLoss);
        console.log("operation", uint8(result.operation));
        console.log("ltvUpperBoundReached", ltvUpperBoundReached);
        console.log("deallocationHigherThanEquity", deallocationHigherThanEquity);
        console.log("insufficientFlashLiquidity", insufficientFlashLiquidity);

        strategy.adjustLeverage();
        console.log("position value before", positionValue);
        positionValue = strategy.totalAllocatedValue();
        console.log("position value after", positionValue);
        assertApproxEqAbs(uint256(strategy.getCurrentLtvInWad()), uint256(targetLtvInWad), 1e9, "current ltv mismatch");
        // engage the staged collateral at the lender
        lenderModule.engage(lenderModule.staged());
        positionValue = strategy.totalAllocatedValue();
        vm.expectRevert(
            abi.encodeWithSelector(IBaseLoopingStrategy.LenderModuleHasDebt.selector, lenderModule.getDebtAmount())
        );
        strategy.disableLooping();
        _deallocateFromStrategy(address(this), address(strategy), type(uint256).max);
        // expect revert if trying to disable looping with staged collateral
        // send collateral to the vault
        lenderModule.send(lenderModule.staged());
        // console log the total assets of the vault
        console.log("total assets of the vault after sending the surplus collateral to the vault", vault.totalAssets());
        // disable looping
        strategy.disableLooping();
        // assert that looping is disabled
        assertEq(strategy.loopingIsEnabled(), false, "looping is not disabled");

        // strategy.adjustLeverage(0, 0, true);
        // positionValue = strategy.totalAllocatedValue();
        // // expect debt to be zero
        // assertEq(lenderModule.getDebtAmount(), 0, "debt mismatch after adjustment");
        // console.log("position value after adjustment", positionValue);
        // // engage the staged collateral at the lender
        // lenderModule.engage(lenderModule.staged());
        // positionValue = strategy.totalAllocatedValue();
        // console.log("position value after engagement", positionValue);
        // ´
        // _deallocateFromStrategy(address(this), address(strategy), type(uint256).max);
        // positionValue = strategy.totalAllocatedValue();
        // console.log("position value after deallocation", positionValue);
        // assertEq(positionValue, 0, "position value mismatch after deallocation");
    }

    function testE2EfirstEnableLoopingAndWindUpAndAdjustLeverageToZero() public {
        deal(WETH, alice, 10 ether);
        _depositAsUser(alice, 10 ether);
        _allocateToStrategy(address(this), address(strategy), 10 ether);

        // enable looping
        uint64 targetLtvInWad = uint64(5 * WAD / 10); // = 50%
        uint256 flashCollateralEpsilon = 0.00001 ether; // 0.1 ether = 300 USD, 0.01 ether = 30 USD, 0.001 ether = 3 USD, 0.0001 ether = 0.3 USD, 0.00001 ether = 0.03 USD
        uint64 ltvAdditiveDeviationInWad = uint64(3 * WAD / 100); // = 3%
        uint64 maxSlippageInWad = uint64(80 * WAD / 10000); // = 0.8%
        strategy.enableLooping(
            address(flashModule),
            address(swapper),
            targetLtvInWad,
            flashCollateralEpsilon,
            ltvAdditiveDeviationInWad,
            maxSlippageInWad,
            false // permissionedLtvAdjustment = false
        );
        strategy.adjustLeverage();
        assertApproxEqAbs(uint256(strategy.getCurrentLtvInWad()), uint256(targetLtvInWad), 1e9, "current ltv mismatch");
        // engage the staged collateral at the lender
        lenderModule.engage(lenderModule.staged());
        strategy.adjustLeverage(maxSlippageInWad, 0, true);
        assertEq(uint256(strategy.getCurrentLtvInWad()), 0, "current ltv mismatch");
        // console.log the debt and collateral values and staged values
        console.log("debt value", lenderModule.getDebtAmount());
        console.log("collateral value", lenderModule.getCollateralAmount());
        console.log("staged value", lenderModule.staged());
    }

    function _depositAsUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(WETH).approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _allocateToStrategy(address allocator, address strategyAddress, uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] =
            IAllocateModule.AllocateParams({strategy: strategyAddress, isDeposit: true, extraData: abi.encode(amount)});

        bytes memory allocateData = abi.encode(params);

        vm.prank(allocator);
        vault.allocate(allocateData);
    }

    function _deallocateFromStrategy(address allocator, address strategyAddress, uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({
            strategy: strategyAddress, isDeposit: false, extraData: abi.encode(amount)
        });

        bytes memory deallocateData = abi.encode(params);

        vm.prank(allocator);
        vault.allocate(deallocateData);
    }
}
