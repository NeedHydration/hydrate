// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRewardVault
/// @notice Interface for the RewardVault contract
interface IRewardVault {
    function getReward(address account, address recipient) external returns (uint256);
}
