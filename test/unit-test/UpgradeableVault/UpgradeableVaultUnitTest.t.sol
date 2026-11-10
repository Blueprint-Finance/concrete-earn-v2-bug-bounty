// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UpgradeableVault} from "../../../src/common/UpgradeableVault.sol";

import {IUpgradeableVault} from "../../../src/interface/IUpgradeableVault.sol";

import {IDefaultEnforcedVaultConfiguration} from "../../../src/interface/IDefaultEnforcedVaultConfiguration.sol";

import {VaultProxy} from "../../../src/factory/VaultProxy.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";

import {ContractIdEncoding} from "../../../src/lib/ContractIdEncoding.sol";
import {IContractId} from "../../../src/interface/IContractId.sol";

contract UpgradeableVaultUnitTest is Test {
    UpgradeableVaultImpl public upgradeableVault;
    address public owner = makeAddr("owner");
    address public protocolConfig = makeAddr("protocolConfig");
    bytes public data = "";
    IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration public defaultEnforcedVaultConfig;

    function setUp() public {
        upgradeableVault = new UpgradeableVaultImpl(address(this));
        defaultEnforcedVaultConfig = IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration({
            defaultManagementFeeRecipient: address(0), defaultPerformanceFeeRecipient: address(0)
        });
    }

    function testInitializeRevertsIfNotFactory() public {
        uint64 vaultImpl = uint64(IContractId(address(upgradeableVault)).ID());
        vm.expectRevert(abi.encodeWithSelector(IUpgradeableVault.NotFactory.selector));
        vm.prank(address(1));
        new VaultProxy(
            address(upgradeableVault),
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
        );
    }

    function testUpgradeEmitsEvent() public {
        uint64 vaultImpl = uint64(IContractId(address(upgradeableVault)).ID());
        address vault = address(
            new VaultProxy(
                address(upgradeableVault),
                abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, owner, defaultEnforcedVaultConfig, data))
            )
        );

        // Create new implementations with different IDs for upgrade testing
        UpgradeableVaultImpl2 impl2 = new UpgradeableVaultImpl2(address(this));
        UpgradeableVaultImpl3 impl3 = new UpgradeableVaultImpl3(address(this));
        uint64 vaultImpl2 = uint64(IContractId(address(impl2)).ID());
        uint64 vaultImpl3 = uint64(IContractId(address(impl3)).ID());

        // Upgrade proxy to impl2 first, then call upgrade function
        // Since address(this) is the factory and proxy admin, we can upgrade and call
        vm.expectEmit(true, true, true, true);
        emit UpgradeableVaultEvents.UpgradeEvent(vaultImpl2, data);
        VaultProxy(payable(vault))
            .upgradeToAndCall(address(impl2), abi.encodeCall(IUpgradeableVault.upgrade, (vaultImpl2, data)));

        // Verify version is updated after upgrade (version() returns the initialized version, which is now vaultImpl2)
        assertEq(IContractId(vault).ID(), vaultImpl2, "Version should be updated after upgrade");

        // Upgrade proxy to impl3 and call upgrade function
        vm.expectEmit(true, true, true, true);
        emit UpgradeableVaultEvents.UpgradeEvent(vaultImpl3, data);
        VaultProxy(payable(vault))
            .upgradeToAndCall(address(impl3), abi.encodeCall(IUpgradeableVault.upgrade, (vaultImpl3, data)));

        // Verify version is updated again
        assertEq(IContractId(vault).ID(), vaultImpl3, "Version should be updated after second upgrade");
    }
}

library UpgradeableVaultEvents {
    event UpgradeEvent(uint64 newVersion, bytes data);
}

contract UpgradeableVaultImpl is UpgradeableVault {
    constructor(address factory) UpgradeableVault(factory) {}

    // override _upgrade with an event
    function _upgrade(uint64 newVersion, bytes calldata data) internal override {
        emit UpgradeableVaultEvents.UpgradeEvent(newVersion, data);
    }

    function ID() public pure override returns (uint64) {
        return ContractIdEncoding.encode(
            0,
            /* contractType=vault */
            1,
            /* flavour=standard-vault */
            9,
            /* majorVersion=9 (test) */
            99,
            /* minorVersion=99 (test) */
            99 /* patchVersion=99 (test) */
        );
    }
}

contract UpgradeableVaultImpl2 is UpgradeableVault {
    constructor(address factory) UpgradeableVault(factory) {}

    function _upgrade(uint64 newVersion, bytes calldata data) internal override {
        emit UpgradeableVaultEvents.UpgradeEvent(newVersion, data);
    }

    function ID() public pure override returns (uint64) {
        return ContractIdEncoding.encode(
            0,
            /* contractType=vault */
            1,
            /* flavour=standard-vault */
            9,
            /* majorVersion=9 (test) */
            99,
            /* minorVersion=99 (test) */
            98 /* patchVersion=98 (test) - different from Impl */
        );
    }
}

contract UpgradeableVaultImpl3 is UpgradeableVault {
    constructor(address factory) UpgradeableVault(factory) {}

    function _upgrade(uint64 newVersion, bytes calldata data) internal override {
        emit UpgradeableVaultEvents.UpgradeEvent(newVersion, data);
    }

    function ID() public pure override returns (uint64) {
        return ContractIdEncoding.encode(
            0,
            /* contractType=vault */
            1,
            /* flavour=standard-vault */
            9,
            /* majorVersion=9 (test) */
            99,
            /* minorVersion=99 (test) */
            97 /* patchVersion=97 (test) - different from Impl and Impl2 */
        );
    }
}
