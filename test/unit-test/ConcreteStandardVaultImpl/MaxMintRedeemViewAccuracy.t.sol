// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplBaseSetup} from "../../common/ConcreteStandardVaultImplBaseSetup.t.sol";
import {IConcreteStandardVaultImpl} from "../../../src/interface/IConcreteStandardVaultImpl.sol";
import {IAllocateModule} from "../../../src/interface/IAllocateModule.sol";
import {IStrategyTemplate} from "../../../src/interface/IStrategyTemplate.sol";
import {ERC4626StrategyMock} from "../../mock/ERC4626StrategyMock.sol";

/**
 * @dev After converting a capacity/liquidity bound to shares, `maxMint` / `maxRedeem` must
 *      re-check that converting those shares back to assets still clears `minTx*`.
 *      At a 1:1 share price the round-trip is exact and the op succeeds; with yield the
 *      views must return 0 rather than a size that `mint` / `redeem` would reject.
 */
contract MaxMintRedeemViewAccuracyTest is ConcreteStandardVaultImplBaseSetup {
    address internal user;
    ERC4626StrategyMock internal strategy;

    function setUp() public override {
        super.setUp();
        user = makeAddr("user");
        strategy = new ERC4626StrategyMock(address(asset), address(concreteStandardVault));

        vm.prank(strategyOperator);
        concreteStandardVault.addStrategy(address(strategy));
    }

    function _deposit(uint256 assets) internal {
        asset.mint(user, assets);
        vm.startPrank(user);
        asset.approve(address(concreteStandardVault), type(uint256).max);
        concreteStandardVault.deposit(assets, user);
        vm.stopPrank();
    }

    function _allocate(uint256 amount) internal {
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({
            isDeposit: true, strategy: address(strategy), extraData: abi.encode(amount)
        });
        vm.prank(allocator);
        concreteStandardVault.allocate(abi.encode(params));
    }

    /// @dev Donate `yield` into the strategy's underlying vault and materialize it on the parent.
    function _accrueYield(uint256 yield) internal {
        asset.mint(address(strategy.underlyingVault()), yield);
        vm.prank(allocator);
        concreteStandardVault.accrueYield();
    }

    // ── maxMint ───────────────────────────────────────────────────────────────

    /// @dev Control: 1:1 share price, remaining capacity == minTx. `mint(maxMint())` must succeed.
    function testMintMaxMintSucceedsAtPar() public {
        _deposit(1e18);

        uint256 minTx = 1e18;
        uint256 ta = concreteStandardVault.cachedTotalAssets();
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(minTx, ta + minTx)
        );

        uint256 maxM = concreteStandardVault.maxMint(user);
        assertGt(maxM, 0, "maxMint should be > 0");

        asset.mint(user, concreteStandardVault.previewMint(maxM));
        vm.prank(user);
        concreteStandardVault.mint(maxM, user);
    }

    /**
     * @dev 10% yield, remaining capacity == minTx = 1e18. The floor→ceil round-trip
     *      lands 1 wei below `minTx`, so `maxMint` must return 0 (no mintable size)
     *      rather than advertise a share amount that `mint` would reject.
     */
    function testMaxMintReturnsZeroWhenRoundTripFallsBelowMinTx() public {
        _deposit(1e18);
        _allocate(1e18);

        uint256 markedUp = 1.1e18;
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IStrategyTemplate.totalAllocatedValue.selector),
            abi.encode(markedUp)
        );
        vm.prank(allocator);
        concreteStandardVault.accrueYield();

        uint256 minTx = 1e18;
        uint256 ta = concreteStandardVault.cachedTotalAssets();
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(minTx, ta + minTx)
        );

        assertEq(concreteStandardVault.maxMint(user), 0, "maxMint must not advertise an unmintable size");
        assertEq(concreteStandardVault.maxDeposit(user), minTx, "deposit of the remaining capacity is still valid");
    }

    // ── maxRedeem ─────────────────────────────────────────────────────────────

    /// @dev Control: 1:1, full liquidity. `redeem(maxRedeem())` must succeed.
    function testRedeemMaxRedeemSucceedsAtPar() public {
        _deposit(10e18);

        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(1e18, type(uint256).max)
        );

        uint256 maxR = concreteStandardVault.maxRedeem(user);
        assertGt(maxR, 0, "maxRedeem should be > 0");

        vm.prank(user);
        concreteStandardVault.redeem(maxR, user, user);
    }

    /**
     * @dev Liquidity is clamped to idle (strategy allocated but not in the deallocation
     *      order). Idle == minTx == 1e18 after 10 bps of yield. The floor→floor
     *      round-trip falls below `minTx`, so `maxRedeem` must return 0.
     */
    function testMaxRedeemReturnsZeroWhenClampedRoundTripFallsBelowMinTx() public {
        _deposit(10e18);
        _allocate(9e18);
        _accrueYield(0.01e18); // 10 bps on the 10e18 book

        uint256 minTx = 1e18;
        vm.prank(vaultManager);
        concreteStandardVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(minTx, type(uint256).max)
        );

        assertEq(concreteStandardVault.maxRedeem(user), 0, "maxRedeem must not advertise an unredeemable size");
    }
}
