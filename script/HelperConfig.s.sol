// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

contract CodeConstants {

    // SEPOLIA constants
    address constant SEPOLIA_WETH_PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
    address constant SEPOLIA_WBTC_PRICE_FEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    address constant SEPOLIA_WETH = 0xdd13E55209Fd76AfE204dBda4007C227904f0a81;
    address constant SEPOLIA_WBTC = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;

    // ANVIL constants
    uint256 constant ANVIL_DEFAULT_DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint8 constant WBTC_DECIMALS = 8;
    uint8 constant WETH_DECIMALS = 8;
    int256 constant WBTC_START_PRICE = int256(90000 * (10 ** WBTC_DECIMALS));
    int256 constant WETH_START_PRICE = int256(3000 * (10 ** WETH_DECIMALS));
    
}
contract HelperConfig is Script, CodeConstants {

    struct NetworkConfig {
        address wbtc;
        address weth;
        address wbtcUsdPriceFeed;
        address wethUsdPriceFeed;
        uint256 deployerKey;
    }

    NetworkConfig activeNetworkConfig;
    mapping(uint256 chainid => NetworkConfig config) chainIdToNetworkConfigMapping;

    constructor() {
        if (block.chainid == 111_55_111) {
            chainIdToNetworkConfigMapping[block.chainid] = getSepoliaEthConfig();
        } else {
            chainIdToNetworkConfigMapping[block.chainid] = getOrCreateAnvilConfig();
        }
        activeNetworkConfig = chainIdToNetworkConfigMapping[block.chainid];
    }

    function getSepoliaEthConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig ({
            wbtc: SEPOLIA_WBTC,
            weth: SEPOLIA_WETH,
            wbtcUsdPriceFeed: SEPOLIA_WBTC_PRICE_FEED,
            wethUsdPriceFeed: SEPOLIA_WETH_PRICE_FEED,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilConfig() internal returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast(ANVIL_DEFAULT_DEPLOYER_KEY);
        MockV3Aggregator wbtcUsdPriceFeed = new MockV3Aggregator(WBTC_DECIMALS, WBTC_START_PRICE);
        MockV3Aggregator wethUsdPriceFeed = new MockV3Aggregator(WETH_DECIMALS, WETH_START_PRICE);
        ERC20Mock wbtc = new ERC20Mock(
            "Wrapped Bitcoin",
            "wBTC",
            msg.sender,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256(WBTC_START_PRICE)
        );
        ERC20Mock weth = new ERC20Mock(
            "Wrapped Ethereum",
            "wETH",
            msg.sender,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256(WETH_START_PRICE)
        );
        vm.stopBroadcast();

        console.log("Deployed WBTC with addreess:", address(wbtc));
        console.log("Deployed WETH with addreess:", address(weth));

        activeNetworkConfig = NetworkConfig({
            wbtc: address(wbtc),
            weth: address(weth),
            wbtcUsdPriceFeed: address(wbtcUsdPriceFeed),
            wethUsdPriceFeed: address(wethUsdPriceFeed),
            deployerKey: ANVIL_DEFAULT_DEPLOYER_KEY
        });
        return activeNetworkConfig;
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    } 

}