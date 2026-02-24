// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../src/MockERC20.sol";

/** @dev deployment:
    forge script script/DeployMockERC20.s.sol --rpc-url mega_mainnet --broadcast --private-key $PRIVATE_KEY \
    --skip-simulation --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 --slow
*/
contract DeployMockERC20Script is Script {
    function run() public {
        vm.startBroadcast();

        // Deploy mock USDmY token (with 18 decimals)
        MockERC20 mockToken = new MockERC20("Mock USDmY", "USDmY");

        console.log("Mock USDmY deployed at:", address(mockToken));

        vm.stopBroadcast();
    }
}
