// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISTEXAMM} from "@valantis-stex/interfaces/ISTEXAMM.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";

contract MockAMM is ISTEXAMM {
    constructor() {}

    function isLocked() external pure returns (bool) {
        return false;
    }

    function pool() external pure returns (address) {
        return address(0);
    }

    function token0() external pure returns (address) {
        return address(0);
    }

    function token1() external pure returns (address) {
        return address(0);
    }

    function poolFeeRecipient1() external pure returns (address) {
        return address(0);
    }

    function poolFeeRecipient2() external pure returns (address) {
        return address(0);
    }

    function withdrawalModule() external pure returns (address) {
        return address(0);
    }

    function pause() external {}

    function unpause() external {}

    function proposeSwapFeeModule(address, uint256) external {}

    function cancelSwapFeeModuleProposal() external {}

    function setProposedSwapFeeModule() external {}

    function proposeWithdrawalModule(address) external {}

    function cancelWithdrawalModuleProposal() external {}

    function setProposedWithdrawalModule() external {}

    function setPoolManagerFeeBips(uint256) external {}

    function claimPoolManagerFees() external {}

    function unstakeToken0Reserves(uint256) external {}

    function supplyToken1Reserves(uint256) external {}

    function getAmountOut(address token, uint256 amountOut, bool isInstantWithdraw) external pure returns (uint256) {
        return amountOut;
    }

    function deposit(uint256, uint256, uint256, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, uint256, uint256, uint256, address, bool, bool)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function onDepositLiquidityCallback(uint256, uint256, bytes memory) external {}

    function onSwapCallback(bool, uint256, uint256) external {}

    function getLiquidityQuote(ALMLiquidityQuoteInput memory, bytes calldata, bytes calldata)
        external
        pure
        returns (ALMLiquidityQuote memory)
    {
        return ALMLiquidityQuote({isCallbackOnSwap: false, amountOut: 0, amountInFilled: 0});
    }
}
