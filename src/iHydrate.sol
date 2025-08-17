// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@solady/tokens/ERC20.sol";
import {Snow} from "./hydrate.sol";
/// @title iSnow
/// @notice Interface for the iSnow contract
/// @dev iSNOW is the inflation token for the Snow protocol
/// @dev iSNOW is minted by the Snow contract and burned by the Snow contract

contract iSnow is ERC20 {
    Snow public immutable snow;

    constructor() {
        snow = Snow(payable(msg.sender));
    }

    mapping(address => bool) public minters;

    event MinterSet(address _contract, bool _allowed);

    modifier onlyMinters() {
        require(msg.sender == address(snow) || minters[msg.sender], "Only Snow or Minters");
        _;
    }

    function setMinter(address _contract, bool _allowed) external {
        require(msg.sender == address(snow), "Only snow");
        minters[_contract] = _allowed;
        emit MinterSet(_contract, _allowed);
    }

    /// @notice Mints iSNOW to a user (only callable by Snow contract)
    function mint(address user, uint256 amount) external onlyMinters {
        _mint(user, amount);
    }

    /// @notice Burns iSNOW from a user (only callable by Snow contract)
    function burn(address user, uint256 amount) external onlyMinters {
        _burn(user, amount);
    }

    /// @notice Burn your own tokens :)
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Returns the name of the token
    function name() public pure override returns (string memory) {
        return "Inflation SNOW";
    }

    /// @notice Returns the symbol of the token
    function symbol() public pure override returns (string memory) {
        return "iSNOW";
    }
}
