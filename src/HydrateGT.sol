// pragma solidity 0.8.28;

// import {ERC20} from "@solady/tokens/ERC20.sol";
// import {Snow} from "./hydrate.sol";

// /// @title Snow
// /// @author Snow
// /// @notice Avax-native DeFi protocol with a bonding curve mechanism, built-in lending, staking, and gameFi elements
// /// @dev SNOW can be freezed with AVAX
// /// @dev Launchpad: Authorized freezer contracts can pool deposits to freeze SNOW
// /// @dev Auto TWAP: Add any ERC20 token, will twap into AVAX and add to SNOW backing
// /// @dev Looping: 100x loop SNOW/AVAX in single-click
// /// @dev Token Locker: lock any ERC20 token with SNOW and contribute to growing SNOW
// /// @dev Multicallable: all actions within SNOW can be batched in single click
// /// @dev Liquid BGT: Mint SnowGT by claiming BGT through Snow, redeem SnowGT for SNOW
// /// @dev Proof-of-Liquidity: Earn BGT by staking iSNOW, or SNOW-OHM LP
// /// @dev Staking: Stake SNOW into iSNOW. iSNOW has elastic supply, controlled by authorized contracts
// /// @dev GameFi: Participate in games of chance with iSNOW liquidity

// //SnowGT
// contract SnowGT is ERC20 {
//     Snow public immutable snow;

//     constructor() {
//         snow = Snow(payable(msg.sender));
//     }

//     modifier onlySnow() {
//         require(msg.sender == address(snow), "Only Snow");
//         _;
//     }

//     /// @notice Only SNOW contract is authorized minter
//     function mint(address user, uint256 amount) external onlySnow {
//         _mint(user, amount);
//     }

//     /// @notice No authorized burners, withdrawal contract will handle burn
//     function burn(uint256 amount) external {
//         _burn(msg.sender, amount);
//     }

//     /// @notice Returns the name of the token
//     function name() public pure override returns (string memory) {
//         return "Snow BGT";
//     }

//     /// @notice Returns the symbol of the token
//     function symbol() public pure override returns (string memory) {
//         return "SnowGT";
//     }
// }
