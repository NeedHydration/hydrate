// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMockKHYPE {
    function mint(address, uint256) external;
}

contract MockKHYPE is ERC20, IMockKHYPE {
    constructor() ERC20("KHYPE", "KHYPE") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
