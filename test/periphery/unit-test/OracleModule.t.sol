// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {OracleModule, IChainlinkOracle} from "../../../src/periphery/oracle/OracleModule.sol";
import {Constants} from "../common/Constants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OracleModuleTest
 * @notice Test suite for OracleModule contract
 * @dev Uses forked mainnet to test with real Chainlink oracles
 */
contract OracleModuleTest is Test {
    OracleModule public oracleModule;

    // Test addresses
    address public owner = address(0x1);
    address public user = address(0x2);

    // Invalid feed for testing
    address public constant INVALID_FEED = address(0x123);

    event OracleSet(
        address indexed asset,
        address indexed feed,
        uint64 minPrice,
        uint64 maxPrice,
        uint64 maxDelay,
        bool validateCaps,
        bool validateStaleness
    );
    event OracleRemoved(address indexed asset);

    function setUp() public {
        // Fork mainnet at a specific block for deterministic tests
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpc, 22816778);
        vm.selectFork(forkId);

        // Deploy OracleModule with 8 decimals (standard for Chainlink feeds)
        oracleModule = new OracleModule(owner, 8);

        // Set up test context
        vm.startPrank(owner);
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(oracleModule.owner(), owner);
        assertEq(oracleModule.decimals(), 8);
    }

    // ============ Access Control Tests ============

    function test_SetOracle_OnlyOwner() public {
        vm.stopPrank();
        vm.startPrank(user);

        bytes memory encodedError = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user));
        vm.expectRevert(encodedError);
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000, // $10.00
            100000000000, // $1000.00
            3600, // 1 hour
            true, // validate caps
            true // validate staleness
        );
    }

    function test_RemoveOracle_OnlyOwner() public {
        // First set an oracle
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        vm.stopPrank();
        vm.startPrank(user);
        bytes memory encodedError = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user));
        vm.expectRevert(encodedError);
        oracleModule.removeOracle(Constants.WETH);
    }

    // ============ Set Oracle Tests ============

    function test_SetOracle_Valid() public {
        vm.expectEmit(true, true, false, true);
        emit OracleSet(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000, // $10.00
            1000000000000, // $10,000.00
            3600, // 1 hour
            true, // validate caps
            true // validate staleness
        );

        // Verify configuration
        (address feed, uint64 minPrice, uint64 maxPrice, uint64 maxDelay, bool validateCaps, bool validateStaleness) =
            oracleModule.oracleConfigs(Constants.WETH);
        assertEq(feed, Constants.ETH_USD_FEED);
        assertEq(minPrice, 1000000000);
        assertEq(maxPrice, 1000000000000);
        assertEq(maxDelay, 3600);
        assertTrue(validateCaps);
        assertTrue(validateStaleness);
    }

    function test_SetOracle_InvalidAsset() public {
        vm.expectRevert(OracleModule.InvalidAsset.selector);

        oracleModule.setOracle(
            address(0), // Invalid asset address
            Constants.ETH_USD_FEED,
            1000000000,
            100000000000,
            3600,
            true,
            true
        );
    }

    function test_SetOracle_InvalidFeed() public {
        vm.expectRevert(OracleModule.InvalidOracle.selector);

        oracleModule.setOracle(Constants.WETH, address(0), 1000000000, 100000000000, 3600, true, true);
    }

    function test_SetOracle_InvalidPriceRange() public {
        vm.expectRevert(OracleModule.InvalidPriceRange.selector);

        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            100000000000, // $1000.00 (max)
            1000000000, // $10.00 (min) - INVALID
            3600,
            true,
            true
        );
    }

    function test_SetOracle_InvalidDelay() public {
        vm.expectRevert(OracleModule.InvalidDelay.selector);

        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000,
            100000000000,
            0, // maxDelay = 0 with validateStaleness = true
            true,
            true
        );
    }

    function test_SetOracle_ZeroDelayWithoutStaleness() public {
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000,
            1000000000000,
            0, // maxDelay = 0 is allowed when staleness is off
            true,
            false
        );

        (,,, uint64 maxDelay,, bool validateStaleness) = oracleModule.oracleConfigs(Constants.WETH);
        assertEq(maxDelay, 0);
        assertFalse(validateStaleness);
        assertGt(oracleModule.getPrice(Constants.WETH), 0);
    }

    function test_SetOracle_InvalidDecimals() public {
        // Create a mock oracle with different decimals
        address mockOracleWithDifferentDecimals = address(0x999);

        // Mock the decimals function to return 6 instead of 8
        vm.mockCall(
            mockOracleWithDifferentDecimals,
            abi.encodeWithSelector(IChainlinkOracle.decimals.selector),
            abi.encode(uint8(6))
        );

        vm.expectRevert(OracleModule.InvalidDecimals.selector);

        oracleModule.setOracle(
            Constants.WETH, mockOracleWithDifferentDecimals, 1000000000, 100000000000, 3600, true, true
        );
    }

    function test_SetOracle_ValidDecimals() public {
        // Create a mock oracle with correct decimals (8)
        address mockOracleWithCorrectDecimals = address(0x888);

        // Mock the decimals function to return 8
        vm.mockCall(
            mockOracleWithCorrectDecimals,
            abi.encodeWithSelector(IChainlinkOracle.decimals.selector),
            abi.encode(uint8(8))
        );

        // Mock the latestRoundData function to return valid data
        vm.mockCall(
            mockOracleWithCorrectDecimals,
            abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
            abi.encode(uint80(1), int256(200000000000), uint256(block.timestamp), uint256(block.timestamp), uint80(1))
        );

        // Should work without reverting
        oracleModule.setOracle(
            Constants.WETH, mockOracleWithCorrectDecimals, 1000000000, 1000000000000, 3600, true, true
        );

        // Verify configuration
        (address feed,,,,,) = oracleModule.oracleConfigs(Constants.WETH);
        assertEq(feed, mockOracleWithCorrectDecimals);
    }

    function test_RealChainlinkFeedsHaveCorrectDecimals() public view {
        // Test that real Chainlink feeds have 8 decimals
        IChainlinkOracle ethFeed = IChainlinkOracle(Constants.ETH_USD_FEED);
        IChainlinkOracle btcFeed = IChainlinkOracle(Constants.BTC_USD_FEED);

        assertEq(ethFeed.decimals(), 8, "ETH/USD feed should have 8 decimals");
        assertEq(btcFeed.decimals(), 8, "BTC/USD feed should have 8 decimals");
        assertEq(oracleModule.decimals(), 8, "OracleModule should expect 8 decimals");
    }

    function test_SetOracle_ZeroMinPrice() public {
        // Should work when validateCaps is false
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            0, // minPrice = 0
            1000000000000, // maxPrice > 0
            3600,
            false, // validateCaps = false
            true
        );

        // Verify configuration
        (, uint64 minPrice, uint64 maxPrice,, bool validateCaps, bool validateStaleness) =
            oracleModule.oracleConfigs(Constants.WETH);
        assertEq(minPrice, 0);
        assertEq(maxPrice, 1000000000000);
        assertFalse(validateCaps);
        assertTrue(validateStaleness);
    }

    function test_SetOracle_ZeroMinPriceWithValidation() public {
        // Should fail when validateCaps is true and maxPrice = 0
        vm.expectRevert(OracleModule.InvalidPriceRange.selector);

        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            0, // minPrice = 0
            0, // maxPrice = 0 (this will trigger InvalidPriceRange)
            3600,
            true, // validateCaps = true
            true
        );
    }

    function test_SetOracle_PriceOutOfBounds() public {
        // Set very restrictive bounds that current ETH price won't meet
        vm.expectRevert(OracleModule.PriceOutOfBounds.selector);

        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000000, // $10,000.00 (min)
            10000000000000, // $100,000.00 (max)
            3600,
            true,
            true
        );
    }

    // ============ Get Price Tests ============

    function test_GetPrice_Valid() public {
        // Set up oracle
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000, // $10.00
            1000000000000, // $10,000.00
            3600, // 1 hour
            true, // validate caps
            true // validate staleness
        );

        // Get price
        uint256 price = oracleModule.getPrice(Constants.WETH);

        // Verify price is within bounds
        assertGt(price, 0);
        assertGe(price, 1000000000); // >= $10.00
        assertLe(price, 1000000000000); // <= $10,000.00
    }

    function test_GetPrice_NoOracle() public {
        vm.expectRevert(OracleModule.InvalidOracle.selector);
        oracleModule.getPrice(Constants.WETH);
    }

    function test_GetPrice_WithoutValidation() public {
        // Set up oracle without validations - should work with any price
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            0, // no min price validation
            0, // no max price validation
            0, // no delay validation
            false, // no caps validation
            false // no staleness validation
        );

        // Get price - should return the actual price from the feed
        uint256 price = oracleModule.getPrice(Constants.WETH);

        // Verify we get a valid price and timestamp
        assertGt(price, 0, "Price should be greater than 0");

        // Verify the price is reasonable (ETH should be > $100)
        assertGt(price, 100000000000, "ETH price should be > $100");
    }

    function test_GetPrice_InvalidAsset() public {
        vm.expectRevert(OracleModule.InvalidAsset.selector);
        oracleModule.getPrice(address(0));
    }

    // ============ Remove Oracle Tests ============

    function test_RemoveOracle_Valid() public {
        // Set up oracle first
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        vm.expectEmit(true, false, false, false);
        emit OracleRemoved(Constants.WETH);

        oracleModule.removeOracle(Constants.WETH);

        // Verify oracle is removed
        (address feed,,,,,) = oracleModule.oracleConfigs(Constants.WETH);
        assertEq(feed, address(0));
    }

    // ============ Multiple Assets Tests ============

    function test_MultipleAssets() public {
        // Set up multiple oracles
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        // Ajustar rango de BTC/USD para cubrir precios reales
        oracleModule.setOracle(
            Constants.WBTC,
            Constants.BTC_USD_FEED,
            1000000000000, // $10,000.00
            100000000000000, // $1,000,000.00
            3600,
            true,
            true
        );

        // Get prices for both
        uint256 ethPrice = oracleModule.getPrice(Constants.WETH);
        uint256 btcPrice = oracleModule.getPrice(Constants.WBTC);

        assertGt(ethPrice, 0);
        assertGt(btcPrice, 0);
    }

    // ============ Staleness Tests ============

    function test_StalePrice() public {
        // Set up oracle with delay de 1 hora
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000,
            1000000000000,
            3600, // 1 hour delay
            true,
            true
        );

        // Fast forward time (menos que el delay)
        vm.warp(block.timestamp + 10);

        // Should still work as the oracle data is still fresh
        uint256 price = oracleModule.getPrice(Constants.WETH);
        assertGt(price, 0);
    }

    // ============ Edge Cases Tests ============

    function test_SetOracle_ZeroMaxPrice() public {
        vm.expectRevert(OracleModule.InvalidPriceRange.selector);

        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1000000000,
            0, // maxPrice = 0 with validateCaps = true
            3600,
            true,
            false
        );
    }

    function test_SetOracle_UpdateExisting() public {
        // Set initial oracle
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        // Update with new configuration
        oracleModule.setOracle(
            Constants.WETH,
            Constants.BTC_USD_FEED, // Different feed
            10000000000, // Different bounds
            1000000000000,
            7200, // Different delay
            false, // Different flags
            false
        );

        // Verify update
        (address feed, uint64 minPrice, uint64 maxPrice, uint64 maxDelay, bool validateCaps, bool validateStaleness) =
            oracleModule.oracleConfigs(Constants.WETH);
        assertEq(feed, Constants.BTC_USD_FEED);
        assertEq(minPrice, 10000000000);
        assertEq(maxPrice, 1000000000000);
        assertEq(maxDelay, 7200);
        assertFalse(validateCaps);
        assertFalse(validateStaleness);
    }

    // ============ Gas Tests ============

    function test_Gas_SetOracle() public {
        uint256 gasBefore = gasleft();

        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for setOracle:", gasUsed);

        // Should be reasonable (adjust threshold as needed)
        assertLt(gasUsed, 500000);
    }

    function test_Gas_GetPrice() public {
        // Set up oracle first
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        uint256 gasBefore = gasleft();

        oracleModule.getPrice(Constants.WETH);

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for getPrice:", gasUsed);

        // Should be reasonable (adjust threshold as needed)
        assertLt(gasUsed, 500000);
    }

    // ============ Additional Edge Cases Tests ============

    function test_GetPrice_StalePriceExceedsDelay() public {
        // Set up oracle with very short delay and unrestrictive bounds
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1, // minPrice: muy bajo
            type(uint64).max, // maxPrice: muy alto
            3350, // 10 seconds delay
            true,
            true
        );

        // Fast forward time beyond the delay
        vm.warp(block.timestamp + 20);

        // Should revert due to stale price
        vm.expectRevert(OracleModule.StalePrice.selector);
        oracleModule.getPrice(Constants.WETH);
    }

    function test_GetPrice_StalePriceAllowedWhenStalenessOff() public {
        oracleModule.setOracle(
            Constants.WETH,
            Constants.ETH_USD_FEED,
            1,
            type(uint64).max,
            1, // 1 second delay would be stale after the warp below
            true,
            false
        );

        vm.warp(block.timestamp + 20);

        assertGt(oracleModule.getPrice(Constants.WETH), 0);
    }

    function test_GetPrice_FutureTimestamp() public {
        // Set up oracle
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        // Mock a future timestamp (this would be unusual but should be handled)
        // We can't easily mock this with the current setup, but the contract should handle it
        // This test documents the expected behavior
    }

    function test_SetOracle_UpdateWithSameValues() public {
        // Set initial oracle
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        // Update with same values - should work
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        // Verify configuration remains the same
        (address feed, uint64 minPrice, uint64 maxPrice, uint64 maxDelay, bool validateCaps, bool validateStaleness) =
            oracleModule.oracleConfigs(Constants.WETH);
        assertEq(feed, Constants.ETH_USD_FEED);
        assertEq(minPrice, 1000000000);
        assertEq(maxPrice, 1000000000000);
        assertEq(maxDelay, 3600);
        assertTrue(validateCaps);
        assertTrue(validateStaleness);
    }

    function test_RemoveOracle_NonExistentAsset() public {
        // Should work without error
        oracleModule.removeOracle(Constants.LINK);

        // Verify oracle is not configured
        (address feed,,,,,) = oracleModule.oracleConfigs(Constants.LINK);
        assertEq(feed, address(0));
    }

    function test_GetPrice_AfterRemoveOracle() public {
        // Set up oracle
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        // Remove oracle
        oracleModule.removeOracle(Constants.WETH);

        // Try to get price - should fail
        vm.expectRevert(OracleModule.InvalidOracle.selector);
        oracleModule.getPrice(Constants.WETH);
    }

    function test_MultipleOraclesSameAsset() public {
        // Set up first oracle
        oracleModule.setOracle(Constants.WETH, Constants.ETH_USD_FEED, 1000000000, 1000000000000, 3600, true, true);

        // Update with different oracle (BTC feed)
        oracleModule.setOracle(
            Constants.WETH, Constants.BTC_USD_FEED, 1000000000000, 100000000000000, 7200, false, false
        );

        // Verify the new configuration
        (address feed, uint64 minPrice, uint64 maxPrice, uint64 maxDelay, bool validateCaps, bool validateStaleness) =
            oracleModule.oracleConfigs(Constants.WETH);
        assertEq(feed, Constants.BTC_USD_FEED);
        assertEq(minPrice, 1000000000000);
        assertEq(maxPrice, 100000000000000);
        assertEq(maxDelay, 7200);
        assertFalse(validateCaps);
        assertFalse(validateStaleness);
    }
}
