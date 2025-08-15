// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockKHYPE is ERC20 {
    constructor() ERC20("KHYPE", "KHYPE") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}