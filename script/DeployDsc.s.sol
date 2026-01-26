// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDsc is Script {
    address[] collateralTokenAddresses;
    address[] collateralTokenPriceFeedAddresses;
    
    
    function run() external returns (DecentralizedStableCoin dsc, DSCEngine dscEngine, HelperConfig config) {
        config = new HelperConfig();
        HelperConfig.NetworkConfig memory networkConfig = config.getActiveNetworkConfig();

        _setCollateralTokenAddresses(networkConfig);
        _setCollateralTokenPriceFeedAddresses(networkConfig);
        dsc = _deployDsc(networkConfig.deployerKey);
        dscEngine = _deployDscEngine(networkConfig.deployerKey, address(dsc));
        vm.startBroadcast(networkConfig.deployerKey);
        dsc.transferOwnership(address(dscEngine));
        vm.stopBroadcast();
    }

    function _deployDsc(uint256 deployerKey) internal returns (DecentralizedStableCoin) {
        DecentralizedStableCoin decentralizedStableCoin;
        vm.startBroadcast(deployerKey);
        decentralizedStableCoin = new DecentralizedStableCoin();
        vm.stopBroadcast();
        return decentralizedStableCoin;
    } 

    function _deployDscEngine(uint256 deployerKey, address dsc) internal returns (DSCEngine) {
        vm.startBroadcast(deployerKey);
        DSCEngine dscEngine = new DSCEngine(
            collateralTokenAddresses,
            collateralTokenPriceFeedAddresses,
            dsc
        );
        vm.stopBroadcast();
        return dscEngine;
    }

    function _setCollateralTokenAddresses(HelperConfig.NetworkConfig memory config) internal {
        collateralTokenAddresses.push(config.wbtc);
        collateralTokenAddresses.push(config.weth);
    } 

    function _setCollateralTokenPriceFeedAddresses(HelperConfig.NetworkConfig memory config) internal {
        collateralTokenPriceFeedAddresses.push(config.wbtcUsdPriceFeed);
        collateralTokenPriceFeedAddresses.push(config.wethUsdPriceFeed);
    }
}