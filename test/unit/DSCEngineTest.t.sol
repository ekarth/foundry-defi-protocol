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
    uint256 DEPOSIT_AMOUNT = 0.5 ether; // deposit amount when not whole balance deposited
    uint256 DSC_TO_MINT = 100e18;
    uint256 MAX_DSC_TO_MINT = type(uint256).max;

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

    modifier mintDsc(uint256 amount) {
        if (amount == 0) {
            vm.expectRevert(DSCEngine.DSCEngine__ZeroAmount.selector);
            dscEngine.mintDsc(amount);
        } else {
            vm.expectEmit(true, true, false, true, address(dscEngine));
            emit DscMinted(DEPOSITER, amount);
            vm.startPrank(DEPOSITER);
            dscEngine.mintDsc(amount);
            dsc.approve(address(dscEngine), type(uint256).max);
            vm.stopPrank();
        }    
        _; 
    }

    address[] public priceFeeds; 
    address[] public tokenAddresses;

    // CONSTRUCTOR
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
                DSCEngine.DSCEngine__NotSupportedCollatralizedToken.selector, 
                token)
            );
        dscEngine.depositCollateral(token, 10e18);

    }


    // DEPOSIT COLLATERAL
    function testDepositZeroEthCollateral() public depositWeth(0) {}

    function testDepositZeroWbtcCollateral() public depositWbtc(0) {}

    function testDepositWethAndWbtcCollateral() public depositWeth(STARTING_WETH_BALANCE) depositWbtc(STARTING_WBTC_BALANCE) {
        uint256 wbtcDeposited = dscEngine.getCollateralDepositedByUser(wbtc, DEPOSITER);
        uint256 wethDeposited = dscEngine.getCollateralDepositedByUser(weth, DEPOSITER);
        assertEq(wbtcDeposited, STARTING_WBTC_BALANCE);
        assertEq(wethDeposited, STARTING_WETH_BALANCE);
    }

    function testRevertIfDepositNotSupportedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAND", "RAND", DEPOSITER, STARTING_WETH_BALANCE);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__NotSupportedCollatralizedToken.selector,
            (address(randToken))
            )
        );
        vm.prank(DEPOSITER);
        dscEngine.depositCollateral(address(randToken), STARTING_WETH_BALANCE);
    }

    // ACCOUNT INFO
    function testGetAccountInfoWhenWbtcCollateral() public depositWbtc(DEPOSIT_AMOUNT) {
        uint256 expectedCollateralUsdValue = 45_000 ether; // 90_000 * .5 +  = 45_000e18
        uint256 expectedDscMinted = 0;
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dscEngine.getAccountInfo(DEPOSITER);
        assertEq(totalCollateralValueInUsd, expectedCollateralUsdValue);
        assertEq(totalDscMinted, expectedDscMinted);
    }

    function testGetAccountInfoWhenWethCollateral() public depositWeth(DEPOSIT_AMOUNT) {
        uint256 expectedCollateralUsdValue = 1500 ether; // 3_000 * .5 +  = 15_00e18
        uint256 expectedDscMinted = 0;
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dscEngine.getAccountInfo(DEPOSITER);
        assertEq(totalCollateralValueInUsd, expectedCollateralUsdValue);
        assertEq(totalDscMinted, expectedDscMinted);
    }

    function testGetAccountInfoWhenBothCollateral() public depositWeth(STARTING_WETH_BALANCE) depositWbtc(STARTING_WBTC_BALANCE) {
        uint256 expectedCollateralUsdValue = 135_000 ether; // 3000 * 15 + 90_000 * 1 = 135_000e18
        uint256 expectedDscMinted = 0;
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dscEngine.getAccountInfo(DEPOSITER);
        assertEq(totalCollateralValueInUsd, expectedCollateralUsdValue);
        assertEq(totalDscMinted, expectedDscMinted);
    }

    function testGetAccountInfoWhenNoCollateral() public view {
        uint256 expectedCollateralUsdValue = 0;
        uint256 expectedDscMinted = 0;
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dscEngine.getAccountInfo(DEPOSITER);
        assertEq(totalCollateralValueInUsd, expectedCollateralUsdValue);
        assertEq(totalDscMinted, expectedDscMinted);
    }

    // MINT DSC
    function testMintDscRevertsIfZeroDscTokensToMint() public depositWeth(STARTING_WETH_BALANCE) {
        vm.prank(DEPOSITER);
        vm.expectRevert(DSCEngine.DSCEngine__ZeroAmount.selector);
        dscEngine.mintDsc(0);
    }

    function testMintDscRevertsIfHealthFactorBreaks() public depositWeth(STARTING_WETH_BALANCE) {
        vm.prank(DEPOSITER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.mintDsc(MAX_DSC_TO_MINT);
    }

    function testMintDscMintsDscToUser() public depositWeth(STARTING_WETH_BALANCE) {
        uint256 expectedUserDscBalance = DSC_TO_MINT;
        uint256 expectedTotalDscMinted = DSC_TO_MINT;
        vm.prank(DEPOSITER);
        vm.expectEmit(true, false, false, true, address(dscEngine));
        emit DscMinted(DEPOSITER, DSC_TO_MINT);
        dscEngine.mintDsc(DSC_TO_MINT);

        uint256 userDscBalance = dscEngine.getDscMintedByUser(DEPOSITER);
        uint256 totalDscMinted = dscEngine.getTotalDscMinted();
        assertEq(expectedUserDscBalance, dsc.balanceOf(DEPOSITER)); // validating if tokens were transferred
        assertEq(expectedUserDscBalance, userDscBalance);
        assertEq(expectedTotalDscMinted, totalDscMinted);
    }

    // DEPOSIT COLLATERAL AND MINT DSC
    function testDepositCollateralAndMintDscRevertsWhenHealthFactorBreaks() public  {
        vm.prank(DEPOSITER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.depositCollateralAndMintDsc(weth, STARTING_WETH_BALANCE, MAX_DSC_TO_MINT);
    }

    function testDepositCollateralAndMintDscPass() public {
        uint256 expectedUserDscBalance = DSC_TO_MINT;
        vm.prank(DEPOSITER);
        dscEngine.depositCollateralAndMintDsc(weth, STARTING_WETH_BALANCE, DSC_TO_MINT);

        uint256 userDscBalance = dscEngine.getDscMintedByUser(DEPOSITER);
        assertEq(expectedUserDscBalance, dsc.balanceOf(DEPOSITER)); // validating if tokens were transferred
        assertEq(expectedUserDscBalance, userDscBalance);
    }

    // BURN DSC
    function testBurnDscRevertsWhenZeroDscToBurn() public depositWeth(STARTING_WETH_BALANCE) mintDsc(100) {
        vm.prank(DEPOSITER);
        vm.expectRevert(DSCEngine.DSCEngine__ZeroAmount.selector);
        dscEngine.burnDsc(0);
    }

    function testBurnDscToBurnAllDsc() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {
        uint256 expectedDscAfterBurn = 0;
        vm.prank(DEPOSITER);
        dscEngine.burnDsc(DSC_TO_MINT);
        assertEq(expectedDscAfterBurn, dscEngine.getDscMintedByUser(DEPOSITER));
        assertEq(expectedDscAfterBurn, dsc.balanceOf(DEPOSITER));
    }

    function testBurnDscToBurnMoreDsc() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {

        uint256 dscToBurn = DSC_TO_MINT + ((DSC_TO_MINT * 10) / 100);
        uint256 expectedDscAfterBurn = 0;
        vm.prank(DEPOSITER);
        dscEngine.burnDsc(dscToBurn);
        assertEq(expectedDscAfterBurn, dscEngine.getDscMintedByUser(DEPOSITER));
        assertEq(expectedDscAfterBurn, dsc.balanceOf(DEPOSITER));
    }

    function testBurnDscToBurnLessDsc() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {

        uint256 expectedDscAfterBurn = (DSC_TO_MINT * 10) / 100;
        uint256 dscToBurn = DSC_TO_MINT - expectedDscAfterBurn;
        vm.prank(DEPOSITER);
        dscEngine.burnDsc(dscToBurn);
        assertEq(expectedDscAfterBurn, dscEngine.getDscMintedByUser(DEPOSITER));
        assertEq(expectedDscAfterBurn, dsc.balanceOf(DEPOSITER));
    }
    
}