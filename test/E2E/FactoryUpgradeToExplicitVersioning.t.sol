import {ConcreteFactory as ConcreteFactoryV2} from "../../src/factory/ConcreteFactory.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin-contracts/proxy/transparent/ProxyAdmin.sol";
// import {ITransparentUpgradeableProxy} from "@openzeppelin-contracts/proxy/transparent/ITransparentUpgradeableProxy.sol";
import {IConcreteFactory} from "../../src/interface/IConcreteFactory.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {IUpgradeableVault} from "../../src/interface/IUpgradeableVault.sol";
import {UpgradeableVault} from "../../src/common/UpgradeableVault.sol";
import {IContractId} from "../../src/interface/IContractId.sol";
import {ConcreteStandardVaultImpl} from "../../src/implementation/ConcreteStandardVaultImpl.sol";
import {ConcretePredepositVaultImpl} from "../../src/implementation/ConcretePredepositVaultImpl.sol";

contract FactoryUpgradeToExplicitVersioning is Test {
    address constant FACTORY_ADDRESS = 0x0265d73a8E61F698d8EB0dfeb91Ddce55516844C;
    ProxyAdmin constant PROXY_ADMIN = ProxyAdmin(0xB255f93cD104Abc2C703aEb693580333D37ab784);
    address ALLOCATE_MODULE_ADDRESS = 0x14A905158aebcb44451857603006a7dc23B0D014;
    address ASSET_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address VAULT_ADDRESS = 0x6503de9FE77d256d9d823f2D335Ce83EcE9E153f;
    uint256 constant LAST_VERSION_BEFORE_UPGRADE = 6;

    address newFactoryImplementation;
    address factoryOwner;
    address factoryProxyAdminOwner;
    address admin;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, 24280000);
        vm.selectFork(forkId);

        factoryOwner = Ownable(FACTORY_ADDRESS).owner();
        factoryProxyAdminOwner = PROXY_ADMIN.owner();

        admin = makeAddr("vaultAdmin");
        vm.label(admin, "vaultAdmin");
        vm.label(factoryOwner, "factoryOwner");
        vm.label(FACTORY_ADDRESS, "factory");
        vm.label(newFactoryImplementation, "newFactoryImplementation");
        vm.label(factoryProxyAdminOwner, "factoryProxyAdminOwner");
        vm.label(address(PROXY_ADMIN), "proxyAdminContract");

        newFactoryImplementation = address(new ConcreteFactoryV2());
    }

    function _upgradeFactory() public {
        vm.startPrank(factoryProxyAdminOwner);
        // pass zero ether
        // proxy address, i.e. factory address,
        // implementation address, i.e. new factory implementation address
        // data, i.e. empty bytes
        PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(FACTORY_ADDRESS), newFactoryImplementation, "");
        vm.stopPrank();
    }

    function test_legacyVersioningStillSupported() public {
        //
        _upgradeFactory();
        // check that all versions until and including LAST_VERSION_BEFORE_UPGRADE are still supported
        address implementation;
        string memory errorMessage;
        for (uint64 i = 1; uint256(i) <= LAST_VERSION_BEFORE_UPGRADE; i++) {
            implementation = IConcreteFactory(FACTORY_ADDRESS).getImplementationByVaultImpl(i);
            errorMessage = "Should have implementation for version.";
            assertTrue(implementation != address(0), errorMessage);
        }
    }

    function test_predictAddressDifferBeforeAndAfterUpgrade() public {
        // predict address of new factory
        bytes memory data = abi.encode(ALLOCATE_MODULE_ADDRESS, ASSET_ADDRESS, admin, "Concrete Example Vault", "ABC");
        address predictedAddressBeforeUpgrade = IConcreteFactory(FACTORY_ADDRESS).predictVaultAddress(3, admin, data);
        // upgrade factory
        _upgradeFactory();

        address predictedAddressAfterUpgrade = IConcreteFactory(FACTORY_ADDRESS).predictVaultAddress(3, admin, data);
        assertNotEq(
            predictedAddressBeforeUpgrade,
            predictedAddressAfterUpgrade,
            "Predicted address should be different after upgrade"
        );
    }

    function test_upgradeVaultAfterFactoryUpgrade() public {
        // register another vault in the old factory
        // get lastVersion() from the old factory
        uint64 expectedNewVersion = IConcreteFactory(FACTORY_ADDRESS).lastVersion() + 1;
        address hypotheticalPredepositVaultImpl = address(new HypotheticalPredepositVault(FACTORY_ADDRESS));
        vm.startPrank(factoryOwner);
        IConcreteFactory(FACTORY_ADDRESS).approveImplementation(hypotheticalPredepositVaultImpl);
        IConcreteFactory(FACTORY_ADDRESS).setMigratable(3, expectedNewVersion);
        vm.stopPrank();

        // upgrade factory
        _upgradeFactory();
        // The new implementation gates approveImplementation/setMigratable behind the
        // FACTORY_MANAGER role, which is unset (address(0)) after an upgrade. The owner
        // must assign it before manager-gated calls can be made.
        vm.prank(factoryOwner);
        IConcreteFactory(FACTORY_ADDRESS).setFactoryManager(factoryOwner);
        // upgrade vault
        // expect revert because its the same as the old vault id
        address vaultOwner = Ownable(VAULT_ADDRESS).owner();
        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(IConcreteFactory.OldVersion.selector));
        IConcreteFactory(FACTORY_ADDRESS)
            .upgrade(
                VAULT_ADDRESS,
                3,
                abi.encode(ALLOCATE_MODULE_ADDRESS, ASSET_ADDRESS, admin, "Concrete Example Vault", "ABC")
            );

        // upgrade to vault version 4
        vm.prank(vaultOwner);
        // expect revert because that version doesnt allow upgrading into it. Its just a revert(); invokation. Dont know how to check that, no specific message
        vm.expectRevert();
        IConcreteFactory(FACTORY_ADDRESS)
            .upgrade(
                VAULT_ADDRESS,
                4,
                abi.encode(ALLOCATE_MODULE_ADDRESS, ASSET_ADDRESS, admin, "Concrete Example Vault", "ABC")
            );

        // upgrade to version lastVersion() + 1
        vm.prank(vaultOwner);
        IConcreteFactory(FACTORY_ADDRESS)
            .upgrade(
                VAULT_ADDRESS,
                expectedNewVersion,
                abi.encode(ALLOCATE_MODULE_ADDRESS, ASSET_ADDRESS, admin, "Concrete Example Predeposit Vault", "ABC")
            );
        // expect the call of the current version (IUpgradeableVault.version() to yield lastVersion + 1)
        vm.assertEq(HypotheticalPredepositVault(VAULT_ADDRESS).ANSWER(), 42, "Vault should be upgraded.");

        // check that the vault is upgraded to version 4
        // finally register the new vault id
        address hypotheticalVaultImplAddr = address(new HypotheticalVault(FACTORY_ADDRESS));
        uint64 hypotheticalVaultImpl = uint64(IContractId(hypotheticalVaultImplAddr).ID());
        vm.startPrank(factoryOwner);
        IConcreteFactory(FACTORY_ADDRESS).approveImplementation(hypotheticalVaultImplAddr);
        IConcreteFactory(FACTORY_ADDRESS).setMigratable(expectedNewVersion, hypotheticalVaultImpl);
        vm.stopPrank();
        vm.prank(vaultOwner);
        IConcreteFactory(FACTORY_ADDRESS)
            .upgrade(
                VAULT_ADDRESS,
                hypotheticalVaultImpl,
                abi.encode(ALLOCATE_MODULE_ADDRESS, ASSET_ADDRESS, admin, "Concrete Example Vault", "ABC")
            );
        // check that the vault is upgraded to the new vault id
        assertEq(IContractId(VAULT_ADDRESS).ID(), hypotheticalVaultImpl);
    }
}

contract HypotheticalPredepositVault is ConcretePredepositVaultImpl {
    string public greeting;
    uint256 public ANSWER;

    constructor(address factory) ConcretePredepositVaultImpl(factory) {
        greeting = "I'm very different from the Predeposit Vault";
    }

    /**
     * @dev Upgrade function that will be called when a proxy vault upgrades to this implementation
     */
    function _upgrade(
        uint64,
        /* newVaultImpl */
        bytes calldata /* data */
    )
        internal
        override(ConcretePredepositVaultImpl)
    {
        // doenst need much upgrading
        ANSWER = 42;
    }

    // override the ID() function to match the expected version
    function ID() public pure override returns (uint64) {
        return uint64(7);
    }
}

contract HypotheticalVault is ConcreteStandardVaultImpl {
    constructor(address factory) ConcreteStandardVaultImpl(factory) {}

    function ID() public pure override returns (uint64) {
        return uint64(199999);
        // return ContractIdEncoding.encode(
        //     0,
        //     /* contractType=vault */
        //     1,
        //     /* flavour=standard-vault */
        //     9,
        //     /* majorVersion=1 (test) */
        //     99,
        //     /* minorVersion=1 (test) */
        //     99 /* patchVersion=1 (test) */
        // );
    }

    function _upgrade(
        uint64,
        /* newVersion */
        bytes calldata /* data */
    )
        internal
        virtual
        override(ConcreteStandardVaultImpl)
    {
        // fa niente
    }
}
