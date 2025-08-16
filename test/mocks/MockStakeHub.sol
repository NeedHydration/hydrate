// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import {MockKHYPE} from "./MockKHYPE.sol";
import {IStakeHub} from "../../src/interfaces/IStakeHub.sol";

contract MockStakeHub is IStakeHub {
    MockKHYPE public kHYPE;

    constructor(address _kHYPE) {
        kHYPE = MockKHYPE(_kHYPE);
    }

    function stake() public payable {
        kHYPE.mint(msg.sender, msg.value);
    }

    function unstake(uint256 amount) public {
        kHYPE.transfer(msg.sender, amount);
    }
}
