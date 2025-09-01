// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IQuoter} from "@v3-periphery/interfaces/IQuoter.sol";

contract MockQuoter is IQuoter {
    constructor() {}

    function quoteExactInput(bytes memory, uint256) external pure returns (uint256 amountOut) {
        return 0;
    }

    function quoteExactInputSingle(address, address, uint24, uint256, uint160)
        external
        pure
        returns (uint256 amountOut)
    {
        return 0;
    }

    function quoteExactOutput(bytes memory, uint256) external pure returns (uint256 amountIn) {
        return 0;
    }

    function quoteExactOutputSingle(address, address, uint24, uint256, uint160)
        external
        pure
        returns (uint256 amountIn)
    {
        return 0;
    }
}
