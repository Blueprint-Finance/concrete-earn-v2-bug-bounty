// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PeripheryFactory} from "../../../src/periphery/factory/PeripheryFactory.sol";
import {PeripheryRolesLib} from "../../../src/periphery/lib/PeripheryRolesLib.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin-contracts/proxy/transparent/ProxyAdmin.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Mock} from "../../mock/ERC20Mock.sol";
import {PositionHelperAaveV3} from "../../../src/periphery/positionhelper/PositionHelperAaveV3.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Upgraded factory (for self-upgrade test)
// ─────────────────────────────────────────────────────────────────────────────

contract PeripheryFactory2 is PeripheryFactory {
    uint8 public version;

    function initializeV2(uint8 version_) external reinitializer(version_) {
        version = version_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockStrategyImpl
// Minimal transparent-proxy-compatible strategy: IContractId + AccessControl.
// ID() returns a constructor-supplied value.
// initialize() grants STRATEGY_UPGRADER (and ROLE_ADMIN) to `admin`.
// ─────────────────────────────────────────────────────────────────────────────

contract MockStrategyImpl is IContractId, AccessControlUpgradeable {
    uint64 private immutable _implId;

    constructor(uint64 implId_) {
        _implId = implId_;
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        __AccessControl_init();
        _setRoleAdmin(PeripheryRolesLib.ROLE_ADMIN, PeripheryRolesLib.ROLE_ADMIN);
        _setRoleAdmin(PeripheryRolesLib.STRATEGY_ADMIN, PeripheryRolesLib.ROLE_ADMIN);
        _setRoleAdmin(PeripheryRolesLib.STRATEGY_UPGRADER, PeripheryRolesLib.ROLE_ADMIN);
        _grantRole(PeripheryRolesLib.ROLE_ADMIN, admin);
        _grantRole(PeripheryRolesLib.STRATEGY_ADMIN, admin);
        _grantRole(PeripheryRolesLib.STRATEGY_UPGRADER, admin);
    }

    function ID() public view override returns (uint64) {
        return _implId;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockPMHImpl
// Minimal clone target: just needs ID() — ClonesWithImmutableArgs handles the rest.
// ─────────────────────────────────────────────────────────────────────────────

contract MockPMHImpl is IContractId {
    uint64 private immutable _implId;

    constructor(uint64 implId_) {
        _implId = implId_;
    }

    function ID() public view override returns (uint64) {
        return _implId;
    }

    // Matches PositionHelperAaveV3.initialize signature so abi.encodeCall works and the
    // factory's clone_.call(initData) succeeds against this mock implementation.
    function initialize(address, address, address, address, address, uint64, uint64, uint64) external {}
}

// ─────────────────────────────────────────────────────────────────────────────
// MockHookImpl
// Minimal ERC-1167 clone target: needs ID() and an initialize() that records args.
// Mirrors the real hooks' immutable-arg layout [factory (20)][vault (20)] and only
// allows the embedded factory to initialize, so the clone-init front-running guard is
// exercised through the factory. `initialize` reverts on a zero owner to exercise the
// bubbled-revert path.
// ─────────────────────────────────────────────────────────────────────────────

contract MockHookImpl is IContractId, Clone {
    error HookZeroOwner();
    error NotFactory();

    uint64 private immutable _implId;
    bool public initialized;
    address public owner;

    constructor(uint64 implId_) {
        _implId = implId_;
    }

    function ID() public view override returns (uint64) {
        return _implId;
    }

    function initialize(address owner_) external {
        require(msg.sender == FACTORY(), NotFactory());
        if (owner_ == address(0)) revert HookZeroOwner();
        initialized = true;
        owner = owner_;
    }

    function vaultAddr() external view returns (address) {
        return _getArgAddress(20);
    }

    function FACTORY() public view returns (address) {
        return _getArgAddress(0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockLegacyStrategyImpl
// Simulates a pre-IContractId strategy: has AccessControl but no ID() function.
// initialize() grants STRATEGY_ADMIN (and ROLE_ADMIN) to `admin`.
// ─────────────────────────────────────────────────────────────────────────────

contract MockLegacyStrategyImpl is AccessControlUpgradeable {
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        __AccessControl_init();
        _setRoleAdmin(PeripheryRolesLib.ROLE_ADMIN, PeripheryRolesLib.ROLE_ADMIN);
        _setRoleAdmin(PeripheryRolesLib.STRATEGY_ADMIN, PeripheryRolesLib.ROLE_ADMIN);
        _setRoleAdmin(PeripheryRolesLib.STRATEGY_UPGRADER, PeripheryRolesLib.ROLE_ADMIN);
        _grantRole(PeripheryRolesLib.ROLE_ADMIN, admin);
        _grantRole(PeripheryRolesLib.STRATEGY_ADMIN, admin);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PeripheryFactoryUnitTest
// ─────────────────────────────────────────────────────────────────────────────

contract PeripheryFactoryUnitTest is Test {
    address public factoryOwner;
    PeripheryFactory public factory;

    uint64 constant STRAT_ID_1 = 1001;
    uint64 constant STRAT_ID_2 = 1002;
    uint64 constant PMH_ID_1 = 2001;
    uint64 constant HOOK_ID_1 = 3001;

    function setUp() public {
        factoryOwner = makeAddr("factoryOwner");
        address factoryImpl = address(new PeripheryFactory());
        factory = PeripheryFactory(
            address(
                new ERC1967Proxy(factoryImpl, abi.encodeCall(PeripheryFactory.initialize, (factoryOwner, address(0))))
            )
        );
    }

    // ── internal helpers ──────────────────────────────────────────────────────

    /// Mirrors the factory's CREATE1 ProxyAdmin formula.
    function _computeProxyAdmin(address proxy) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))))));
    }

    /// Deploy a legacy strategy (no ID()) as a transparent proxy managed by the factory,
    /// then register it. Returns the proxy address.
    function _deployAndRegisterLegacyProxy(address admin) internal returns (address proxy) {
        address legacyImpl = address(new MockLegacyStrategyImpl());
        proxy = address(
            new TransparentUpgradeableProxy(
                legacyImpl, address(factory), abi.encodeCall(MockLegacyStrategyImpl.initialize, (admin))
            )
        );
        address pa = _computeProxyAdmin(proxy);
        vm.prank(factoryOwner);
        factory.registerStrategy(proxy, pa);
    }

    /// Approve both strategy impls in one call.
    function _approveStrats() internal returns (address impl1, address impl2) {
        impl1 = address(new MockStrategyImpl(STRAT_ID_1));
        impl2 = address(new MockStrategyImpl(STRAT_ID_2));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl1);
        factory.approveStrategyImpl(impl2);
        vm.stopPrank();
    }

    /// Deploy a strategy proxy via the factory.
    function _deployProxy(uint64 implId, address admin) internal returns (address) {
        return factory.deployStrategy(implId, abi.encodeCall(MockStrategyImpl.initialize, (admin)));
    }

    // =========================================================================
    // FACTORY SELF-UPGRADE
    // =========================================================================

    function testUpgradeFactory() public {
        address factoryImpl2 = address(new PeripheryFactory2());

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.FactoryUpgradeAuthorized(factoryImpl2, factoryOwner);

        vm.prank(factoryOwner);
        factory.upgradeToAndCall(factoryImpl2, abi.encodeCall(PeripheryFactory2.initializeV2, (2)));
        assertEq(PeripheryFactory2(address(factory)).version(), 2);
    }

    function testUpgradeFactory_fails_NonOwner() public {
        address factoryImpl2 = address(new PeripheryFactory2());
        address nonOwner = makeAddr("nonOwner");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        factory.upgradeToAndCall(factoryImpl2, abi.encodeCall(PeripheryFactory2.initializeV2, (2)));
    }

    // =========================================================================
    // STRATEGY — registration
    // =========================================================================

    function testApproveStrategyImpl() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.StrategyImplApproved(STRAT_ID_1, impl);

        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl);

        assertEq(factory.getStrategyImpl(STRAT_ID_1), impl);
    }

    function testApproveStrategyImpl_fails_ZeroAddress() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.approveStrategyImpl(address(0));
    }

    function testApproveStrategyImpl_fails_ZeroId() public {
        address impl = address(new MockStrategyImpl(0));
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ZeroImplId.selector);
        factory.approveStrategyImpl(impl);
    }

    function testApproveStrategyImpl_fails_AlreadyApproved() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl);
        vm.expectRevert(PeripheryFactory.ImplAlreadyApproved.selector);
        factory.approveStrategyImpl(impl);
        vm.stopPrank();
    }

    function testBlockStrategyImpl() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl);

        vm.expectEmit(true, false, false, false);
        emit PeripheryFactory.StrategyImplBlocked(STRAT_ID_1);

        factory.blockStrategyImpl(STRAT_ID_1);
        vm.stopPrank();

        assertEq(factory.isStrategyImplBlocked(STRAT_ID_1), true);
    }

    function testBlockStrategyImpl_fails_NotFound() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.blockStrategyImpl(STRAT_ID_1);
    }

    function testBlockStrategyImpl_fails_AlreadyBlocked() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl);
        factory.blockStrategyImpl(STRAT_ID_1);
        vm.expectRevert(PeripheryFactory.AlreadyBlocked.selector);
        factory.blockStrategyImpl(STRAT_ID_1);
        vm.stopPrank();
    }

    function testSetStrategyMigratable() public {
        _approveStrats();

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.StrategyMigratableSet(STRAT_ID_1, STRAT_ID_2);

        vm.prank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);

        assertEq(factory.isStrategyMigratable(STRAT_ID_1, STRAT_ID_2), true);
        assertEq(factory.isStrategyMigratable(STRAT_ID_2, STRAT_ID_1), false);
    }

    function testSetStrategyMigratable_fails_SameImpl() public {
        address impl1 = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl1);
        vm.expectRevert(PeripheryFactory.SameImpl.selector);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_1);
        vm.stopPrank();
    }

    function testSetStrategyMigratable_fails_FromNotFound() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
    }

    function testSetStrategyMigratable_fails_ToNotFound() public {
        address impl1 = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl1);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
        vm.stopPrank();
    }

    // =========================================================================
    // STRATEGY — deployment
    // =========================================================================

    function testDeployStrategy() public {
        address admin = makeAddr("stratAdmin");
        address impl = address(new MockStrategyImpl(STRAT_ID_1));

        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl);

        // Only verify the indexed implId (topic2); proxy and proxyAdmin addresses are unknown beforehand.
        vm.expectEmit(false, true, false, false);
        emit PeripheryFactory.StrategyDeployed(address(0), STRAT_ID_1, address(0));

        address proxy = _deployProxy(STRAT_ID_1, admin);

        assertEq(factory.isRegisteredStrategy(proxy), true);
        assertEq(IContractId(proxy).ID(), STRAT_ID_1);
    }

    /// @dev OZ v5 TransparentUpgradeableProxy writes the ProxyAdmin address into the
    ///      ERC-1967 admin slot (0xb53127...6103) via ERC1967Utils.changeAdmin during
    ///      construction.  We use vm.load to read that slot and confirm our CREATE1
    ///      formula produces the identical address, making the formula a verified fact
    ///      rather than an unvalidated assumption.
    function testDeployStrategy_proxyAdminComputationMatchesERC1967Slot() public {
        address admin = makeAddr("stratAdmin");
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl);

        address proxy = _deployProxy(STRAT_ID_1, admin);
        address storedProxyAdmin = factory.getStrategyProxyAdmin(proxy);

        // Read the ERC-1967 admin slot directly from the proxy's storage.
        bytes32 ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        address slotValue = address(uint160(uint256(vm.load(proxy, ERC1967_ADMIN_SLOT))));

        // The factory's computed address must equal what OZ wrote into the slot.
        assertEq(storedProxyAdmin, slotValue, "CREATE1 formula mismatch with ERC1967 admin slot");

        // Also confirm the factory is the ProxyAdmin's owner.
        assertEq(ProxyAdmin(storedProxyAdmin).owner(), address(factory));
    }

    function testDeployStrategy_fails_ImplNotFound() public {
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.deployStrategy(STRAT_ID_1, "");
    }

    function testDeployStrategy_fails_Blocked() public {
        address admin = makeAddr("stratAdmin");
        address impl = address(new MockStrategyImpl(STRAT_ID_1));

        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl);
        factory.blockStrategyImpl(STRAT_ID_1);
        vm.stopPrank();

        vm.expectRevert(PeripheryFactory.ImplBlocked.selector);
        _deployProxy(STRAT_ID_1, admin);
    }

    function testDeployStrategy_fails_EmptyInitData() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));

        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl);

        vm.expectRevert(PeripheryFactory.InvalidInitData.selector);
        factory.deployStrategy(STRAT_ID_1, "");
    }

    // =========================================================================
    // STRATEGY — upgrade
    // =========================================================================

    function testUpgradeStrategy() public {
        address admin = makeAddr("stratAdmin");
        _approveStrats();

        vm.prank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);

        address proxy = _deployProxy(STRAT_ID_1, admin);

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.StrategyUpgraded(proxy, STRAT_ID_2);

        vm.prank(admin);
        factory.upgradeStrategy(proxy, STRAT_ID_2, "");

        assertEq(IContractId(proxy).ID(), STRAT_ID_2);
    }

    function testUpgradeStrategy_fails_NotRegistered() public {
        address nonProxy = makeAddr("nonProxy");
        vm.expectRevert(PeripheryFactory.NotRegistered.selector);
        factory.upgradeStrategy(nonProxy, STRAT_ID_2, "");
    }

    function testUpgradeStrategy_fails_NotStrategyUpgrader() public {
        address admin = makeAddr("stratAdmin");
        address nonUpgrader = makeAddr("nonUpgrader");
        _approveStrats();

        vm.prank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);

        address proxy = _deployProxy(STRAT_ID_1, admin);

        vm.prank(nonUpgrader);
        vm.expectRevert(PeripheryFactory.NotStrategyUpgrader.selector);
        factory.upgradeStrategy(proxy, STRAT_ID_2, "");
    }

    // ── Legacy (no ID()) upgrade path ─────────────────────────────────────────

    /// A caller with neither STRATEGY_ADMIN nor STRATEGY_UPGRADER is rejected on a legacy proxy.
    function testUpgradeStrategy_legacy_fails_NotStrategyUpgrader() public {
        address admin = makeAddr("stratAdmin");
        address nobody = makeAddr("nobody");

        address proxy = _deployAndRegisterLegacyProxy(admin);

        vm.prank(nobody);
        vm.expectRevert(PeripheryFactory.NotStrategyUpgrader.selector);
        factory.upgradeStrategy(proxy, STRAT_ID_2, "");
    }

    /// STRATEGY_ADMIN satisfies the legacy role check; downstream migration check fires next.
    function testUpgradeStrategy_legacy_strategyAdminPassesRoleCheck() public {
        address admin = makeAddr("stratAdmin");

        // Approve a sentinel impl with id=1 (the legacy catch-all) and the target impl.
        address legacySentinel = address(new MockStrategyImpl(1));
        address impl2 = address(new MockStrategyImpl(STRAT_ID_2));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(legacySentinel);
        factory.approveStrategyImpl(impl2);
        factory.setStrategyMigratable(1, STRAT_ID_2);
        vm.stopPrank();

        address proxy = _deployAndRegisterLegacyProxy(admin);

        // Admin holds STRATEGY_ADMIN → role check passes → migration proceeds.
        vm.prank(admin);
        factory.upgradeStrategy(proxy, STRAT_ID_2, "");

        // After upgrade the proxy runs MockStrategyImpl(STRAT_ID_2) which has ID().
        assertEq(IContractId(proxy).ID(), STRAT_ID_2);
    }

    function testUpgradeStrategy_fails_SameImpl() public {
        address admin = makeAddr("stratAdmin");
        address impl1 = address(new MockStrategyImpl(STRAT_ID_1));
        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl1);

        address proxy = _deployProxy(STRAT_ID_1, admin);

        vm.prank(admin);
        vm.expectRevert(PeripheryFactory.SameImpl.selector);
        factory.upgradeStrategy(proxy, STRAT_ID_1, "");
    }

    function testUpgradeStrategy_fails_CanNotMigrate() public {
        address admin = makeAddr("stratAdmin");
        _approveStrats();
        // No migration path set

        address proxy = _deployProxy(STRAT_ID_1, admin);

        vm.prank(admin);
        vm.expectRevert(PeripheryFactory.CanNotMigrate.selector);
        factory.upgradeStrategy(proxy, STRAT_ID_2, "");
    }

    function testUpgradeStrategy_fails_TargetBlocked() public {
        address admin = makeAddr("stratAdmin");
        _approveStrats();

        vm.startPrank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
        factory.blockStrategyImpl(STRAT_ID_2);
        vm.stopPrank();

        address proxy = _deployProxy(STRAT_ID_1, admin);

        vm.prank(admin);
        vm.expectRevert(PeripheryFactory.ImplBlocked.selector);
        factory.upgradeStrategy(proxy, STRAT_ID_2, "");
    }

    function testBatchUpgradeStrategies() public {
        address admin = makeAddr("stratAdmin");
        _approveStrats();

        vm.prank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);

        address[] memory proxies = new address[](2);
        proxies[0] = _deployProxy(STRAT_ID_1, admin);
        proxies[1] = _deployProxy(STRAT_ID_1, admin);

        bytes[] memory data = new bytes[](2);

        vm.prank(admin);
        factory.batchUpgradeStrategies(proxies, STRAT_ID_2, data);

        assertEq(IContractId(proxies[0]).ID(), STRAT_ID_2);
        assertEq(IContractId(proxies[1]).ID(), STRAT_ID_2);
    }

    function testBatchUpgradeStrategies_fails_InvalidDataLength() public {
        address[] memory proxies = new address[](2);
        bytes[] memory data = new bytes[](1);

        vm.expectRevert(PeripheryFactory.InvalidDataLength.selector);
        factory.batchUpgradeStrategies(proxies, STRAT_ID_2, data);
    }

    // =========================================================================
    // STRATEGY — deregistration
    // =========================================================================

    function testDeregisterStrategy_byOwner() public {
        address admin = makeAddr("stratAdmin");
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl);
        address proxy = _deployProxy(STRAT_ID_1, admin);
        address pa = factory.getStrategyProxyAdmin(proxy);

        address newOwner = makeAddr("newOwner");
        vm.prank(factoryOwner);
        factory.deregisterStrategy(proxy, newOwner);

        assertEq(factory.isRegisteredStrategy(proxy), false);
        assertEq(ProxyAdmin(pa).owner(), newOwner);
    }

    function testDeregisterStrategy_byStrategyAdmin() public {
        address admin = makeAddr("stratAdmin");
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl);
        address proxy = _deployProxy(STRAT_ID_1, admin);
        address pa = factory.getStrategyProxyAdmin(proxy);

        address newOwner = makeAddr("newOwner");
        vm.prank(admin); // admin holds STRATEGY_ADMIN on the proxy
        factory.deregisterStrategy(proxy, newOwner);

        assertEq(factory.isRegisteredStrategy(proxy), false);
        assertEq(ProxyAdmin(pa).owner(), newOwner);
    }

    function testDeregisterStrategy_fails_Unauthorized() public {
        address admin = makeAddr("stratAdmin");
        address stranger = makeAddr("stranger");
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.prank(factoryOwner);
        factory.approveStrategyImpl(impl);
        address proxy = _deployProxy(STRAT_ID_1, admin);

        vm.prank(stranger);
        vm.expectRevert(PeripheryFactory.Unauthorized.selector);
        factory.deregisterStrategy(proxy, stranger);
    }

    function testDeregisterStrategy_fails_NotRegistered() public {
        address stranger = makeAddr("stranger");
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.NotRegistered.selector);
        factory.deregisterStrategy(stranger, factoryOwner);
    }

    // =========================================================================
    // PMH — registration
    // =========================================================================

    function testApprovePMHImpl() public {
        address impl = address(new MockPMHImpl(PMH_ID_1));

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.PMHImplApproved(PMH_ID_1, impl);

        vm.prank(factoryOwner);
        factory.approvePMHImpl(impl);

        assertEq(factory.getPMHImpl(PMH_ID_1), impl);
    }

    function testApprovePMHImpl_fails_ZeroAddress() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.approvePMHImpl(address(0));
    }

    function testApprovePMHImpl_fails_ZeroId() public {
        address impl = address(new MockPMHImpl(0));
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ZeroImplId.selector);
        factory.approvePMHImpl(impl);
    }

    function testApprovePMHImpl_fails_AlreadyApproved() public {
        address impl = address(new MockPMHImpl(PMH_ID_1));
        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);
        vm.expectRevert(PeripheryFactory.ImplAlreadyApproved.selector);
        factory.approvePMHImpl(impl);
        vm.stopPrank();
    }

    function testBlockPMHImpl() public {
        address impl = address(new MockPMHImpl(PMH_ID_1));
        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);

        vm.expectEmit(true, false, false, false);
        emit PeripheryFactory.PMHImplBlocked(PMH_ID_1);

        factory.blockPMHImpl(PMH_ID_1);
        vm.stopPrank();

        assertEq(factory.isPMHImplBlocked(PMH_ID_1), true);
    }

    function testBlockPMHImpl_fails_NotFound() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.blockPMHImpl(PMH_ID_1);
    }

    function testBlockPMHImpl_fails_AlreadyBlocked() public {
        address impl = address(new MockPMHImpl(PMH_ID_1));
        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);
        factory.blockPMHImpl(PMH_ID_1);
        vm.expectRevert(PeripheryFactory.AlreadyBlocked.selector);
        factory.blockPMHImpl(PMH_ID_1);
        vm.stopPrank();
    }

    // =========================================================================
    // PMH — cloning
    // =========================================================================

    function testClonePMH_fails_EmptyInitData() public {
        address positionOwner = makeAddr("positionOwner");
        ERC20Mock collateral = new ERC20Mock();
        ERC20Mock borrow = new ERC20Mock();
        address impl = address(new MockPMHImpl(PMH_ID_1));

        vm.prank(factoryOwner);
        factory.approvePMHImpl(impl);

        vm.expectRevert(PeripheryFactory.InvalidInitData.selector);
        factory.clonePMH(PMH_ID_1, positionOwner, address(collateral), address(borrow), "");
    }

    function testClonePMH_success_WithValidInitData() public {
        address positionOwner = makeAddr("positionOwner");
        ERC20Mock collateral = new ERC20Mock();
        ERC20Mock borrow = new ERC20Mock();
        address impl = address(new MockPMHImpl(PMH_ID_1));

        vm.prank(factoryOwner);
        factory.approvePMHImpl(impl);

        bytes memory initData = abi.encodeCall(
            PositionHelperAaveV3.initialize,
            (
                makeAddr("admin"),
                makeAddr("operator"),
                makeAddr("yieldVault"),
                makeAddr("flashModule"),
                makeAddr("swapModule"),
                0.7e18, // healthyLtvInWad (70%)
                0.05e18, // healthyLtvDeviationInWad (5%)
                0.02e18 // selfLiqThrBufferInWad (2%)
            )
        );

        // Only verify indexed implId and positionOwner; clone address is unknown beforehand.
        vm.expectEmit(false, true, true, false);
        emit PeripheryFactory.PMHCloned(address(0), PMH_ID_1, positionOwner);

        address clone = factory.clonePMH(PMH_ID_1, positionOwner, address(collateral), address(borrow), initData);

        assertEq(factory.isRegisteredPMHClone(clone), true);
        // ID() on the clone delegates to the impl.
        assertEq(IContractId(clone).ID(), PMH_ID_1);
    }

    function testClonePMH_fails_ZeroPositionOwner() public {
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.clonePMH(PMH_ID_1, address(0), makeAddr("col"), makeAddr("borrow"), "");
    }

    function testClonePMH_fails_ZeroCollateral() public {
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.clonePMH(PMH_ID_1, makeAddr("owner"), address(0), makeAddr("borrow"), "");
    }

    function testClonePMH_fails_ZeroBorrow() public {
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.clonePMH(PMH_ID_1, makeAddr("owner"), makeAddr("col"), address(0), "");
    }

    function testClonePMH_fails_ImplNotFound() public {
        ERC20Mock collateral = new ERC20Mock();
        ERC20Mock borrow = new ERC20Mock();
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.clonePMH(PMH_ID_1, makeAddr("owner"), address(collateral), address(borrow), "");
    }

    function testClonePMH_fails_Blocked() public {
        ERC20Mock collateral = new ERC20Mock();
        ERC20Mock borrow = new ERC20Mock();
        address impl = address(new MockPMHImpl(PMH_ID_1));

        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);
        factory.blockPMHImpl(PMH_ID_1);
        vm.stopPrank();

        vm.expectRevert(PeripheryFactory.ImplBlocked.selector);
        factory.clonePMH(PMH_ID_1, makeAddr("owner"), address(collateral), address(borrow), "");
    }

    function testClonePMHReadsDecimalsFromTokens() public {
        address positionOwner = makeAddr("positionOwner");
        // ERC20 default is 18 decimals; factory reads decimals() to build immutable args.
        ERC20Mock collateral = new ERC20Mock();
        ERC20Mock borrow = new ERC20Mock();
        address impl = address(new MockPMHImpl(PMH_ID_1));

        vm.prank(factoryOwner);
        factory.approvePMHImpl(impl);

        bytes memory initData = abi.encodeCall(
            PositionHelperAaveV3.initialize,
            (
                makeAddr("admin"),
                makeAddr("operator"),
                makeAddr("yieldVault"),
                makeAddr("flashModule"),
                makeAddr("swapModule"),
                0.7e18, // healthyLtvInWad (70%)
                0.05e18, // healthyLtvDeviationInWad (5%)
                0.02e18 // selfLiqThrBufferInWad (2%)
            )
        );

        address clone = factory.clonePMH(PMH_ID_1, positionOwner, address(collateral), address(borrow), initData);
        assertNotEq(clone, address(0));
    }

    // ============================================================================
    // TWO-STEP OWNERSHIP TESTS
    // ============================================================================

    function test_transferOwnership_setsPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        assertEq(factory.owner(), factoryOwner);
        assertEq(Ownable2StepUpgradeable(address(factory)).pendingOwner(), address(0));

        vm.expectEmit(true, true, false, false);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(factoryOwner, newOwner);

        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        // owner unchanged until accepted
        assertEq(factory.owner(), factoryOwner);
        assertEq(Ownable2StepUpgradeable(address(factory)).pendingOwner(), newOwner);
    }

    function test_acceptOwnership_completesTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, false);
        emit OwnableUpgradeable.OwnershipTransferred(factoryOwner, newOwner);

        vm.prank(newOwner);
        Ownable2StepUpgradeable(address(factory)).acceptOwnership();

        assertEq(factory.owner(), newOwner);
        assertEq(Ownable2StepUpgradeable(address(factory)).pendingOwner(), address(0));
    }

    function test_transferOwnership_revertsForNonOwner() public {
        address newOwner = makeAddr("newOwner");
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        factory.transferOwnership(newOwner);
    }

    function test_acceptOwnership_revertsForNonPendingOwner() public {
        address newOwner = makeAddr("newOwner");
        address nonOwner = makeAddr("nonOwner");

        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        Ownable2StepUpgradeable(address(factory)).acceptOwnership();
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.RenounceOwnershipDisabled.selector);
        factory.renounceOwnership();
    }

    // ============================================================================
    // FACTORY MANAGER ROLE TESTS
    // ============================================================================

    function testFactoryManager_defaultsToOwner() public view {
        assertEq(factory.getFactoryManager(), factoryOwner);
    }

    function testSetFactoryManager_byOwner() public {
        address manager = makeAddr("factoryManager");

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.FactoryManagerSet(factoryOwner, manager);

        vm.prank(factoryOwner);
        factory.setFactoryManager(manager);

        assertEq(factory.getFactoryManager(), manager);
    }

    function testSetFactoryManager_revertsForNonOwner() public {
        address manager = makeAddr("factoryManager");
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFactoryManager(manager);
    }

    function testSetFactoryManager_revertsZeroAddress() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.setFactoryManager(address(0));
    }

    /// @dev Delegate the manager role to a distinct address for the separation tests.
    function _delegateManager() internal returns (address manager) {
        manager = makeAddr("factoryManager");
        vm.prank(factoryOwner);
        factory.setFactoryManager(manager);
    }

    function testManager_canApproveAndBlockStrategyImpl() public {
        address manager = _delegateManager();
        address impl = address(new MockStrategyImpl(STRAT_ID_1));

        vm.startPrank(manager);
        factory.approveStrategyImpl(impl);
        assertEq(factory.getStrategyImpl(STRAT_ID_1), impl);

        factory.blockStrategyImpl(STRAT_ID_1);
        assertTrue(factory.isStrategyImplBlocked(STRAT_ID_1));
        vm.stopPrank();
    }

    function testManager_canSetStrategyMigratable() public {
        address manager = _delegateManager();
        address impl1 = address(new MockStrategyImpl(STRAT_ID_1));
        address impl2 = address(new MockStrategyImpl(STRAT_ID_2));

        vm.startPrank(manager);
        factory.approveStrategyImpl(impl1);
        factory.approveStrategyImpl(impl2);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
        vm.stopPrank();

        assertTrue(factory.isStrategyMigratable(STRAT_ID_1, STRAT_ID_2));
    }

    function testManager_canRegisterStrategy() public {
        address manager = _delegateManager();
        address proxy = makeAddr("externalProxy");

        vm.prank(manager);
        factory.registerStrategy(proxy, address(0));

        assertTrue(factory.isRegisteredStrategy(proxy));
    }

    function testManager_canApproveAndBlockPMHImpl() public {
        address manager = _delegateManager();
        address impl = address(new MockPMHImpl(PMH_ID_1));

        vm.startPrank(manager);
        factory.approvePMHImpl(impl);
        assertEq(factory.getPMHImpl(PMH_ID_1), impl);

        factory.blockPMHImpl(PMH_ID_1);
        assertTrue(factory.isPMHImplBlocked(PMH_ID_1));
        vm.stopPrank();
    }

    function testManager_canApproveAndBlockHookImpl() public {
        address manager = _delegateManager();
        address impl = address(new MockHookImpl(HOOK_ID_1));

        vm.startPrank(manager);
        factory.approveHookImpl(impl);
        assertEq(factory.getHookImpl(HOOK_ID_1), impl);

        factory.blockHookImpl(HOOK_ID_1);
        assertTrue(factory.isHookImplBlocked(HOOK_ID_1));
        vm.stopPrank();
    }

    /// @dev Strict separation: once delegated, the owner can no longer call manager functions.
    function testOwner_cannotCallManagerFunctions_afterDelegation() public {
        _delegateManager();
        address impl = address(new MockStrategyImpl(STRAT_ID_1));

        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.approveStrategyImpl(impl);
    }

    function testManagerFunctions_revertForNonManager() public {
        _delegateManager();
        address stranger = makeAddr("stranger");
        address impl = address(new MockStrategyImpl(STRAT_ID_1));

        vm.startPrank(stranger);
        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.approveStrategyImpl(impl);

        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.blockStrategyImpl(STRAT_ID_1);

        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);

        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.registerStrategy(makeAddr("proxy"), address(0));

        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.approvePMHImpl(impl);

        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.blockPMHImpl(PMH_ID_1);

        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.approveHookImpl(impl);

        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.blockHookImpl(HOOK_ID_1);
        vm.stopPrank();
    }

    // ============================================================================
    // UNBLOCK / UNSET-MIGRATABLE
    // ============================================================================

    function testUnblockStrategyImpl() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl);
        factory.blockStrategyImpl(STRAT_ID_1);
        assertTrue(factory.isStrategyImplBlocked(STRAT_ID_1));

        vm.expectEmit(true, false, false, false);
        emit PeripheryFactory.StrategyImplUnblocked(STRAT_ID_1);
        factory.unblockStrategyImpl(STRAT_ID_1);
        vm.stopPrank();

        assertFalse(factory.isStrategyImplBlocked(STRAT_ID_1));
    }

    function testUnblockStrategyImpl_fails_NotFound() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.unblockStrategyImpl(STRAT_ID_1);
    }

    function testUnblockStrategyImpl_fails_NotBlocked() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl);
        vm.expectRevert(PeripheryFactory.NotBlocked.selector);
        factory.unblockStrategyImpl(STRAT_ID_1);
        vm.stopPrank();
    }

    function testUnblockStrategyImpl_revertsForNonOwner() public {
        address impl = address(new MockStrategyImpl(STRAT_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveStrategyImpl(impl);
        factory.blockStrategyImpl(STRAT_ID_1);
        vm.stopPrank();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.unblockStrategyImpl(STRAT_ID_1);
    }

    function testUnblockPMHImpl() public {
        address impl = address(new MockPMHImpl(PMH_ID_1));
        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);
        factory.blockPMHImpl(PMH_ID_1);
        assertTrue(factory.isPMHImplBlocked(PMH_ID_1));

        vm.expectEmit(true, false, false, false);
        emit PeripheryFactory.PMHImplUnblocked(PMH_ID_1);
        factory.unblockPMHImpl(PMH_ID_1);
        vm.stopPrank();

        assertFalse(factory.isPMHImplBlocked(PMH_ID_1));
    }

    function testUnblockPMHImpl_fails_NotFound() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.unblockPMHImpl(PMH_ID_1);
    }

    function testUnblockPMHImpl_fails_NotBlocked() public {
        address impl = address(new MockPMHImpl(PMH_ID_1));
        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);
        vm.expectRevert(PeripheryFactory.NotBlocked.selector);
        factory.unblockPMHImpl(PMH_ID_1);
        vm.stopPrank();
    }

    function testUnblockPMHImpl_revertsForNonOwner() public {
        address impl = address(new MockPMHImpl(PMH_ID_1));
        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);
        factory.blockPMHImpl(PMH_ID_1);
        vm.stopPrank();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.unblockPMHImpl(PMH_ID_1);
    }

    function testUnblockPMHImpl_reEnablesClone() public {
        ERC20Mock collateral = new ERC20Mock();
        ERC20Mock borrow = new ERC20Mock();
        address impl = address(new MockPMHImpl(PMH_ID_1));
        address positionOwner = makeAddr("positionOwner");
        bytes memory initData = abi.encodeCall(
            PositionHelperAaveV3.initialize,
            (
                makeAddr("admin"),
                makeAddr("operator"),
                makeAddr("yieldVault"),
                makeAddr("flashModule"),
                makeAddr("swapModule"),
                0.7e18,
                0.05e18,
                0.02e18
            )
        );

        vm.startPrank(factoryOwner);
        factory.approvePMHImpl(impl);
        factory.blockPMHImpl(PMH_ID_1);
        vm.stopPrank();

        vm.expectRevert(PeripheryFactory.ImplBlocked.selector);
        factory.clonePMH(PMH_ID_1, positionOwner, address(collateral), address(borrow), initData);

        vm.prank(factoryOwner);
        factory.unblockPMHImpl(PMH_ID_1);

        address clone = factory.clonePMH(PMH_ID_1, positionOwner, address(collateral), address(borrow), initData);
        assertEq(factory.isRegisteredPMHClone(clone), true);
    }

    function testUnblockHookImpl() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);
        factory.blockHookImpl(HOOK_ID_1);
        assertTrue(factory.isHookImplBlocked(HOOK_ID_1));

        vm.expectEmit(true, false, false, false);
        emit PeripheryFactory.HookImplUnblocked(HOOK_ID_1);
        factory.unblockHookImpl(HOOK_ID_1);
        vm.stopPrank();

        assertFalse(factory.isHookImplBlocked(HOOK_ID_1));
    }

    function testUnblockHookImpl_fails_NotFound() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.unblockHookImpl(HOOK_ID_1);
    }

    function testUnblockHookImpl_fails_NotBlocked() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);
        vm.expectRevert(PeripheryFactory.NotBlocked.selector);
        factory.unblockHookImpl(HOOK_ID_1);
        vm.stopPrank();
    }

    function testUnblockHookImpl_revertsForNonOwner() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);
        factory.blockHookImpl(HOOK_ID_1);
        vm.stopPrank();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.unblockHookImpl(HOOK_ID_1);
    }

    function testUnblockHookImpl_reEnablesClone() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        bytes memory initData = abi.encodeCall(MockHookImpl.initialize, (makeAddr("hookOwner")));

        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);
        factory.blockHookImpl(HOOK_ID_1);
        vm.stopPrank();

        vm.expectRevert(PeripheryFactory.ImplBlocked.selector);
        factory.cloneHook(HOOK_ID_1, makeAddr("v"), initData);

        vm.prank(factoryOwner);
        factory.unblockHookImpl(HOOK_ID_1);

        address clone = factory.cloneHook(HOOK_ID_1, makeAddr("v"), initData);
        assertEq(factory.isRegisteredHookClone(clone), true);
    }

    function testUnsetStrategyMigratable() public {
        _approveStrats();
        vm.startPrank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
        assertTrue(factory.isStrategyMigratable(STRAT_ID_1, STRAT_ID_2));

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.StrategyMigratableUnset(STRAT_ID_1, STRAT_ID_2);
        factory.unsetStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
        vm.stopPrank();

        assertFalse(factory.isStrategyMigratable(STRAT_ID_1, STRAT_ID_2));
    }

    function testUnsetStrategyMigratable_fails_NotMigratable() public {
        _approveStrats();
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.NotMigratable.selector);
        factory.unsetStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
    }

    function testUnsetStrategyMigratable_byManager() public {
        address manager = _delegateManager();
        address impl1 = address(new MockStrategyImpl(STRAT_ID_1));
        address impl2 = address(new MockStrategyImpl(STRAT_ID_2));

        vm.startPrank(manager);
        factory.approveStrategyImpl(impl1);
        factory.approveStrategyImpl(impl2);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
        factory.unsetStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
        vm.stopPrank();

        assertFalse(factory.isStrategyMigratable(STRAT_ID_1, STRAT_ID_2));
    }

    function testUnsetStrategyMigratable_revertsForNonManager() public {
        _approveStrats();
        vm.prank(factoryOwner);
        factory.setStrategyMigratable(STRAT_ID_1, STRAT_ID_2);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.unsetStrategyMigratable(STRAT_ID_1, STRAT_ID_2);
    }

    // =========================================================================
    // HOOK — registration
    // =========================================================================

    function testApproveHookImpl() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));

        vm.expectEmit(true, true, false, false);
        emit PeripheryFactory.HookImplApproved(HOOK_ID_1, impl);

        vm.prank(factoryOwner);
        factory.approveHookImpl(impl);

        assertEq(factory.getHookImpl(HOOK_ID_1), impl);
    }

    function testApproveHookImpl_fails_ZeroAddress() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.approveHookImpl(address(0));
    }

    function testApproveHookImpl_fails_ZeroId() public {
        address impl = address(new MockHookImpl(0));
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ZeroImplId.selector);
        factory.approveHookImpl(impl);
    }

    function testApproveHookImpl_fails_AlreadyApproved() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);
        vm.expectRevert(PeripheryFactory.ImplAlreadyApproved.selector);
        factory.approveHookImpl(impl);
        vm.stopPrank();
    }

    function testApproveHookImpl_fails_NonManager() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PeripheryFactory.NotFactoryManager.selector);
        factory.approveHookImpl(impl);
    }

    function testBlockHookImpl() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);

        vm.expectEmit(true, false, false, false);
        emit PeripheryFactory.HookImplBlocked(HOOK_ID_1);

        factory.blockHookImpl(HOOK_ID_1);
        vm.stopPrank();

        assertEq(factory.isHookImplBlocked(HOOK_ID_1), true);
    }

    function testBlockHookImpl_fails_NotFound() public {
        vm.prank(factoryOwner);
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.blockHookImpl(HOOK_ID_1);
    }

    function testBlockHookImpl_fails_AlreadyBlocked() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);
        factory.blockHookImpl(HOOK_ID_1);
        vm.expectRevert(PeripheryFactory.AlreadyBlocked.selector);
        factory.blockHookImpl(HOOK_ID_1);
        vm.stopPrank();
    }

    // =========================================================================
    // HOOK — cloning
    // =========================================================================

    function testCloneHook_success_WithValidInitData() public {
        address owner = makeAddr("hookOwner");
        address vault = makeAddr("hookVault");
        address impl = address(new MockHookImpl(HOOK_ID_1));

        vm.prank(factoryOwner);
        factory.approveHookImpl(impl);

        bytes memory initData = abi.encodeCall(MockHookImpl.initialize, (owner));

        // Clone address is unknown beforehand; only verify the indexed implId.
        vm.expectEmit(false, true, false, false);
        emit PeripheryFactory.HookCloned(address(0), HOOK_ID_1);

        address clone = factory.cloneHook(HOOK_ID_1, vault, initData);

        assertEq(factory.isRegisteredHookClone(clone), true);
        assertEq(IContractId(clone).ID(), HOOK_ID_1);
        assertEq(MockHookImpl(clone).initialized(), true);
        assertEq(MockHookImpl(clone).owner(), owner);
        assertEq(MockHookImpl(clone).vaultAddr(), vault);
        // The factory must embed its own address as the first immutable arg (offset 0).
        assertEq(MockHookImpl(clone).FACTORY(), address(factory));
    }

    /// @notice A clone whose embedded factory differs from the caller must reject
    ///         initialization with NotFactory, preventing a third party from front-running
    ///         the initialization of a freshly-deployed clone.
    function testCloneHook_initializeByNonFactoryReverts() public {
        MockHookImpl impl = new MockHookImpl(HOOK_ID_1);
        address vault = makeAddr("hookVault");

        // Clone manually embedding the real factory as the authorized initializer.
        address clone = ClonesWithImmutableArgs.clone(address(impl), abi.encodePacked(address(factory), vault));

        // An attacker (not the embedded factory) cannot initialize the clone.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(MockHookImpl.NotFactory.selector);
        MockHookImpl(clone).initialize(makeAddr("hookOwner"));
    }

    function testCloneHook_fails_EmptyInitData() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.prank(factoryOwner);
        factory.approveHookImpl(impl);

        vm.expectRevert(PeripheryFactory.InvalidInitData.selector);
        factory.cloneHook(HOOK_ID_1, makeAddr("v"), "");
    }

    function testCloneHook_fails_ImplNotFound() public {
        bytes memory initData = abi.encodeCall(MockHookImpl.initialize, (makeAddr("o")));
        vm.expectRevert(PeripheryFactory.ImplNotFound.selector);
        factory.cloneHook(HOOK_ID_1, makeAddr("v"), initData);
    }

    function testCloneHook_fails_Blocked() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.startPrank(factoryOwner);
        factory.approveHookImpl(impl);
        factory.blockHookImpl(HOOK_ID_1);
        vm.stopPrank();

        bytes memory initData = abi.encodeCall(MockHookImpl.initialize, (makeAddr("o")));
        vm.expectRevert(PeripheryFactory.ImplBlocked.selector);
        factory.cloneHook(HOOK_ID_1, makeAddr("v"), initData);
    }

    function testCloneHook_fails_ZeroVault() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.prank(factoryOwner);
        factory.approveHookImpl(impl);
        bytes memory initData = abi.encodeCall(MockHookImpl.initialize, (makeAddr("o")));
        vm.expectRevert(PeripheryFactory.ZeroAddress.selector);
        factory.cloneHook(HOOK_ID_1, address(0), initData);
    }

    function testCloneHook_bubblesInitializerRevert() public {
        address impl = address(new MockHookImpl(HOOK_ID_1));
        vm.prank(factoryOwner);
        factory.approveHookImpl(impl);

        // Zero owner makes MockHookImpl.initialize revert with HookZeroOwner.
        bytes memory initData = abi.encodeCall(MockHookImpl.initialize, (address(0)));
        vm.expectRevert(MockHookImpl.HookZeroOwner.selector);
        factory.cloneHook(HOOK_ID_1, makeAddr("v"), initData);
    }
}
