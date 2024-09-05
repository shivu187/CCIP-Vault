// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Sender} from "../src/Sender.sol";

contract SenderTest is Script {
    function run() external {
        vm.startBroadcast();
        // address SOURCE_ROUTER = vm.envAddress(SOURCE_ROUTER);
        // address SOURCE_LINK_ADDRESS = vm.envAddress(SOURCE_LINK_ADDRESS);
        // address BASE_USDC = vm.envAddress(BASE_USDC);
        Sender sender = new Sender(
            0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93,
            0xE4aB69C077896252FAFBD49EFD26B5D171A32410,
            0x036CbD53842c5426634e7929541eC2318f3dCF7e
        );
        vm.stopBroadcast();
        console.log("Sender contract", address(sender));
    }
}
