// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IERC20Burnable
/// @notice Interface for the ERC20Burnable contract
/// @dev Based on OpenZeppelin's ERC20Burnable contract https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC20Burnable.sol
interface IERC20Burnable {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
