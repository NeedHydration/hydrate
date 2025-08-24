pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hydrate} from "../src/Hydrate.sol";

contract Deploy is Script {
// // Likely move to env var
// address public owner = 0xa03555A5E9729a9bE6FFc92F8fbC50456C0aFc57;
// address public treasury = 0xa03555A5E9729a9bE6FFc92F8fbC50456C0aFc57;

// function run() public {
//     uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
//     address deployer = vm.addr(deployerPrivateKey);
//     console.log("Deploying contracts with deployer:", deployer);
//     vm.startBroadcast(deployerPrivateKey);
//     address snow = address(new Snow(owner, treasury));
//     vm.stopBroadcast();

//     // Log deployments
//     string memory json = vm.serializeJson("contracts", "{}"); // Creates empty JSON object
//     json = _logDeploy("Snow", snow);
//     vm.writeJson(json, "./DeployedContracts.json");
// }

// function _logDeploy(
//     string memory contractName,
//     address deployedAddress
// ) internal returns (string memory) {
//     console.log("Deployed", contractName, "at:", deployedAddress);
//     return vm.serializeAddress("contracts", contractName, deployedAddress);
// }
}
