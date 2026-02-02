// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine, DecentralizedStableCoin} from "../../src/DSCEngine.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {HelperConfig, CodeConstants} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DSCEngineTest is Test , CodeConstants{
    // contracts
    DeployDsc deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig config;

    // collateral tokens & their price Feeds
    address wbtc;
    address weth;
    address wbtcUsdPriceFeed;
    address wethUsdPriceFeed;

    // Test constants
    address DEPOSITER = makeAddr("depositer");
    uint256 STARTING_WETH_BALANCE = 15 ether;
    uint256 STARTING_WBTC_BALANCE = 1 ether;

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, dscEngine, config) = deployer.run();
        HelperConfig.NetworkConfig memory networkConfig = config.getActiveNetworkConfig();
        wbtc = networkConfig.wbtc;
        weth = networkConfig.weth;
        wbtcUsdPriceFeed = networkConfig.wbtcUsdPriceFeed;
        wethUsdPriceFeed = networkConfig.wethUsdPriceFeed;
        ERC20Mock(wbtc).mint(DEPOSITER, STARTING_WBTC_BALANCE);
        ERC20Mock(wbtc).approveInternal(DEPOSITER, address(dscEngine), STARTING_WBTC_BALANCE);
        ERC20Mock(weth).mint(DEPOSITER, STARTING_WETH_BALANCE);
        ERC20Mock(weth).approveInternal(DEPOSITER, address(dscEngine), STARTING_WETH_BALANCE);
    }

    function testAccountCollateralValueInUsdWhenWbtcCollateral() public {
        uint256 DEPOSIT_AMOUNT = 0.5 ether;

        uint256 expectedUsdValue = 45_000 ether; // 90_000 * .5 +  = 45_000e18

        vm.startPrank(DEPOSITER);
        dscEngine.depositCollateral(wbtc, DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 totalCollateralValueInUsd = dscEngine.getAccountCollateralValueInUsd(DEPOSITER);
        assertEq(totalCollateralValueInUsd, expectedUsdValue);
    }

    function testAccountCollateralValueInUsdWhenWethCollateral() public {
        uint256 DEPOSIT_AMOUNT = 7.205 ether;

        uint256 expectedUsdValue = 21_615 ether; // 3000 * 7.205 +  = 21_615e18

        vm.startPrank(DEPOSITER);
        dscEngine.depositCollateral(weth, DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 totalCollateralValueInUsd = dscEngine.getAccountCollateralValueInUsd(DEPOSITER);
        assertEq(totalCollateralValueInUsd, expectedUsdValue);

    }

    function testAccountCollateralValueInUsdWhenBothCollateral() public {

        uint256 expectedUsdValue = 135_000 ether; // 3000 * 15 + 90_000 * 1 = 135_000e18

        vm.startPrank(DEPOSITER);
        dscEngine.depositCollateral(wbtc, STARTING_WBTC_BALANCE);
        dscEngine.depositCollateral(weth, STARTING_WETH_BALANCE);
        vm.stopPrank();

        uint256 totalCollateralValueInUsd = dscEngine.getAccountCollateralValueInUsd(DEPOSITER);
        assertEq(totalCollateralValueInUsd, expectedUsdValue);

    }

    function testAccountCollateralValueInUsdWhenNoCollateral() public view {

        uint256 totalCollateralValueInUsd = dscEngine.getAccountCollateralValueInUsd(DEPOSITER);
        assertEq(totalCollateralValueInUsd, 0);
    }
}