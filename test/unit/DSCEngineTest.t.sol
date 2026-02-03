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

    // DSCEngine contract events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);
    event DscMinted(address indexed user, uint256 amount);
    event DscBurned(address indexed user, uint256 amount);

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

    // modifier to deposit WETH to the DSCEngine contract
    // Checks both when the amount is 0 -> revert condition & Successful deposit with event validation
    modifier depositWeth(uint256 amount) {
        if (amount == 0) {
            vm.expectRevert(DSCEngine.DSCEngine__ZeroAmount.selector);
            dscEngine.depositCollateral(weth, amount);
        } else {
            vm.expectEmit(true, true, false, true, address(dscEngine));
            emit CollateralDeposited(DEPOSITER, weth, amount);
            vm.prank(DEPOSITER);
            dscEngine.depositCollateral(weth, amount);
        }    
        _;
    }

    // modifier to deposit WBTC to the DSCEngine contract
    // Checks both when the amount is 0 -> revert condition & Successful deposit with event validation
    modifier depositWbtc(uint256 amount) {
        if (amount == 0) {
            vm.expectRevert(DSCEngine.DSCEngine__ZeroAmount.selector);
            dscEngine.depositCollateral(wbtc, amount);
        } else {
            vm.expectEmit(true, true, false, true, address(dscEngine));
            emit CollateralDeposited(DEPOSITER, wbtc, amount);
            vm.prank(DEPOSITER);
            dscEngine.depositCollateral(wbtc, amount);
        }    
        _;
    }

    address[] public priceFeeds; 
    address[] public tokenAddresses;

    function testConstructorInitialisationPass() public { 
        priceFeeds.push(wbtcUsdPriceFeed);
        priceFeeds.push(wethUsdPriceFeed);
        tokenAddresses.push(wbtc);
        tokenAddresses.push(weth);
        new DSCEngine(tokenAddresses, priceFeeds, address(dsc));
    }

    function testRevertsIfLengthMismatchForPriceFeedsAndTokens() public {
        priceFeeds.push(wbtcUsdPriceFeed);
        priceFeeds.push(wethUsdPriceFeed);
        tokenAddresses.push(wbtc);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeeds, address(dsc));
    }

    function testNonCollateralizedTokenDeposit() public {
        address token = makeAddr("lightbeam");
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__TokenCannotBeCollateralized.selector, 
                token)
            );
        dscEngine.depositCollateral(token, 10e18);

    }

    function testDepositZeroEthCollateral() public depositWeth(0) {}

    function testDepositZeroWbtcCollateral() public depositWbtc(0) {}

    function testDepositWethAndWbtcCollateral() public depositWeth(STARTING_WETH_BALANCE) depositWbtc(STARTING_WBTC_BALANCE) {
        uint256 wbtcDeposited = dscEngine.getCollateralDepositedByUser(wbtc, DEPOSITER);
        uint256 wethDeposited = dscEngine.getCollateralDepositedByUser(weth, DEPOSITER);
        assertEq(wbtcDeposited, STARTING_WBTC_BALANCE);
        assertEq(wethDeposited, STARTING_WETH_BALANCE);
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