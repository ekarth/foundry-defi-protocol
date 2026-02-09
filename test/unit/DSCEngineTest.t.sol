// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {HelperConfig, CodeConstants} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

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
    uint256 MIN_HEALTH_FACTOR = 1e18;

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
        dscEngine.mintDsc(UINT256_MAX);
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
        dscEngine.depositCollateralAndMintDsc(weth, STARTING_WETH_BALANCE, UINT256_MAX);
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

    // REDEEM COLLATERAL
    function testRedeemCollateralRevertsWhenNotSupportedCollateralRedeem() public depositWeth(STARTING_WETH_BALANCE) {
        address token = makeAddr("killer");
        vm.prank(DEPOSITER);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__NotSupportedCollatralizedToken.selector, token));
        dscEngine.redeemCollateral(token, STARTING_WETH_BALANCE);
    }
    
    function testRedeemCollateralRevertsWhenNoTokensToRedeem() public depositWeth(STARTING_WETH_BALANCE) {
        vm.prank(DEPOSITER);
        vm.expectRevert(DSCEngine.DSCEngine__ZeroAmount.selector);
        dscEngine.redeemCollateral(weth, 0);
    }

    function testRedeemCollateralRevertsWhenRedeemMoreCollateralThanDeposited() public depositWeth(STARTING_WETH_BALANCE) {
        uint256 collateralToRedeem = UINT256_MAX;
        vm.prank(DEPOSITER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__RedeemMoreCollateralThanDeposited.selector,
                weth,
                STARTING_WETH_BALANCE,
                collateralToRedeem
            )
        );
        dscEngine.redeemCollateral(weth, collateralToRedeem);
    }

    function testRedeemCollateralRevertsWhenHealthFactorBreaks() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {
        vm.prank(DEPOSITER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.redeemCollateral(weth, STARTING_WETH_BALANCE);
    }

    function testRedeemCollateralPassWhenDscMinted() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {
        uint256 collateralToRedeem = (STARTING_WETH_BALANCE * 10) / 100;
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, DEPOSITER, weth, collateralToRedeem);
        vm.prank(DEPOSITER);
        dscEngine.redeemCollateral(weth, collateralToRedeem);
        
        uint256 healthFactorAfterRedeem = dscEngine.getHealthFactor(DEPOSITER);
        console.log("User health factor after redeeming collateral: ", healthFactorAfterRedeem);
        assertGt(healthFactorAfterRedeem, MIN_HEALTH_FACTOR);
    }

    function testRedeemCollateralPassWhenNoDscMinted() public depositWeth(STARTING_WETH_BALANCE) {
        uint256 collateralToRedeem = STARTING_WETH_BALANCE;
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, DEPOSITER, weth, collateralToRedeem);
        vm.prank(DEPOSITER);
        dscEngine.redeemCollateral(weth, collateralToRedeem);
        
        uint256 healthFactorAfterRedeem = dscEngine.getHealthFactor(DEPOSITER);
        console.log("User health factor after redeeming collateral: ", healthFactorAfterRedeem);
        assertEq(healthFactorAfterRedeem, UINT256_MAX);
        assertEq(dscEngine.getCollateralDepositedByUser(weth, DEPOSITER), 0);
    }

    function testRedeemOneCollateralWhenBothDepositedAndDscMinted() public
        depositWeth(STARTING_WETH_BALANCE)
        depositWbtc(STARTING_WBTC_BALANCE) 
        mintDsc(DSC_TO_MINT)
    {
        uint256 collateralToRedeem = STARTING_WETH_BALANCE;
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, DEPOSITER, weth, collateralToRedeem);
        vm.prank(DEPOSITER);
        dscEngine.redeemCollateral(weth, collateralToRedeem);
        
        uint256 healthFactorAfterRedeem = dscEngine.getHealthFactor(DEPOSITER);
        console.log("User health factor after redeeming collateral: ", healthFactorAfterRedeem);
        assertGt(healthFactorAfterRedeem, MIN_HEALTH_FACTOR);
        assertEq(dscEngine.getCollateralDepositedByUser(weth, DEPOSITER), 0);
        assertEq(dscEngine.getCollateralDepositedByUser(wbtc, DEPOSITER), STARTING_WBTC_BALANCE);
    }

    // GET AMOUNT COLLATERAL FROM USD
    function testGetAmountCollateralFromUsdRevertsWhenTokenNotSupported() public {
        uint256 usdAmountInWei = 100e18;
        address token = makeAddr("killer");
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__NotSupportedCollatralizedToken.selector,
                token
            )
        );
        dscEngine.getAmountCollateralFromUsd(token, usdAmountInWei);
    }

    function testGetAmountCollateralFromUsd() public {
        uint256 usdAmountInWei = 100e18;
        uint256 expectedCollateralAmount = 0.05 ether;
        
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(2_000e8); // update price for calculation
        uint256 actualCollateralAmount = dscEngine.getAmountCollateralFromUsd(weth, usdAmountInWei);

        assertEq(expectedCollateralAmount, actualCollateralAmount);
    }

    function testGetAmountCollateralFromUsdRevertsWhenNegativePrice() public {
        int256 price = -1_000 * int256((10 ** WETH_DECIMALS));
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(price);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__InvalidCollateralPrice.selector,
                price
            )
        );
        dscEngine.getAmountCollateralFromUsd(weth, DSC_TO_MINT);
        
    }

    // LIQUIDATE
    function testLiquidateRevertsWhenNotSupportedCollateral() public depositWeth(STARTING_WETH_BALANCE) {
        address token = makeAddr("killer");
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__NotSupportedCollatralizedToken.selector,
                token
            )
        );
        dscEngine.liquidate(token, DEPOSITER, 100e18);

    }

    function testLiquidateWhenDebtToCoverIsZero() public depositWeth(STARTING_WETH_BALANCE) {
        vm.expectRevert(DSCEngine.DSCEngine__ZeroAmount.selector);
        dscEngine.liquidate(weth, DEPOSITER, 0);
    }

    function testLiquidateRevertsWhenUserHealthFactorIsMoreThanMinHealthFactor() public depositWeth(STARTING_WETH_BALANCE) mintDsc(10_000e18) {
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, DEPOSITER, 100e18);
    }

    // used to test a scenario where the user deposited one collateral and borrowed DSC but the liqudidator wants another collateral (supported not-deposited) as the redeeming collateral
    function testLiquidateWhenDebtToCoverMoreThanDebt() public depositWeth(STARTING_WETH_BALANCE) mintDsc(20_000 ether) {
        uint256 debt = 20_000 ether;
        uint256 dscToMint = 22_000 ether;
        int256 priceForLiquidation = int256(2600 * (10 ** WETH_DECIMALS));

        // Get DSC
        ERC20Mock(wbtc).mint(address(this), STARTING_WBTC_BALANCE); // funding the contract
        ERC20Mock(wbtc).approveInternal(address(this), address(dscEngine), STARTING_WBTC_BALANCE);
        dscEngine.depositCollateralAndMintDsc(wbtc, STARTING_WBTC_BALANCE, dscToMint);
        dsc.approve(address(dscEngine), dscToMint);

        // update collateral price to be eligible for liquidation
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(priceForLiquidation);

        uint256 redeemedCollateral = dscEngine.getAmountCollateralFromUsd(weth, debt); // collateral amount against debt and not debtToCover
        uint256 bonusCollateral = (10 * redeemedCollateral) / 100;
        uint256 expectedRedeemedCollateral = redeemedCollateral + bonusCollateral;

        // liquidate
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, address(this), weth, expectedRedeemedCollateral);
        dscEngine.liquidate(weth, DEPOSITER, dscToMint);

        assertEq(dsc.balanceOf(address(this)), dscToMint - debt);
        assertEq(ERC20Mock(weth).balanceOf(address(this)), expectedRedeemedCollateral);
        assertEq(dscEngine.getCollateralDepositedByUser(weth, DEPOSITER), 0);

    }

    function testLiquidateWhenDebtToCoverEqualsDebt() public depositWeth(STARTING_WETH_BALANCE) mintDsc(20_000 ether) {
        uint256 debt = 20_000 ether;
        uint256 dscToMint = 20_000 ether;
        int256 priceForLiquidation = int256(2600 * (10 ** WETH_DECIMALS));

        // Get DSC
        ERC20Mock(wbtc).mint(address(this), STARTING_WBTC_BALANCE); // funding the contract
        ERC20Mock(wbtc).approveInternal(address(this), address(dscEngine), STARTING_WBTC_BALANCE);
        dscEngine.depositCollateralAndMintDsc(wbtc, STARTING_WBTC_BALANCE, dscToMint);
        dsc.approve(address(dscEngine), dscToMint);

        // update collateral price to be eligible for liquidation
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(priceForLiquidation);

        uint256 redeemedCollateral = dscEngine.getAmountCollateralFromUsd(weth, dscToMint); 
        uint256 bonusCollateral = (10 * redeemedCollateral) / 100;
        uint256 expectedRedeemedCollateral = redeemedCollateral + bonusCollateral;

        // liquidate
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, address(this), weth, expectedRedeemedCollateral);
        dscEngine.liquidate(weth, DEPOSITER, dscToMint);

        assertEq(dsc.balanceOf(address(this)), dscToMint - debt);
        assertEq(ERC20Mock(weth).balanceOf(address(this)), expectedRedeemedCollateral);
        assertEq(dscEngine.getCollateralDepositedByUser(weth, DEPOSITER), 0);
    }

    function testLiquidatePartialLiquidation() public depositWeth(STARTING_WETH_BALANCE) mintDsc(20_000 ether) {
        uint256 dscToMint = 10_000 ether;
        int256 priceForLiquidation = int256(2600 * (10 ** WETH_DECIMALS));

        // Get DSC
        ERC20Mock(wbtc).mint(address(this), STARTING_WBTC_BALANCE); // funding the contract
        ERC20Mock(wbtc).approveInternal(address(this), address(dscEngine), STARTING_WBTC_BALANCE);
        dscEngine.depositCollateralAndMintDsc(wbtc, STARTING_WBTC_BALANCE, dscToMint);
        dsc.approve(address(dscEngine), dscToMint);

        // update collateral price to be eligible for liquidation
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(priceForLiquidation);

        uint256 redeemedCollateral = dscEngine.getAmountCollateralFromUsd(weth, dscToMint);
        uint256 bonusCollateral = (10 * redeemedCollateral) / 100;
        uint256 expectedRedeemedCollateral = redeemedCollateral + bonusCollateral;

        // liquidate
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, address(this), weth, expectedRedeemedCollateral);
        dscEngine.liquidate(weth, DEPOSITER, dscToMint);

        assertEq(dsc.balanceOf(address(this)), 0);
        assertEq(ERC20Mock(weth).balanceOf(address(this)), expectedRedeemedCollateral);
    }

    // REDEEM COLLATERAL FOR DSC
    function testRedeemCollateralForDscPartialRedeem() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {
        uint256 dscToRedeem = DSC_TO_MINT / 2;
        uint256 redeemCollateralAmount = STARTING_WETH_BALANCE / 2;

        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, DEPOSITER, weth, redeemCollateralAmount);
        vm.prank(DEPOSITER);
        dscEngine.redeemCollateralForDsc(weth, redeemCollateralAmount, dscToRedeem);

        assertEq(dscEngine.getCollateralDepositedByUser(weth, DEPOSITER), redeemCollateralAmount);
        assertEq(dscEngine.getDscMintedByUser(DEPOSITER), dscToRedeem);
    }

    function testRedeemCollateralForDscFullRedeem() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {
        uint256 dscToRedeem = DSC_TO_MINT;
        uint256 redeemCollateralAmount = STARTING_WETH_BALANCE;

        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(DEPOSITER, DEPOSITER, weth, redeemCollateralAmount);
        vm.prank(DEPOSITER);
        dscEngine.redeemCollateralForDsc(weth, redeemCollateralAmount, dscToRedeem);

        assertEq(dscEngine.getCollateralDepositedByUser(weth, DEPOSITER), 0);
        assertEq(dscEngine.getDscMintedByUser(DEPOSITER), 0);
    }

    function testRedeemCollateralForDscRevertsWhenHealthFactorBreaks() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {
        uint256 dscToRedeem = DSC_TO_MINT / 2;
        uint256 redeemCollateralAmount = STARTING_WETH_BALANCE;

        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        vm.prank(DEPOSITER);
        dscEngine.redeemCollateralForDsc(weth, redeemCollateralAmount, dscToRedeem);
    }

    // GET ACCOUNT COLLATERAL VALUE IN USD
    function testGetAccountCollateralValueInUsd() public depositWeth(STARTING_WETH_BALANCE) {
        assertEq(dscEngine.getAccountCollateralValueInUsd(DEPOSITER), 45_000 ether);
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(int256(2_100 * (10 ** WETH_DECIMALS)));
        assertEq(dscEngine.getAccountCollateralValueInUsd(DEPOSITER), 31_500 ether);
        assertEq(
            dscEngine.getAccountCollateralValueInUsd(makeAddr("killer")),
            0
        );
    }

    function testGetAccountCollateralValueInUsdRevertsWhenNegativatePrice() public depositWeth(STARTING_WETH_BALANCE) {
        int256 price = -1_000 * int256((10 ** WETH_DECIMALS));
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(price);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__InvalidCollateralPrice.selector,
                price
            )
        );
        dscEngine.getAccountCollateralValueInUsd(DEPOSITER);
    }

    // Getter functions
    // HEALTH FACTOR
    function testHealthFactorWhenNoDeposit() public view {
        uint256 expectedHealthFactor = UINT256_MAX;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(DEPOSITER);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthFactorWhenNoDscMinted() public depositWbtc(STARTING_WBTC_BALANCE) {
        uint256 expectedHealthFactor = UINT256_MAX;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(DEPOSITER);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthFactorWhenDscMinted() public depositWeth(STARTING_WETH_BALANCE) mintDsc(DSC_TO_MINT) {
        uint256 expectedHealthFactor = 225 ether; //((3000 * 15 * .5)) / 100 * 1e18
        uint256 actualHealthFactor = dscEngine.getHealthFactor(DEPOSITER);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }
}