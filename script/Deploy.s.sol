// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GigaVault} from "../src/GigaVault.sol";

/** @dev deployment:
    forge script script/Deploy.s.sol --rpc-url mega_mainnet --broadcast --private-key $PRIVATE_KEY \
    --skip-simulation --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 --slow
*/
contract DeployScript is Script {
    function run() public {
        vm.startBroadcast();

        GigaVault vault = new GigaVault();

        console.log("GigaVault deployed at:", address(vault));
        console.log("USDmY address:", vault.USDMY());
        console.log("Owner:", vault.owner());
        console.log("Deployment time:", block.timestamp);
        console.log("Minting end time:", block.timestamp + 3 days);

        vm.stopBroadcast();
    }
}
