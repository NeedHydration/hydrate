// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISovereignPool} from "../../lib/valantis-core/src/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams} from "../../lib/valantis-core/src/pools/structs/SovereignPoolStructs.sol";
import {IFlashBorrower} from "../../lib/valantis-core/src/pools/interfaces/IFlashBorrower.sol";
import {IMockKHYPE} from "./MockKHYPE.sol";

contract MockPool is ISovereignPool {
    IMockKHYPE public immutable KHYPE;

    constructor(address _KHYPE) {
        KHYPE = IMockKHYPE(_KHYPE);
    }

    function getTokens() external pure returns (address[] memory) {
        return new address[](0);
    }

    function sovereignVault() external pure returns (address) {
        return address(0);
    }

    function protocolFactory() external pure returns (address) {
        return address(0);
    }

    function gauge() external pure returns (address) {
        return address(0);
    }

    function poolManager() external pure returns (address) {
        return address(0);
    }

    function sovereignOracleModule() external pure returns (address) {
        return address(0);
    }

    function swapFeeModule() external pure returns (address) {
        return address(0);
    }

    function verifierModule() external pure returns (address) {
        return address(0);
    }

    function isLocked() external pure returns (bool) {
        return false;
    }

    function isRebaseTokenPool() external pure returns (bool) {
        return false;
    }

    function poolManagerFeeBips() external pure returns (uint256) {
        return 0;
    }

    function defaultSwapFeeBips() external pure returns (uint256) {
        return 0;
    }

    function swapFeeModuleUpdateTimestamp() external pure returns (uint256) {
        return 0;
    }

    function alm() external pure returns (address) {
        return address(0);
    }

    function getPoolManagerFees() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function getReserves() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function setPoolManager(address) external {}

    function setGauge(address) external {}

    function setPoolManagerFeeBips(uint256) external {}

    function setSovereignOracle(address) external {}

    function setSwapFeeModule(address) external {}

    function setALM(address) external {}

    function swap(SovereignPoolSwapParams calldata params) external returns (uint256, uint256) {
        KHYPE.mint(params.recipient, params.amountIn);
        return (params.amountIn, params.amountOutMin);
    }

    function depositLiquidity(uint256, uint256, address, bytes calldata, bytes calldata)
        external pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function withdrawLiquidity(uint256, uint256, address, address, bytes calldata) external {}

    // IValantisPool functions
    function token0() external pure returns (address) {
        return address(0);
    }

    function token1() external pure returns (address) {
        return address(0);
    }

    function claimProtocolFees() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function claimPoolManagerFees(uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function flashLoan(bool, IFlashBorrower, uint256, bytes calldata) external {}
}
