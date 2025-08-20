// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IQuoter} from "@v3-periphery/interfaces/IQuoter.sol";

contract MockQuoter is IQuoter {
    constructor() {}

    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut) {
        return 0;
    }

    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut) {
        return 0;
    }

    function quoteExactOutput(bytes memory path, uint256 amountOut) external returns (uint256 amountIn) {
        return 0;
    }

    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountIn) {
        return 0;
    }
}
