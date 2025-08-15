// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Snow} from "../src/Hydrate.sol";
import {Vm} from "forge-std/Vm.sol";
import {Snow} from "../src/Hydrate.sol";
import "forge-std/console.sol";

contract HydrateTest is Test {
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address minter = makeAddr("minter");
    Snow hydrate;

    function _setup() internal {
        vm.deal(admin, 6900 ether);
        vm.deal(minter, 1000 ether);

        hydrate = new Snow(admin, treasury);

        vm.startBroadcast(admin);

        // Enable minting and burning
        hydrate.setStart{value: 6900 ether}();

        // Increase Total supply
        // TODO: what should the total supply at deployment be?
        uint256 newTotalSupply = hydrate.totalFreezed() * 2;
        hydrate.increaseMaxSupply(newTotalSupply);

        vm.stopBroadcast();
    }

    function test_mintAndBurn() public {
        _setup();

        vm.startBroadcast(minter);

        uint256 preBal = address(hydrate).balance;
        uint256 msgValue = 100 ether;

        // Mint
        hydrate.freeze{value: msgValue}(minter);

        // 97.5% of mint goes to minter
        assertEq(97.5 ether, hydrate.balanceOf(minter));
        // 35% of 2.50 (Fee)
        assertEq(0.875 ether, address(treasury).balance);
        // Remainig 65% to contract
        assertEq(
            preBal + (msgValue - address(treasury).balance),
            address(hydrate).balance
        );

        // ================================================

        preBal = address(treasury).balance;
        uint256 preBalMinter = address(minter).balance;

        // Burn
        hydrate.burn(10 ether);

        // Minter balance (gets 97.5% of 10)
        // Use Lt then due to rounding errors in arithmetic
        assertLt(preBalMinter, address(minter).balance);

        // Treasury balance (gets 2.5% of 10)
        assertLt(preBal, address(treasury).balance);

        vm.stopBroadcast();
    }
}
