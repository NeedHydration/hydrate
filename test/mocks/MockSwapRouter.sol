// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IMockKHYPE} from "./MockKHYPE.sol";
import {ISwapRouter} from "@v3-periphery/interfaces/ISwapRouter.sol";

contract MockSwapRouter is ISwapRouter {
    IMockKHYPE public immutable KHYPE;

    constructor(address _KHYPE) {
        KHYPE = IMockKHYPE(_KHYPE);
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        KHYPE.mint(params.recipient, params.amountIn);
        return 0;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256 amountOut) {
        return 0;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256 amountIn) {
        return 0;
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256 amountIn) {
        return 0;
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external {}
}
