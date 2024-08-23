//SPDX-License-Identifier:MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {console} from "forge-std/console.sol";

contract DeployDSC is Script {

    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin,DSCEngine,HelperConfig) {

        HelperConfig config = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) = config.activeNewtworkConfig();

        tokenAddresses=[wbtc, weth];
        priceFeedAddresses=[wbtcUsdPriceFeed,wethUsdPriceFeed];
        
        vm.startBroadcast(deployerKey);
        

        //to deploy Decentralized stable coin
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();

        //takes tokenAddresses and priceFeedAddresses and dsc Address as params in its contructor
        DSCEngine dscEngine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );

        vm.stopBroadcast();

        return (dsc, dscEngine, config);
    }

}
