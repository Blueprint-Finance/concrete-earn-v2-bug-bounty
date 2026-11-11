// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    IConcreteFactory,
    ConcreteFactoryBaseSetup,
    VaultProxy,
    IConcreteStandardVaultImpl,
    ConcreteStandardVaultImpl,
    TestBaseSetup
} from "../common/TestBaseSetup.t.sol";
import {ConcretePredepositVaultImpl} from "../../src/implementation/ConcretePredepositVaultImpl.sol";
import {IConcretePredepositVaultImpl} from "../../src/interface/IConcretePredepositVaultImpl.sol";
import {PredepostVaultOApp} from "../../src/periphery/predeposit/PredepostVaultOApp.sol";
import {ShareDistributor} from "../../src/periphery/predeposit/ShareDistributor.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {AllocateModule} from "../../src/module/AllocateModule.sol";
import {IAllocateModule} from "../../src/interface/IAllocateModule.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../src/lib/Roles.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {IPredepostVaultOApp} from "../../src/periphery/interface/IPredepostVaultOApp.sol";
import {ConcreteBridgedAsyncVaultImpl} from "../../src/implementation/ConcreteBridgedAsyncVaultImpl.sol";
import {IConcreteBridgedAsyncVaultImpl} from "../../src/interface/IConcreteBridgedAsyncVaultImpl.sol";
import {MultisigStrategy} from "../../src/periphery/strategies/MultisigStrategy.sol";
import {PeripheryRolesLib} from "../../src/periphery/lib/PeripheryRolesLib.sol";
import {StrategyType} from "../../src/interface/IStrategyTemplate.sol";
import {IContractId} from "../../src/interface/IContractId.sol";

/**
 * @title LayerZeroClaimE2ETest
 * @notice End-to-end tests for LayerZero cross-chain share claiming using actual ShareDistributor proxy
 * @dev This test suite uses the real ShareDistributor contract (not a mock) to test the complete flow
 */
contract LayerZeroClaimE2ETest is TestBaseSetup, TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 public aEid = 1; // Source chain (where users deposit)
    uint32 public bEid = 2; // Destination chain (where shares are claimed)

    address public vaultOwner;
    address public vaultManager;
    address public strategyOperator;
    address public allocator;
    address public user1;
    address public user2;
    address public user3;
    address public strategyAdmin;
    address public multisig;
    address public destinationMultisig;

    ERC20Mock public asset;
    AllocateModule public allocateModule;
    ConcretePredepositVaultImpl public predepositVault; // Predeposit vault on chain A (source)
    PredepostVaultOApp public predepositVaultOApp; // OApp for predeposit vault
    ConcreteBridgedAsyncVaultImpl public destinationVault; // Bridged vault on chain B (destination)
    ShareDistributor public distributor; // Real ShareDistributor on chain B
    MultisigStrategy public strategy;
    MultisigStrategy public destinationStrategy; // Strategy for destination vault

    event SharesClaimedOnTargetChain(address indexed user, uint256 shares);

    function setUp() public virtual override(TestBaseSetup, TestHelperOz5) {
        TestBaseSetup.setUp();
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        _setupAddresses();
        _deployContracts();
        _setupLabels();
        _configureConnections();
        _setupRoles();
        _setupUsers();
        _fundDistributor();
    }

    function _setupAddresses() private {
        vaultOwner = makeAddr("vaultOwner");
        vaultManager = makeAddr("vaultManager");
        strategyOperator = makeAddr("strategyOperator");
        allocator = makeAddr("allocator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        strategyAdmin = makeAddr("strategyAdmin");
        multisig = makeAddr("multisig");
        destinationMultisig = makeAddr("destinationMultisig");
    }

    function _deployContracts() private {
        asset = new ERC20Mock();
        allocateModule = new AllocateModule();

        // Deploy and approve predeposit vault implementation
        ConcretePredepositVaultImpl predepositVaultImpl = new ConcretePredepositVaultImpl(address(factory));
        ConcreteBridgedAsyncVaultImpl bridgedAsyncVaultImpl = new ConcreteBridgedAsyncVaultImpl(address(factory));
        vm.startPrank(factoryOwner);
        factory.approveImplementation(address(predepositVaultImpl));
        factory.approveImplementation(address(bridgedAsyncVaultImpl));
        vm.stopPrank();

        // Get vault IDs
        uint64 predepositVaultUint64 = uint64(IContractId(address(predepositVaultImpl)).ID());
        uint64 bridgedAsyncVaulttUint64 = uint64(IContractId(address(bridgedAsyncVaultImpl)).ID());

        // Deploy predeposit vault on chain A
        predepositVault = ConcretePredepositVaultImpl(
            factory.create(
                predepositVaultUint64,
                vaultOwner,
                abi.encode(address(allocateModule), address(asset), vaultManager, "Concrete Predeposit Vault A", "CPVA")
            )
        );

        // Deploy OApp for predeposit vault
        predepositVaultOApp = PredepostVaultOApp(
            address(
                new ERC1967Proxy(
                    address(new PredepostVaultOApp(address(endpoints[aEid]))),
                    abi.encodeCall(PredepostVaultOApp.initialize, (address(predepositVault), vaultOwner))
                )
            )
        );

        // Deploy bridged async destination vault on chain B
        destinationVault = ConcreteBridgedAsyncVaultImpl(
            factory.create(
                bridgedAsyncVaulttUint64,
                vaultOwner,
                abi.encode(address(allocateModule), address(asset), vaultManager, "Concrete Bridged Vault B", "CBVB")
            )
        );

        // Deploy REAL ShareDistributor on chain B using proxy pattern
        ShareDistributor distributorImpl = new ShareDistributor(address(endpoints[bEid]));
        bytes memory initData = abi.encodeCall(ShareDistributor.initialize, (address(destinationVault), vaultManager));
        ERC1967Proxy distributorProxy = new ERC1967Proxy(address(distributorImpl), initData);
        distributor = ShareDistributor(address(distributorProxy));

        // Deploy MultisigStrategy for source vault
        MultisigStrategy strategyImpl = new MultisigStrategy();
        bytes memory strategyInitData = abi.encodeWithSelector(
            MultisigStrategy.initialize.selector,
            strategyAdmin,
            address(predepositVault),
            multisig,
            uint64(1000), // maxAccountingChangeThreshold (10%)
            uint64(86400), // accountingValidityPeriod (1 day)
            uint64(3600), // cooldownPeriod (1 hour)
            address(0) // timelock_ (no timelock at deploy time)
        );
        ERC1967Proxy strategyProxy = new ERC1967Proxy(address(strategyImpl), strategyInitData);
        strategy = MultisigStrategy(address(strategyProxy));

        // Deploy MultisigStrategy for destination vault
        MultisigStrategy destStrategyImpl = new MultisigStrategy();
        bytes memory destStrategyInitData = abi.encodeWithSelector(
            MultisigStrategy.initialize.selector,
            strategyAdmin,
            address(destinationVault),
            destinationMultisig,
            uint64(5000), // maxAccountingChangeThreshold (50%) - max allowed threshold for setup
            uint64(86400), // accountingValidityPeriod (1 day)
            uint64(3600), // cooldownPeriod (1 hour)
            address(0) // timelock_ (no timelock at deploy time)
        );
        ERC1967Proxy destStrategyProxy = new ERC1967Proxy(address(destStrategyImpl), destStrategyInitData);
        destinationStrategy = MultisigStrategy(address(destStrategyProxy));
    }

    function _setupLabels() private {
        vm.label(address(predepositVault), "predepositVault");
        vm.label(address(predepositVaultOApp), "predepositVaultOApp");
        vm.label(address(destinationVault), "destinationVault");
        vm.label(address(distributor), "distributor");
        vm.label(address(asset), "asset");
        vm.label(address(endpoints[aEid]), "endpointA");
        vm.label(address(endpoints[bEid]), "endpointB");
        vm.label(address(strategy), "strategy");
        vm.label(address(destinationStrategy), "destinationStrategy");
        vm.label(strategyAdmin, "strategyAdmin");
        vm.label(multisig, "multisig");
        vm.label(destinationMultisig, "destinationMultisig");
    }

    function _configureConnections() private {
        // Set OApp in predeposit vault and enable self claims
        vm.startPrank(vaultManager);
        predepositVault.setOApp(address(predepositVaultOApp));
        predepositVault.setSelfClaimsEnabled(true); // Enable self claims for testing
        vm.stopPrank();

        // Configure OApp peer and destination
        vm.startPrank(vaultOwner);
        predepositVaultOApp.setPeer(bEid, addressToBytes32(address(distributor)));
        predepositVaultOApp.setDstEid(bEid);
        vm.stopPrank();

        // Configure distributor peer
        vm.prank(vaultManager);
        distributor.setPeer(aEid, addressToBytes32(address(predepositVaultOApp)));
    }

    function _setupRoles() private {
        vm.startPrank(vaultManager);
        predepositVault.grantRole(RolesLib.STRATEGY_MANAGER, strategyOperator);
        predepositVault.grantRole(RolesLib.ALLOCATOR, allocator);

        // Setup roles for destination vault
        destinationVault.grantRole(RolesLib.STRATEGY_MANAGER, strategyOperator);
        destinationVault.grantRole(RolesLib.ALLOCATOR, allocator);
        vm.stopPrank();
    }

    function _setupUsers() private {
        // Fund users with assets
        asset.mint(user1, 10000e18);
        asset.mint(user2, 10000e18);
        asset.mint(user3, 10000e18);

        // Fund users with ETH for LayerZero fees
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(user3, 10 ether);
        vm.deal(vaultManager, 10 ether);

        // Approve vault
        vm.prank(user1);
        asset.approve(address(predepositVault), 10000e18);

        vm.prank(user2);
        asset.approve(address(predepositVault), 10000e18);

        vm.prank(user3);
        asset.approve(address(predepositVault), 10000e18);

        // Add strategy to vault
        vm.prank(strategyOperator);
        predepositVault.addStrategy(address(strategy));

        // Set deallocation order
        address[] memory order = new address[](1);
        order[0] = address(strategy);
        vm.prank(allocator);
        predepositVault.setDeallocationOrder(order);

        // Users deposit into vault A
        vm.prank(user1);
        predepositVault.deposit(5000e18, user1);

        vm.prank(user2);
        predepositVault.deposit(3000e18, user2);

        vm.prank(user3);
        predepositVault.deposit(2000e18, user3);

        // Allocate all assets to strategy
        _allocateAllToStrategy();

        // Lock deposits and withdrawals before allowing claims
        vm.startPrank(vaultManager);
        predepositVault.configure(IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(0, 0));
        predepositVault.configure(IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits, abi.encode(0, 0));
        vm.stopPrank();
    }

    function _fundDistributor() private {
        // Fund the distributor using unbacked mint + direct multisig funding with 1.5x exchange rate
        uint256 sharesToMint = predepositVault.totalSupply();
        uint256 assetsToFund = (sharesToMint * 15) / 10; // 1.5x the shares for 1.5 exchange rate
        vm.prank(vaultManager);
        destinationVault.configure(IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(0, 0));
        // Step 1: Unbacked mint shares to the distributor (via vault manager)
        vm.prank(vaultManager);
        destinationVault.unbackedMint(sharesToMint);

        // Verify shares were minted without assets
        assertEq(destinationVault.balanceOf(vaultManager), sharesToMint, "Shares should be minted to vault manager");
        assertEq(destinationVault.totalSupply(), sharesToMint, "Total supply should equal minted shares");
        assertEq(destinationVault.totalAssets(), 0, "Total assets should still be 0");

        // Step 2: Transfer shares from vault manager to distributor
        vm.prank(vaultManager);
        destinationVault.transfer(address(distributor), sharesToMint);

        // Step 3: Add strategy to destination vault
        vm.prank(strategyOperator);
        destinationVault.addStrategy(address(destinationStrategy));

        // Set deallocation order for destination vault
        address[] memory order = new address[](1);
        order[0] = address(destinationStrategy);
        vm.prank(allocator);
        destinationVault.setDeallocationOrder(order);

        // Step 4: Send assets directly to the strategy's multisig (simulating external funding)
        // This bypasses the vault's allocate function
        asset.mint(destinationMultisig, assetsToFund);
        emit log_named_address("Assets sent to multisig", destinationMultisig);
        emit log_named_uint("Assets sent to multisig amount", assetsToFund);

        // Step 5: Adjust strategy's totalAssets to reflect the multisig holdings
        // This is how the strategy tracks assets held by the multisig
        vm.startPrank(strategyAdmin);
        destinationStrategy.pause();
        destinationStrategy.unpauseAndAdjustTotalAssets(int256(assetsToFund));
        vm.stopPrank();

        // Verify state BEFORE accrueYield
        // cachedTotalAssets is 0, but convertToAssets previews strategy value via _previewYieldNoFees
        uint256 oneShare = 10 ** destinationVault.decimals();
        uint256 expectedAssets = (oneShare * 15) / 10; // 1.5e18 for 1e18 shares

        emit log_string("=== BEFORE accrueYield ===");
        assertEq(destinationVault.cachedTotalAssets(), 0, "Cached total assets should be 0 before accrueYield");

        uint256 exchangeRateBefore = destinationVault.convertToAssets(oneShare);
        emit log_named_uint("Exchange rate BEFORE accrueYield", exchangeRateBefore);
        emit log_named_uint("cachedTotalAssets BEFORE", destinationVault.cachedTotalAssets());

        // convertToAssets previews yield by querying strategy, so exchange rate is already 1.5
        assertApproxEqAbs(
            exchangeRateBefore, expectedAssets, 1, "Exchange rate should be ~1.5 BEFORE accrueYield (via preview)"
        );

        // Step 6: Accrue yield to update cachedTotalAssets based on strategy's reported value
        vm.prank(allocator);
        destinationVault.accrueYield();

        // Verify state AFTER accrueYield
        // Now cachedTotalAssets is updated, and there's no new yield to preview
        emit log_string("=== AFTER accrueYield ===");
        uint256 cachedAssetsAfter = destinationVault.cachedTotalAssets();
        emit log_named_uint("cachedTotalAssets AFTER", cachedAssetsAfter);
        assertEq(cachedAssetsAfter, assetsToFund, "Cached assets should be updated to funded amount");

        uint256 exchangeRateAfter = destinationVault.convertToAssets(oneShare);
        emit log_named_uint("Exchange rate AFTER accrueYield", exchangeRateAfter);

        // Exchange rate should still be 1.5, but now comes from cachedTotalAssets (no new yield)
        assertApproxEqAbs(
            exchangeRateAfter, expectedAssets, 1, "Exchange rate should be ~1.5 AFTER accrueYield (from cache)"
        );

        // Verify total assets equals the strategy's reported amount
        assertEq(destinationVault.totalAssets(), assetsToFund, "Total assets should equal funded amount");

        // Verify cached assets was updated by accrueYield
        uint256 cachedAssets = destinationVault.cachedTotalAssets();
        assertEq(cachedAssets, assetsToFund, "Cached assets should equal funded amount after accrueYield");

        // Verify no fees are counted (totalAssets should equal cachedTotalAssets)
        assertEq(destinationVault.totalAssets(), cachedAssets, "No fees should be counted");

        // Log the setup for clarity
        emit log_named_uint("Shares minted", sharesToMint);
        emit log_named_uint("Assets funded to multisig", assetsToFund);
        emit log_string("--- Exchange Rate Verification ---");
        emit log_named_uint("Before accrueYield", exchangeRateBefore);
        emit log_named_uint("After accrueYield", exchangeRateAfter);
    }

    function _allocateAllToStrategy() internal {
        uint256 amount = predepositVault.cachedTotalAssets();
        if (amount > 0) {
            IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
            params[0] = IAllocateModule.AllocateParams({
                isDeposit: true, strategy: address(strategy), extraData: abi.encode(amount)
            });
            vm.prank(allocator);
            predepositVault.allocate(abi.encode(params));
        }
    }

    /*//////////////////////////////////////////////////////////////
                        SINGLE CLAIM E2E TESTS
    //////////////////////////////////////////////////////////////*/

    function test_E2E_singleClaim_fullFlow() public {
        uint256 user1SharesBefore = predepositVault.balanceOf(user1);
        assertGt(user1SharesBefore, 0, "User should have shares");

        // Check initial state on destination chain
        uint256 user1DestSharesBefore = destinationVault.balanceOf(user1);
        uint256 distributorSharesBefore = distributor.getAvailableShares();
        assertEq(user1DestSharesBefore, 0, "User should have no destination shares initially");
        assertGt(distributorSharesBefore, 0, "Distributor should have shares");

        // Build options for the send operation
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Quote the fee via OApp
        IPredepostVaultOApp oapp = IPredepostVaultOApp(predepositVault.getOApp());
        MessagingFee memory fee = oapp.quoteClaimOnTargetChain(user1, options, false);

        vm.expectEmit(true, true, true, true);
        emit SharesClaimedOnTargetChain(user1, user1SharesBefore);

        // Perform the claim operation
        vm.prank(user1);
        predepositVault.claimOnTargetChain{value: fee.nativeFee}(options);

        // Verify that packets were sent correctly and delivered to distributor
        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // Check shares are burned on chain A
        uint256 user1SharesAfter = predepositVault.balanceOf(user1);
        assertEq(user1SharesAfter, 0, "User shares should be burned on chain A");

        // Check locked shares tracking
        uint256 lockedShares = predepositVault.getLockedShares(user1);
        assertEq(lockedShares, user1SharesBefore, "Locked shares should be tracked");

        // Check shares distributed on chain B
        uint256 user1DestSharesAfter = destinationVault.balanceOf(user1);
        uint256 distributorSharesAfter = distributor.getAvailableShares();

        assertEq(user1DestSharesAfter, user1SharesBefore, "User should receive destination shares");
        assertEq(
            distributorSharesAfter, distributorSharesBefore - user1SharesBefore, "Distributor shares should decrease"
        );

        // ============================================================================
        // REDEMPTION FLOW: User1 redeems their shares on the destination vault
        // ============================================================================

        emit log_string("=== Starting Redemption Flow ===");

        // Calculate expected assets to receive (1.5x exchange rate)
        uint256 sharesToRedeem = user1DestSharesAfter;
        uint256 expectedAssets = destinationVault.convertToAssets(sharesToRedeem);
        emit log_named_uint("Shares to redeem", sharesToRedeem);
        emit log_named_uint("Expected assets to receive", expectedAssets);

        // Verify exchange rate before redemption
        uint256 oneShare = 10 ** destinationVault.decimals();
        uint256 exchangeRateBeforeRedeem = destinationVault.convertToAssets(oneShare);
        emit log_named_uint("Exchange rate before redemption", exchangeRateBeforeRedeem);

        // The multisig needs to approve the strategy to pull assets for withdrawal
        // The MultisigStrategy pulls assets FROM multisig TO strategy when onWithdraw is called
        uint256 assetsNeededForWithdrawal = expectedAssets;

        // Multisig approves strategy to transfer assets (simulating multisig preparing for redemption)
        vm.prank(destinationMultisig);
        asset.approve(address(destinationStrategy), assetsNeededForWithdrawal);

        emit log_named_uint("Multisig approved strategy for", assetsNeededForWithdrawal);

        // Check if withdrawal queue is active (AsyncVault feature)
        bool queueActive = destinationVault.isQueueActive();
        emit log_named_string("Withdrawal queue active?", queueActive ? "YES" : "NO");

        // If queue is active, disable it for immediate redemption
        if (queueActive) {
            vm.prank(vaultManager);
            destinationVault.toggleQueueActive();
            emit log_string("Withdrawal queue DISABLED for immediate redemption");
        }

        // User1 redeems all their shares
        uint256 user1AssetsBefore = asset.balanceOf(user1);
        emit log_named_uint("User1 asset balance BEFORE redemption", user1AssetsBefore);
        emit log_named_uint("Multisig asset balance BEFORE redemption", asset.balanceOf(destinationMultisig));
        emit log_named_uint("Strategy asset balance BEFORE redemption", asset.balanceOf(address(destinationStrategy)));

        vm.prank(user1);
        uint256 assetsReceived = destinationVault.redeem(sharesToRedeem, user1, user1);

        uint256 user1AssetsAfter = asset.balanceOf(user1);

        emit log_named_uint("Assets received from redemption (return value)", assetsReceived);
        emit log_named_uint("User1 asset balance AFTER redemption", user1AssetsAfter);
        emit log_named_uint("Multisig asset balance AFTER redemption", asset.balanceOf(destinationMultisig));
        emit log_named_uint("Strategy asset balance AFTER redemption", asset.balanceOf(address(destinationStrategy)));
        emit log_named_uint("Actual assets received by user1", user1AssetsAfter - user1AssetsBefore);

        // Verify redemption results
        assertEq(destinationVault.balanceOf(user1), 0, "User1 shares should be burned after redemption");
        assertEq(user1AssetsAfter - user1AssetsBefore, assetsReceived, "User should receive the redeemed assets");
        assertApproxEqAbs(
            assetsReceived, expectedAssets, 1, "Assets received should match expected (within 1 wei rounding)"
        );

        // Verify exchange rate is maintained after redemption
        uint256 exchangeRateAfterRedeem = destinationVault.convertToAssets(oneShare);
        emit log_named_uint("Exchange rate after redemption", exchangeRateAfterRedeem);
        assertApproxEqAbs(
            exchangeRateAfterRedeem,
            exchangeRateBeforeRedeem,
            2,
            "Exchange rate should remain constant after redemption"
        );

        emit log_string("=== Redemption Flow Completed Successfully ===");
    }

    function test_E2E_multipleUsersClaim() public {
        uint256 user1Shares = predepositVault.balanceOf(user1);
        uint256 user2Shares = predepositVault.balanceOf(user2);
        uint256 user3Shares = predepositVault.balanceOf(user3);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        IPredepostVaultOApp oapp = IPredepostVaultOApp(predepositVault.getOApp());

        // User1 claims
        MessagingFee memory fee1 = oapp.quoteClaimOnTargetChain(user1, options, false);
        vm.prank(user1);
        predepositVault.claimOnTargetChain{value: fee1.nativeFee}(options);
        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // User2 claims
        MessagingFee memory fee2 = oapp.quoteClaimOnTargetChain(user2, options, false);
        vm.prank(user2);
        predepositVault.claimOnTargetChain{value: fee2.nativeFee}(options);
        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // User3 claims
        MessagingFee memory fee3 = oapp.quoteClaimOnTargetChain(user3, options, false);
        vm.prank(user3);
        predepositVault.claimOnTargetChain{value: fee3.nativeFee}(options);
        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // All users should have their shares burned on chain A
        assertEq(predepositVault.balanceOf(user1), 0);
        assertEq(predepositVault.balanceOf(user2), 0);
        assertEq(predepositVault.balanceOf(user3), 0);

        // All users should have their locked shares tracked
        assertEq(predepositVault.getLockedShares(user1), user1Shares);
        assertEq(predepositVault.getLockedShares(user2), user2Shares);
        assertEq(predepositVault.getLockedShares(user3), user3Shares);

        // All users should have received destination shares
        assertEq(destinationVault.balanceOf(user1), user1Shares);
        assertEq(destinationVault.balanceOf(user2), user2Shares);
        assertEq(destinationVault.balanceOf(user3), user3Shares);
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH CLAIM E2E TESTS
    //////////////////////////////////////////////////////////////*/

    function test_E2E_batchClaim_fullFlow() public {
        uint256 user1SharesBefore = predepositVault.balanceOf(user1);
        uint256 user2SharesBefore = predepositVault.balanceOf(user2);
        uint256 user3SharesBefore = predepositVault.balanceOf(user3);

        // Check initial state on destination chain
        uint256 distributorSharesBefore = distributor.getAvailableShares();
        assertGt(distributorSharesBefore, 0, "Distributor should have shares");

        // Build options for batch operation
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(300000, 0);

        // Prepare batch data
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        bytes memory addressesData = abi.encode(users);

        // Quote the fee via OApp
        IPredepostVaultOApp oapp = IPredepostVaultOApp(predepositVault.getOApp());
        MessagingFee memory fee = oapp.quoteBatchClaimOnTargetChain(addressesData, options, false);

        // Perform the batch claim operation
        vm.prank(vaultManager);
        predepositVault.batchClaimOnTargetChain{value: fee.nativeFee}(addressesData, options);

        // Verify packets sent to distributor
        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // Check shares are burned on chain A
        assertEq(predepositVault.balanceOf(user1), 0, "User1 shares should be burned");
        assertEq(predepositVault.balanceOf(user2), 0, "User2 shares should be burned");
        assertEq(predepositVault.balanceOf(user3), 0, "User3 shares should be burned");

        // Check locked shares tracking
        assertEq(predepositVault.getLockedShares(user1), user1SharesBefore);
        assertEq(predepositVault.getLockedShares(user2), user2SharesBefore);
        assertEq(predepositVault.getLockedShares(user3), user3SharesBefore);

        // Check shares distributed on chain B
        assertEq(destinationVault.balanceOf(user1), user1SharesBefore, "User1 should receive shares on chain B");
        assertEq(destinationVault.balanceOf(user2), user2SharesBefore, "User2 should receive shares on chain B");
        assertEq(destinationVault.balanceOf(user3), user3SharesBefore, "User3 should receive shares on chain B");

        // Check claimed shares tracking on distributor
        assertEq(distributor.claimedShares(user1), user1SharesBefore);
        assertEq(distributor.claimedShares(user2), user2SharesBefore);
        assertEq(distributor.claimedShares(user3), user3SharesBefore);
    }

    function test_E2E_batchClaim_withDuplicates() public {
        // Create array with duplicate users
        address[] memory users = new address[](4);
        users[0] = user1;
        users[1] = user2;
        users[2] = user1; // Duplicate
        users[3] = user2; // Duplicate

        uint256 user1SharesBefore = predepositVault.balanceOf(user1);
        uint256 user2SharesBefore = predepositVault.balanceOf(user2);

        bytes memory addressesData = abi.encode(users);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(300000, 0);

        IPredepostVaultOApp oapp = IPredepostVaultOApp(predepositVault.getOApp());
        MessagingFee memory fee = oapp.quoteBatchClaimOnTargetChain(addressesData, options, false);

        // Batch claim should succeed - duplicates are skipped
        vm.prank(vaultManager);
        predepositVault.batchClaimOnTargetChain{value: fee.nativeFee}(addressesData, options);

        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // Users should have their shares burned (only once)
        assertEq(predepositVault.balanceOf(user1), 0);
        assertEq(predepositVault.balanceOf(user2), 0);

        // Users should receive shares only once on destination
        assertEq(destinationVault.balanceOf(user1), user1SharesBefore);
        assertEq(destinationVault.balanceOf(user2), user2SharesBefore);
    }

    /*//////////////////////////////////////////////////////////////
                    EXCHANGE RATE INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_E2E_exchangeRate_remainsConstant() public {
        // Get initial exchange rate
        uint256 decimals = predepositVault.decimals();
        uint256 oneShare = 10 ** decimals;
        uint256 initialExchangeRate = predepositVault.convertToAssets(oneShare);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        IPredepostVaultOApp oapp = IPredepostVaultOApp(predepositVault.getOApp());

        // User1 claims
        MessagingFee memory fee = oapp.quoteClaimOnTargetChain(user1, options, false);
        vm.prank(user1);
        predepositVault.claimOnTargetChain{value: fee.nativeFee}(options);
        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // Check exchange rate after first claim
        if (predepositVault.totalSupply() > 0) {
            uint256 exchangeRateAfter = predepositVault.convertToAssets(oneShare);
            uint256 diff = exchangeRateAfter > initialExchangeRate
                ? exchangeRateAfter - initialExchangeRate
                : initialExchangeRate - exchangeRateAfter;
            uint256 maxDiff = initialExchangeRate / 10000; // 0.01%
            assertLe(diff, maxDiff, "Exchange rate should remain nearly constant");
        }

        // User2 claims
        vm.prank(user2);
        predepositVault.claimOnTargetChain{value: fee.nativeFee}(options);
        verifyPackets(bEid, addressToBytes32(address(distributor)));

        // Check exchange rate after second claim
        if (predepositVault.totalSupply() > 0) {
            uint256 exchangeRateAfter = predepositVault.convertToAssets(oneShare);
            uint256 diff = exchangeRateAfter > initialExchangeRate
                ? exchangeRateAfter - initialExchangeRate
                : initialExchangeRate - exchangeRateAfter;
            uint256 maxDiff = initialExchangeRate / 10000; // 0.01%
            assertLe(diff, maxDiff, "Exchange rate should remain nearly constant");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_E2E_emergencyWithdraw() public {
        uint256 withdrawAmount = 1000e18;
        uint256 managerBalanceBefore = destinationVault.balanceOf(vaultManager);
        uint256 distributorBalanceBefore = distributor.getAvailableShares();

        vm.prank(vaultManager);
        distributor.emergencyWithdraw(withdrawAmount);

        assertEq(
            destinationVault.balanceOf(vaultManager),
            managerBalanceBefore + withdrawAmount,
            "Manager should receive shares"
        );
        assertEq(
            distributor.getAvailableShares(),
            distributorBalanceBefore - withdrawAmount,
            "Distributor balance should decrease"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_E2E_revertsWhenSelfClaimsDisabled() public {
        // Disable self claims
        vm.prank(vaultManager);
        predepositVault.setSelfClaimsEnabled(false);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        vm.expectRevert(IConcretePredepositVaultImpl.SelfClaimsDisabled.selector);
        vm.prank(user1);
        predepositVault.claimOnTargetChain{value: 0.01 ether}(options);
    }

    function test_E2E_revertsWhenDepositsNotLocked() public {
        // Unlock deposits
        vm.prank(vaultManager);
        predepositVault.configure(
            IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits, abi.encode(0, type(uint256).max)
        );

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        IPredepostVaultOApp oapp = IPredepostVaultOApp(predepositVault.getOApp());
        MessagingFee memory fee = oapp.quoteClaimOnTargetChain(user1, options, false);

        vm.expectRevert(IConcretePredepositVaultImpl.DepositsNotLocked.selector);
        vm.prank(user1);
        predepositVault.claimOnTargetChain{value: fee.nativeFee}(options);
    }

    function test_E2E_revertsWithNoShares() public {
        address noSharesUser = makeAddr("noSharesUser");
        vm.deal(noSharesUser, 1 ether);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        vm.expectRevert(IConcretePredepositVaultImpl.NoSharesToClaim.selector);
        vm.prank(noSharesUser);
        predepositVault.claimOnTargetChain{value: 0.01 ether}(options);
    }
}
