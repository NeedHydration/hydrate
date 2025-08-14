// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Burnable} from "./IERC20Burnable.sol";

/**
 * @title InterfaceSNOW
 * @dev Interface for the Snow contract
 */
interface InterfaceSNOW is IERC20, IERC20Burnable {
    // Events
    event PriceUpdated(uint256 time, uint256 price, uint256 volumeInAvax);
    event MaxUpdated(uint256 max);
    event SellFeeUpdated(uint256 sellFee);
    event SnowTreasuryUpdated(address _address);
    event BuyFeeUpdated(uint256 buyFee);
    event LeverageFeeUpdated(uint256 leverageFee);
    event Started(bool started);
    event Liquidate(uint256 time, uint256 amount);
    event LoanDataUpdate(
        uint256 collateralByDate,
        uint256 borrowedByDate,
        uint256 totalBorrowed,
        uint256 totalCollateral
    );
    event SendAvax(address to, uint256 amount);

    // Constants
    function DUST() external view returns (uint256);
    function COLLATERAL_RATIO() external view returns (uint256);
    function BPS_DENOMINATOR() external view returns (uint256);
    function PROTOCOL_FEE_SHARE_BPS() external view returns (uint256);
    function INTEREST_APR_1e18() external view returns (uint256);
    function ORIGINATION_FEE_1e18() external view returns (uint256);

    // State Variables
    function snowTreasury() external view returns (address payable);
    function burnFeeBps() external view returns (uint256);
    function freezeFeeBps() external view returns (uint256);
    function leverageFeeBps() external view returns (uint256);
    function started() external view returns (bool);
    function whitelist() external view returns (bool);
    function maxSupply() external view returns (uint256);
    function totalFreezed() external view returns (uint256);
    function lastPrice() external view returns (uint256);
    function activeLoans(
        address user
    ) external view returns (uint256, uint256, uint256, uint256, uint256);
    function loansByDate(uint256 date) external view returns (uint256);
    function collateralByDate(uint256 date) external view returns (uint256);
    function lastLiquidateDate() external view returns (uint256);
    function tokenLockerFeeBps() external view returns (uint256);
    function totalLockedTokens(address token) external view returns (uint256);
    function lockedTokens(
        address user,
        address token
    ) external view returns (uint256, uint256);

    // Owner settings
    function getWhitelistAllowance(
        address _address
    ) external view returns (uint256);
    function setStart() external payable;
    function setSnowTreasury(address _address) external;
    function setFreezeFee(uint256 amount) external;
    function setLeverageFee(uint256 amount) external;
    function setBurnFee(uint256 amount) external;
    function increaseMaxSupply(uint256 amount) external;
    function setTokenLockerFee(uint256 amount) external;
    function setBribeBounty(uint256 amount) external;

    // External functions
    function buy(address receiver) external payable;
    function freeze(address receiver) external payable;
    function burn(uint256 snow) external;
    function loop(uint256 avax, uint256 numberOfDays) external payable;
    function borrow(uint256 avax, uint256 numberOfDays) external;
    function increaseBorrow(uint256 avax) external;
    function removeCollateral(uint256 amount) external;
    function repay() external payable;
    function closePosition() external payable;
    function flashBurn() external;
    function extendLoan(
        uint256 numberOfDays
    ) external payable returns (uint256);
    function liquidate() external;
    function lockTokens(
        address token,
        uint256 amount,
        uint256 unlockTime
    ) external;
    function unlockTokens(address token) external;
    function claimBribeBounty(address[] calldata tokens) external payable;

    // Utility functions
    function getDayStart(uint256 date) external pure returns (uint256);
    function getLoansExpiringByDate(
        uint256 date
    ) external view returns (uint256, uint256);
    function getLoanByAddress(
        address _address
    ) external view returns (uint256, uint256, uint256);
    function leverageFee(
        uint256 avax,
        uint256 numberOfDays
    ) external view returns (uint256);
    function getInterestFee(
        uint256 amount,
        uint256 numberOfDays
    ) external view returns (uint256);
    function isLoanExpired(address _address) external view returns (bool);
    function getBacking() external view returns (uint256);
    function SNOWtoAVAXFloor(uint256 value) external view returns (uint256);
    function AVAXtoSNOWFloor(uint256 value) external view returns (uint256);
    function AVAXtoSNOWLev(
        uint256 value,
        uint256 fee
    ) external view returns (uint256);
    function AVAXtoSNOWNoTradeCeil(
        uint256 value
    ) external view returns (uint256);
    function AVAXtoSNOWNoTradeFloor(
        uint256 value
    ) external view returns (uint256);
    function getAmountOutBuy(
        uint256 avaxAmount
    ) external view returns (uint256);
    function getAmountOutSell(
        uint256 snowAmount
    ) external view returns (uint256);
    function totalLoans() external view returns (uint256);
    function totalCollateral() external view returns (uint256);
}
