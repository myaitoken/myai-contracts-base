// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/MyAIEscrow.sol";

/**
 * @notice Deploy updated MyAIEscrow with adjustable feeBps (starts at 3%).
 *
 * Run:
 *   forge script script/DeployEscrow.s.sol \\
 *     --rpc-url $BASE_RPC \\
 *     --private-key $DEPLOYER_PRIVATE_KEY \\
 *     --broadcast \\
 *     --verify \\
 *     --etherscan-api-key $BASESCAN_API_KEY
 *
 * Env required:
 *   BASE_RPC, DEPLOYER_PRIVATE_KEY, MYAI_TOKEN, COORDINATOR_ADDRESS,
 *   TREASURY_ADDRESS, BASESCAN_API_KEY
 */
contract DeployEscrow is Script {
    function run() external {
        address myaiToken   = vm.envAddress("MYAI_TOKEN");
        address coordinator = vm.envAddress("COORDINATOR_ADDRESS");
        address treasury    = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast();
        MyAIEscrow escrow = new MyAIEscrow(myaiToken, coordinator, treasury);
        vm.stopBroadcast();

        console.log("MyAIEscrow deployed:", address(escrow));
        console.log("  feeBps:   ", escrow.feeBps());
        console.log("  burnBps:  ", escrow.BURN_BPS());
        console.log("  treasury: ", treasury);
    }
}
