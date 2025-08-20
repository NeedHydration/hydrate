// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import {IMockKHYPE} from "./MockKHYPE.sol";
import {ISwapRouter} from "@v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract MockPool is ISwapRouter {
    IMockKHYPE public immutable KHYPE;

    constructor(address _KHYPE) {
        KHYPE = IMockKHYPE(_KHYPE);
    }

}
