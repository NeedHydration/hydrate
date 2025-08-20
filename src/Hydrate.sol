/*
    TODO: REPLACE 
	Snow
	SNOW on Avalanche is based on BREAD.
*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@solady/tokens/ERC20.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {ReentrancyGuard} from "@solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Multicallable} from "@solady/utils/Multicallable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";
import {Panic} from "@openzeppelin/contracts/utils/Panic.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IRewardVault} from "./interfaces/IRewardVault.sol";
import {InterfaceSNOW} from "./interfaces/InterfaceHydrate.sol";
import {iSnow} from "./iHydrate.sol";
import {SnowGT} from "./HydrateGT.sol";
import {IStakeHub} from "./interfaces/IStakeHub.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IQuoter} from "@v3-periphery/interfaces/IQuoter.sol";
import {ISwapRouter} from "@v3-periphery/interfaces/ISwapRouter.sol";

// Snow
contract Snow is ERC20, Ownable, ReentrancyGuard, Multicallable {
    using SafeTransferLib for address;
    using SafeERC20 for IERC20;

    /// @notice Struct representing a user's loan
    /// @param collateral Amount of SNOW tokens staked as collateral
    /// @param borrowed Amount of AVAX borrowed against the collateral
    /// @param endDate Timestamp when the loan expires
    /// @param numberOfDays Duration of the loan in days
    struct Loan {
        uint256 collateral; // shares of token staked
        uint256 borrowed; // user reward per token paid
        uint256 endDate;
        uint256 numberOfDays;
        uint256 lastTimeCreated;
    }

    struct LockedToken {
        uint256 amount;
        uint256 unlockTime;
    }

    mapping(address => mapping(address => LockedToken)) public lockedTokens; //user -> token -> LockTokens
    mapping(address => uint256) public totalLockedTokens; //Total locked balance per token

    // Borrowing
    uint256 public constant COLLATERAL_RATIO = 9900;
    uint256 public constant INTEREST_APR_BPS = 690; //6.9%
    bool public borrowingEnabled;

    // Constants
    uint256 public constant DUST = 1000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 3500;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    //Mutable, owner-only setting variables
    IERC20 public KHYPE;
    IStakeHub public stakeHub;
    IQuoter public quoter;
    ISwapRouter public swapRouter;
    address public constant WHYPE = 0x5555555555555555555555555555555555555555;

    address payable public snowTreasury;
    // TODO: confirm these
    uint256 public freezeFeeBps = 250;
    uint256 public burnFeeBps = 250;
    uint256 public leverageFeeBps = 142;
    address public freezer;

    //Global state variables
    bool public started;
    uint256 public totalLoans;
    uint256 public totalCollateral;
    uint256 public maxFreeze;
    uint256 public totalFreezed;
    uint256 public prevPrice;

    //User state variables
    mapping(address => Loan) public activeLoans;

    //Global by date state variables
    mapping(uint256 => uint256) public loansByDate;
    mapping(uint256 => uint256) public collateralByDate;
    uint256 public lastLiquidateDate;

    //***************************************************
    //  Constructor

    /// @notice Initializes the Snow contract
    /// @dev Sets the initial lastLiquidateDate and snowTreasury, deploy iSnow and snowGT
    constructor(
        address _owner,
        address _treasury,
        address _KHYPE,
        address _stakeHub,
        address _quoter,
        address _swapRouter
    ) {
        require(_owner != address(0), "Owner cannot be 0 address");
        require(_treasury != address(0), "Treasury cannot be 0 address");
        require(_KHYPE != address(0), "KHYPE cannot be 0 address");
        require(_stakeHub != address(0), "StakeHub cannot be 0 address");

        _initializeOwner(_owner);
        lastLiquidateDate = getDayStart(block.timestamp);
        snowTreasury = payable(_treasury);
        KHYPE = IERC20(_KHYPE);
        stakeHub = IStakeHub(_stakeHub);
        quoter = IQuoter(_quoter);
        swapRouter = ISwapRouter(_swapRouter);
    }

    //***************************************************
    //  ERC20 settings
    function name() public pure override returns (string memory) {
        return "Hydrate";
    }

    function symbol() public pure override returns (string memory) {
        return "H20";
    }

    //***************************************************
    //  Owner settings

    // TODO: move me
    function _start(uint256 amount) internal {
        require(!started && maxFreeze == 0, "Trading already initialized");
        require(amount == 6900 ether, "Must send 6900 KHYPE to start trading");

        started = true;
        borrowingEnabled = true;

        uint256 masterFreezerFreeze = amount; // sets initial price to 1 AVAX
        maxFreeze = masterFreezerFreeze;

        _freeze(msg.sender, masterFreezerFreeze);

        emit MaxFreezeUpdated(masterFreezerFreeze);
        emit Started(true);
    }

    function setStartKHYPE(uint256 amount) public payable onlyOwner {
        _start(amount);
        KHYPE.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Starts freezing and burning for the SNOW token
    /// @dev Requires that fee address is set and must send 6900 AVAX
    /// @dev Requires that the maxSupply is 0 and trading hasn't already started
    /// Mints initial SNOW to the owner and burns 0.1 SNOW
    function setStart() public payable onlyOwner {
        _start(msg.value);
        stakeHub.stake{value: msg.value}();
    }

    /// @notice Sets the freezer address
    /// @param _freezer The address of the freezer contract
    /// @dev The freezer contract can mint and increase total supply atomically
    function setFreezer(address _freezer) external onlyOwner {
        freezer = _freezer;
        emit FreezerSet(_freezer);
    }

    /// @notice Increase the maxFreeze
    /// @param _maxFreeze The new maximum supply of SNOW
    /// @dev Requires its increasing and higher than total freezed
    function increaseMaxSupply(uint256 _maxFreeze) external onlyOwner {
        require(_maxFreeze > totalFreezed, "Max supply must be greater than total freezed");
        require(_maxFreeze > maxFreeze, "Increase only");
        maxFreeze = _maxFreeze;
        emit MaxFreezeUpdated(_maxFreeze);
    }

    /// @notice Sets the fee recipient address
    /// @param _address The new fee address
    /// @dev Cannot be the zero address
    function setSnowTreasury(address _address) external onlyOwner {
        require(_address != address(0), "Can't set fee address to 0 address");
        snowTreasury = payable(_address);
        emit SnowTreasuryUpdated(_address);
    }

    /// @notice Sets the freeze fee
    /// @param amount The new freeze fee
    /// @dev Fee is in basis points, must be between 1-5%
    function setFreezeFee(uint256 amount) external onlyOwner {
        require(amount >= 100, "freeze fee must be greater than 1%");
        require(amount <= 500, "freeze fee must be less than 5%");
        require(amount >= leverageFeeBps, "freeze fee must be greater than leverage fee");
        freezeFeeBps = amount;
        emit FreezeFeeUpdated(amount);
    }

    /// @notice Sets the leverage fee
    /// @param amount The new leverage fee
    /// @dev Fee is in basis points, must be between 0.5% and 2.5%
    function setLeverageFee(uint256 amount) external onlyOwner {
        require(amount >= 50, "leverage fee must be greater than 0.5%");
        require(amount <= 250, "leverage fee must be less than 2.5%");
        require(amount <= freezeFeeBps, "leverage fee must be less than freeze fee");
        leverageFeeBps = amount;
        emit LeverageFeeUpdated(amount);
    }

    /// @notice Sets the burn fee
    /// @param amount The new burn fee
    /// @dev Fee is in basis points, must be between 1-5%
    function setBurnFee(uint256 amount) external onlyOwner {
        require(amount >= 100, "burn fee must be greater than 1%");
        require(amount <= 500, "burn fee must be less than 5%");
        burnFeeBps = amount;
        emit BurnFeeUpdated(amount);
    }

    /// @notice Enable borrowing
    /// @param _enabled Whether borrowing is enabled
    function enableBorrowing(bool _enabled) external onlyOwner {
        borrowingEnabled = _enabled;
        emit BorrowingEnabled(_enabled);
    }

    /// @notice Recover ERC20 tokens from the contract after snow is freezed
    /// @param _token Address of the token to recover
    /// @dev Unruggable because it can only recover erc20s that are not snow (mistakenly donated or farmed tokens)
    function recoverERC20(address _token) external onlyOwner {
        require(_token != address(this), "Snow: can only recover erc20s that are not snow");
        _token.safeTransfer(msg.sender, _token.balanceOf(address(this)));
    }

    //***************************************************
    //  External functions

    function freezeKHYPE(address receiver, uint256 amount) external nonReentrant {
        KHYPE.transferFrom(msg.sender, address(this), amount);
        _freezeSnow(receiver, amount);
    }

    /// @notice Buys SNOW tokens with AVAX
    /// @param receiver The address to receive the SNOW tokens
    /// @dev Requires trading to be started
    /// Mints SNOW to the receiver based on the current price
    function freeze(address receiver) external payable nonReentrant {
        uint256 amount = msg.value;
        stakeHub.stake{value: amount}();
        _freezeSnow(receiver, amount);
    }

    function _freezeSnow(address receiver, uint256 amount) internal {
        liquidate();
        require(started, "Trading must be initialized");

        require(receiver != address(0), "Receiver cannot be 0 address");

        // Calculate amount of snow to recieve
        uint256 snow = AVAXtoSNOWFloor(amount);
        uint256 snowToFreeze = (snow * (BPS_DENOMINATOR - freezeFeeBps)) / BPS_DENOMINATOR;

        if (msg.sender == freezer) {
            // check if we need to increase max supply
            if (totalFreezed + snowToFreeze > maxFreeze) {
                uint256 _maxFreeze = maxFreeze + snowToFreeze;
                maxFreeze = _maxFreeze;
                emit MaxFreezeUpdated(_maxFreeze);
            }
        }

        // Mint SNOW to receiver
        _freeze(receiver, snowToFreeze);

        // Calculate Treasury Fee and deduct
        uint256 treasuryAmount = (amount * freezeFeeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "must trade over min");
        KHYPE.safeTransfer(snowTreasury, treasuryAmount);

        _riseOnly(amount);
        emit Freeze(receiver, amount, snowToFreeze);
    }

    /// @notice Sells SNOW tokens for AVAX
    /// @param snow The amount of SNOW to sell
    /// @dev Burns SNOW and sends AVAX to the sender based on the current price
    function burn(uint256 snow) external nonReentrant {
        liquidate();

        // Total Avax to be sent
        uint256 avax = SNOWtoAVAXFloor(snow); //Rounds down user amount (in favor of protocol)

        // Burn of Snow
        _burn(msg.sender, snow);

        // Payment to sender
        uint256 avaxToPay = (avax * (BPS_DENOMINATOR - burnFeeBps)) / BPS_DENOMINATOR;
        KHYPE.safeTransfer(msg.sender, avaxToPay);

        // Treasury fee
        uint256 treasuryAmount = (avax * burnFeeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "must trade over min");
        KHYPE.safeTransfer(snowTreasury, treasuryAmount);

        _riseOnly(avax);
        emit Burn(msg.sender, avaxToPay, snow);
    }

    // TODO: natspec
    // redeem function that unwraps backing KHYPE to HYPE
    function burnHype(uint256 snow) external nonReentrant {
        liquidate();

        // Total Hype to be sent
        uint256 hype = SNOWtoAVAXFloor(snow);

        // Burn SNOW
        _burn(msg.sender, snow);

        // Handle fees before swapping
        // Treasury fee
        uint256 treasuryAmount = (hype * burnFeeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "must trade over min");
        KHYPE.safeTransfer(snowTreasury, treasuryAmount);

        // Amount Hype the user will recieve
        uint256 hypeToSwap = (hype * (BPS_DENOMINATOR - burnFeeBps)) / BPS_DENOMINATOR;

        // Fee param for swap, do highest tier
        uint24 fee = 10000;
        // Calculate the expected amount of hype to recieve from DEX
        uint256 amountOut = quoter.quoteExactInputSingle(address(KHYPE), WHYPE, fee, hypeToSwap, 0);
        // TODO: make slippage configurable?
        uint256 amountOutWithSlippage = (amountOut * 98) / 100;

        // Swap params
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(KHYPE),
            tokenOut: WHYPE,
            fee: fee,
            recipient: msg.sender,
            deadline: block.timestamp + 10 minutes,
            amountIn: hypeToSwap,
            amountOutMinimum: amountOutWithSlippage,
            sqrtPriceLimitX96: 0
        });

        // Swap KHYPE to HYPE
        swapRouter.exactInputSingle(swapParams);

        _riseOnly(hype);
        emit Burn(msg.sender, hypeToSwap, snow);
    }

    // TODO: Accept $HYPE as well?
    /// @notice Creates a leveraged position
    /// @param avax The amount of AVAX to loop
    /// @param numberOfDays The duration of the loan in days
    /// @dev Requires trading to be started
    ///     Creates a loan with collateral and borrowed amount
    function loop(uint256 avax, uint256 numberOfDays) public nonReentrant {
        require(started, "Trading must be initialized");
        require(borrowingEnabled, "Borrowing is disabled");
        require(numberOfDays < 366, "Max borrow/extension must be 365 days or less");

        Loan memory userLoan = activeLoans[msg.sender];
        if (userLoan.borrowed != 0) {
            if (isLoanExpired(msg.sender)) {
                delete activeLoans[msg.sender];
            }
            require(activeLoans[msg.sender].borrowed == 0, "Use account with no loans");
        }

        liquidate();
        uint256 endDate = getDayStart((numberOfDays * 1 days) + block.timestamp);

        (uint256 freezeFee, uint256 userBorrow, uint256 overCollateralizationAmount, uint256 interestFee) =
            loopCalcs(avax, numberOfDays);

        uint256 totalAvaxRequired = overCollateralizationAmount + freezeFee + interestFee;
        KHYPE.safeTransferFrom(msg.sender, address(this), totalAvaxRequired);
        // uint256 feeOverage;
        // if (msg.value > totalAvaxRequired) {
        //     feeOverage = msg.value - totalAvaxRequired;
        //     _sendAvax(msg.sender, feeOverage);
        // }
        // require(msg.value - feeOverage == totalAvaxRequired, "Insufficient avax fee sent");

        uint256 userAvax = avax - freezeFee;
        uint256 userSnow = AVAXtoSNOWLev(userAvax, totalAvaxRequired);
        _freeze(address(this), userSnow);

        uint256 treasuryAmount = ((freezeFee + interestFee) * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "Fees must be higher than dust");
        KHYPE.safeTransfer(snowTreasury, treasuryAmount);

        _addLoansOnDate(userBorrow, userSnow, endDate);
        activeLoans[msg.sender] = Loan({
            collateral: userSnow,
            borrowed: userBorrow,
            endDate: endDate,
            numberOfDays: numberOfDays,
            lastTimeCreated: block.timestamp
        });

        _riseOnly(avax);
        emit Loop(msg.sender, avax, numberOfDays, userSnow, userBorrow, totalAvaxRequired);
    }

    /// @notice Creates a loan by borrowing AVAX against SNOW collateral
    /// @param avax The amount of AVAX to borrow
    /// @param numberOfDays The duration of the loan in days
    /// @dev Requires no existing loan
    /// @dev Use increaseBorrow with existing loan
    function borrow(uint256 avax, uint256 numberOfDays) public nonReentrant {
        require(borrowingEnabled, "Borrowing is disabled");
        require(numberOfDays <= 365, "Max borrow/extension must be 365 days or less");
        require(avax != 0, "Must borrow more than 0");
        if (isLoanExpired(msg.sender)) {
            delete activeLoans[msg.sender];
        }
        require(activeLoans[msg.sender].borrowed == 0, "Use increaseBorrow to borrow more");

        liquidate();
        uint256 endDate = getDayStart((numberOfDays * 1 days) + block.timestamp);

        uint256 newUserBorrow = (avax * COLLATERAL_RATIO) / BPS_DENOMINATOR;

        uint256 avaxFee = getInterestFee(newUserBorrow, numberOfDays);

        uint256 treasuryFee = (avaxFee * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;

        uint256 userSnow = AVAXtoSNOWNoTradeCeil(avax); //Rounds up borrow amount (in favor of protocol)

        activeLoans[msg.sender] = Loan({
            collateral: userSnow,
            borrowed: newUserBorrow,
            endDate: endDate,
            numberOfDays: numberOfDays,
            lastTimeCreated: block.timestamp
        });

        _transfer(msg.sender, address(this), userSnow);
        require(treasuryFee > DUST, "Fees must be higher than dust");

        KHYPE.safeTransfer(msg.sender, newUserBorrow - avaxFee);
        KHYPE.safeTransfer(snowTreasury, treasuryFee);

        _addLoansOnDate(newUserBorrow, userSnow, endDate);

        _riseOnly(avaxFee);
        emit Borrow(msg.sender, avax, numberOfDays, userSnow, newUserBorrow, avaxFee);
    }

    /// @notice Increases an existing loan by borrowing more AVAX
    /// @param avax The additional amount of AVAX to borrow
    /// @dev Requires an active non-expired loan
    function increaseBorrow(uint256 avax) public nonReentrant {
        require(borrowingEnabled, "Borrowing is disabled");
        require(!isLoanExpired(msg.sender), "Loan expired use borrow");
        require(avax != 0, "Must borrow more than 0");
        liquidate();
        uint256 userBorrowed = activeLoans[msg.sender].borrowed;
        uint256 userCollateral = activeLoans[msg.sender].collateral;
        uint256 userEndDate = activeLoans[msg.sender].endDate;

        uint256 todayMidnight = getDayStart(block.timestamp);
        uint256 newBorrowLength = (userEndDate - todayMidnight) / 1 days;

        uint256 newUserBorrow = (avax * COLLATERAL_RATIO) / BPS_DENOMINATOR;
        uint256 avaxFee = getInterestFee(newUserBorrow, newBorrowLength);

        uint256 userBorrowedInSnow = AVAXtoSNOWNoTradeCeil(userBorrowed); //Rounds up borrow amount (in favor of protocol)
        uint256 userExcessInSnow =
            userCollateral - Math.mulDiv(userBorrowedInSnow, BPS_DENOMINATOR, COLLATERAL_RATIO, Math.Rounding.Ceil); //Rounds up (in favor of protocol)

        uint256 userSnow = AVAXtoSNOWNoTradeCeil(avax); //Rounds up borrow amount (in favor of protocol)
        uint256 requireCollateralFromUser = userExcessInSnow >= userSnow ? 0 : userSnow - userExcessInSnow;

        {
            uint256 newUserBorrowTotal = userBorrowed + newUserBorrow;
            uint256 newUserCollateralTotal = userCollateral + requireCollateralFromUser;
            activeLoans[msg.sender] = Loan({
                collateral: newUserCollateralTotal,
                borrowed: newUserBorrowTotal,
                endDate: userEndDate,
                numberOfDays: newBorrowLength,
                lastTimeCreated: block.timestamp
            });
        }

        if (requireCollateralFromUser != 0) {
            _transfer(msg.sender, address(this), requireCollateralFromUser);
        }

        {
            uint256 treasuryFee = (avaxFee * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;
            require(treasuryFee > DUST, "Fees must be higher than dust");
            KHYPE.safeTransfer(snowTreasury, treasuryFee);
        }

        KHYPE.safeTransfer(msg.sender, newUserBorrow - avaxFee);
        _addLoansOnDate(newUserBorrow, requireCollateralFromUser, userEndDate);

        _riseOnly(avaxFee);
        emit Borrow(msg.sender, avax, newBorrowLength, userSnow, newUserBorrow, avaxFee);
    }

    /// @notice Removes collateral from an active loan
    /// @param amount The amount of SNOW collateral to remove
    /// @dev Requires an active non-expired loan and maintains collateralization ratio
    function removeCollateral(uint256 amount) public nonReentrant {
        require(!isLoanExpired(msg.sender), "No active loans");
        liquidate();
        uint256 collateral = activeLoans[msg.sender].collateral;
        uint256 remainingCollateralInAvax = SNOWtoAVAXFloor(collateral - amount); //Rounds down user amount (in favor of protocol)

        require(
            activeLoans[msg.sender].borrowed <= (remainingCollateralInAvax * COLLATERAL_RATIO) / BPS_DENOMINATOR,
            "Require 99% collateralization rate"
        );
        activeLoans[msg.sender].collateral = activeLoans[msg.sender].collateral - amount;
        _transfer(address(this), msg.sender, amount);
        _subtractLoansOnDate(0, amount, activeLoans[msg.sender].endDate);

        _riseOnly(0);

        emit RemoveCollateral(msg.sender, amount);
    }

    /// @notice Partially repays an active loan
    /// @dev Requires an active non-expired loan and repayment amount less than borrowed
    function repay(uint256 amount) public nonReentrant {
        uint256 borrowed = activeLoans[msg.sender].borrowed;
        require(borrowed > amount, "Must repay less than borrowed amount");
        require(amount > 0, "Repay amount must be greater than 0");
        liquidate();
        require(!isLoanExpired(msg.sender), "Your loan has been liquidated, cannot repay");
        uint256 newBorrow = borrowed - amount;
        activeLoans[msg.sender].borrowed = newBorrow;
        _subtractLoansOnDate(amount, 0, activeLoans[msg.sender].endDate);

        KHYPE.safeTransferFrom(msg.sender, address(this), amount);
        _riseOnly(0);

        emit Repay(msg.sender, amount, newBorrow);
    }

    /// @notice Fully repays a loan and returns collateral
    /// @dev Requires an active non-expired loan and exact repayment amount
    /// @dev Applies a 1% fee on the collateral value
    function closePosition(uint256 amount) public nonReentrant {
        uint256 borrowed = activeLoans[msg.sender].borrowed;
        uint256 collateral = activeLoans[msg.sender].collateral;
        require(!isLoanExpired(msg.sender), "No active loans");
        require(borrowed == amount, "Must return entire borrowed amount");

        liquidate();
        _transfer(address(this), msg.sender, collateral);
        KHYPE.safeTransferFrom(msg.sender, address(this), amount);
        _subtractLoansOnDate(borrowed, collateral, activeLoans[msg.sender].endDate);

        delete activeLoans[msg.sender];
        _riseOnly(0);

        emit Repay(msg.sender, amount, 0);
    }

    /// @notice Allows users to close their loan positions by using their SNOW collateral directly
    /// @dev Requires an active non-expired loan with sufficient collateral value
    function flashBurn() public nonReentrant {
        require(!isLoanExpired(msg.sender), "No active loan");
        liquidate();
        uint256 borrowed = activeLoans[msg.sender].borrowed;
        uint256 collateral = activeLoans[msg.sender].collateral;

        uint256 collateralInAvax = SNOWtoAVAXFloor(collateral); //Rounds down user amount (in favor of protocol)
        _burn(address(this), collateral);

        uint256 burnFee = (collateralInAvax * burnFeeBps) / BPS_DENOMINATOR;
        uint256 collateralInAvaxAfterFee = collateralInAvax - burnFee;

        require(collateralInAvaxAfterFee >= borrowed, "Not enough collateral to close position"); //This seems redundant, but fine to keep

        // Explanation of how it works:

        // Assume SNOW/AVAX = 1.10
        // I own 90.90 SNOW = 100 AVAX worth of SNOW
        // I max borrow against it for 1 year
        // Max borrow possible is 99 AVAX
        // Interest fee = 99 * 6.9% APR
        // Thus, borrow amount = 99 AVAX and avax received = 92.169 AVAX
        // Collateral = 100 AVAX (worth of) SNOW = 90.90 SNOW

        // Let's say SNOW/AVAX rises to 1.20, and now I want to close my position

        // Option 1: close the loan normally.
        // I flash borrow (elsewhere, assume for 0 cost) and pay back 99 AVAX
        // I receive 90.90 SNOW
        // I burn the SNOW for 90.90 * 1.20 = 109.08 AVAX - 2.69% burn fee
        // I receive 106.145 AVAX and pay back by flash borrow, I netted 106.145 - 99 AVAX = 7.145 AVAX

        // Option 2: I call flashBurn()
        // My entire SNOW collateral (90.90 SNOW) is burned
        // My collateral was worth 90.90 * 120 = 109.08 AVAX
        // The fee is 109.08 * burnFee = 109.08 * 2.69% = 2.93 AVAX
        // Remaining collateral in AVAX after fee = 109.08 - 2.934 = 106.145 AVAX
        // 106.145 AVAX must be worth more than the borrowed amount (99 AVAX) -> which it is
        // I get back collateral value - borrowed - fee = 106.145 AVAX - 99 AVAX = 7.145 AVAX
        // Note this is the exact same outcome as Option 1

        uint256 toUser = collateralInAvaxAfterFee - borrowed;
        uint256 treasuryFee = (burnFee * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;

        if (toUser > 0) {
            KHYPE.safeTransfer(msg.sender, toUser);
        }

        require(treasuryFee > DUST, "Fees must be higher than dust");
        KHYPE.safeTransfer(snowTreasury, treasuryFee);
        _subtractLoansOnDate(borrowed, collateral, activeLoans[msg.sender].endDate);

        delete activeLoans[msg.sender];
        _riseOnly(borrowed);
        emit FlashBurn(msg.sender, borrowed, collateral, toUser, burnFee);
    }

    /// @notice Extends the duration of an existing loan
    /// @param numberOfDays Additional days to extend the loan
    /// @return The fee paid for the extension
    /// @dev Requires an active non-expired loan and payment of extension fee
    function extendLoan(uint256 numberOfDays, uint256 loanAmount) public nonReentrant returns (uint256) {
        require(borrowingEnabled, "Borrowing is disabled");
        uint256 oldEndDate = activeLoans[msg.sender].endDate;
        uint256 borrowed = activeLoans[msg.sender].borrowed;
        uint256 collateral = activeLoans[msg.sender].collateral;
        uint256 _numberOfDays = activeLoans[msg.sender].numberOfDays;

        uint256 newEndDate = oldEndDate + (numberOfDays * 1 days);

        uint256 loanFee = getInterestFee(borrowed, numberOfDays);
        require(!isLoanExpired(msg.sender), "No active loans");
        require(loanFee == loanAmount, "Loan extension fee incorrect");
        KHYPE.safeTransferFrom(msg.sender, address(this), loanAmount);

        uint256 treasuryFee = (loanFee * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;
        require(treasuryFee > DUST, "Fees must be higher than dust");
        liquidate();
        KHYPE.safeTransfer(snowTreasury, treasuryFee);

        _subtractLoansOnDate(borrowed, collateral, oldEndDate);
        _addLoansOnDate(borrowed, collateral, newEndDate);
        activeLoans[msg.sender].endDate = newEndDate;
        activeLoans[msg.sender].numberOfDays = numberOfDays + _numberOfDays;
        require((newEndDate - block.timestamp) / 1 days < 366, "Loan must be under 365 days");

        _riseOnly(loanFee);
        emit LoanExtended(msg.sender, numberOfDays, collateral, borrowed, loanFee);
        return loanFee;
    }

    /// @notice Liquidates expired loans
    /// @dev Processes all expired loans up to the current timestamp
    /// @dev Burns collateral and updates total borrowed/collateral amounts
    /// @dev The Loan mapping is not updated for the users whose loan are liquidated
    function liquidate() public {
        uint256 borrowed;
        uint256 collateral;

        while (lastLiquidateDate < block.timestamp) {
            collateral = collateral + collateralByDate[lastLiquidateDate];
            borrowed = borrowed + loansByDate[lastLiquidateDate];
            lastLiquidateDate = lastLiquidateDate + 1 days;
        }

        if (collateral != 0) {
            totalCollateral = totalCollateral - collateral;
            _burn(address(this), collateral);
        }
        if (borrowed != 0) {
            totalLoans = totalLoans - borrowed;
            emit Liquidate(lastLiquidateDate - 1 days, borrowed);
        }
    }

    //***************************************************
    //  Internal functions

    /// @notice Mints SNOW tokens to a specified address
    /// @param to Address to receive the minted tokens
    /// @param value Amount of tokens to mint
    /// @dev Updates totalMinted, enforces max supply, and prevents minting to zero address
    function _freeze(address to, uint256 value) private {
        require(to != address(0), "Can't mint to 0 address");
        totalFreezed = totalFreezed + value;

        require(totalFreezed <= maxFreeze, "NO MORE SNOW");

        _mint(to, value);
    }

    /// @notice Adds loan data to the tracking by expiration date
    /// @param borrowed Amount borrowed in the loan
    /// @param collateral Amount of collateral in the loan
    /// @param date Expiration date of the loan
    /// @dev Updates global tracking variables and emits LoanDataUpdate event
    function _addLoansOnDate(uint256 borrowed, uint256 collateral, uint256 date) private {
        collateralByDate[date] = collateralByDate[date] + collateral;
        loansByDate[date] = loansByDate[date] + borrowed;
        totalLoans = totalLoans + borrowed;
        totalCollateral = totalCollateral + collateral;
        emit LoanDataUpdate(collateralByDate[date], loansByDate[date], totalLoans, totalCollateral);
    }

    /// @notice Subtracts loan data from the tracking by expiration date
    /// @param borrowed Amount borrowed to subtract
    /// @param collateral Amount of collateral to subtract
    /// @param date Expiration date of the loan
    /// @dev Updates global tracking variables and emits LoanDataUpdate event
    function _subtractLoansOnDate(uint256 borrowed, uint256 collateral, uint256 date) private {
        collateralByDate[date] = collateralByDate[date] - collateral;
        loansByDate[date] = loansByDate[date] - borrowed;
        totalLoans = totalLoans - borrowed;
        totalCollateral = totalCollateral - collateral;
        emit LoanDataUpdate(collateralByDate[date], loansByDate[date], totalLoans, totalCollateral);
    }

    /// @notice Performs safety checks after operations that affect the protocol's state
    /// @param avax Amount of AVAX involved in the operation
    /// @dev Ensures contract balance covers all collateral, price only increases, and emits Price event
    function _riseOnly(uint256 avax) private {
        uint256 newPrice = (getBacking() * 1 ether) / totalSupply();
        uint256 _totalCollateral = balanceOf(address(this));
        require(
            _totalCollateral >= totalCollateral,
            "The snow balance of the contract must be greater than or equal to the collateral"
        );
        require(prevPrice <= newPrice, "The price of snow cannot decrease");
        prevPrice = newPrice;
        emit PriceUpdated(block.timestamp, newPrice, avax);
    }

    /// @notice Sends AVAX to a specified address
    /// @param _address Recipient address
    /// @param _value Amount of AVAX to send
    /// @dev Emits SendAvax event on successful transfer
    function _sendAvax(address _address, uint256 _value) internal {
        require(_address != address(0), "Can't send to 0 address");
        _address.safeTransferETH(_value);
        emit SendAvax(_address, _value);
    }

    //***************************************************
    //  Utility functions

    /// @notice Calculates the start timestamp for a given date
    /// @param date Timestamp to convert
    /// @return Start timestamp of the current day
    function getDayStart(uint256 date) public pure returns (uint256) {
        uint256 dayBoundary = date - (date % 86400); // Subtracting the remainder when divided by the number of seconds in a day (86400)
        return dayBoundary + 1 days;
    }

    /// @notice Gets the total borrowed and collateral amounts expiring on a specific date
    /// @param date Date to check
    /// @return Borrowed amount and collateral amount expiring on the date
    function getLoansExpiringByDate(uint256 date) public view returns (uint256, uint256) {
        return (loansByDate[getDayStart(date)], collateralByDate[getDayStart(date)]);
    }

    /// @notice Gets loan details for a specific address
    /// @param _address Address to check
    /// @return Collateral amount, borrowed amount, and end date of the loan
    /// @dev Returns zeros if the loan has expired
    function getLoanByAddress(address _address) public view returns (uint256, uint256, uint256) {
        if (activeLoans[_address].endDate >= block.timestamp) {
            return (activeLoans[_address].collateral, activeLoans[_address].borrowed, activeLoans[_address].endDate);
        } else {
            return (0, 0, 0);
        }
    }

    /// @notice Calculates the leverage fee for a loan
    /// @param avax Amount of AVAX to borrow
    /// @param numberOfDays Duration of the loan in days
    function loopCalcs(uint256 avax, uint256 numberOfDays)
        public
        view
        returns (uint256 freezeFee, uint256 userBorrow, uint256 overCollateralizationAmount, uint256 interest)
    {
        freezeFee = (avax * leverageFeeBps) / BPS_DENOMINATOR;
        uint256 userAvax = avax - freezeFee;
        userBorrow = (userAvax * COLLATERAL_RATIO) / BPS_DENOMINATOR;
        overCollateralizationAmount = userAvax - userBorrow;
        interest = getInterestFee(userBorrow, numberOfDays);
    }

    /// @notice Calculates the interest fee for a loan
    /// @param borrowed Amount borrowed
    /// @param numberOfDays Duration of the loan in days
    /// @return Interest fee amount
    function getInterestFee(uint256 borrowed, uint256 numberOfDays) public view returns (uint256) {
        uint256 interestFee = (borrowed * INTEREST_APR_BPS * numberOfDays * 1e18) / 365 / BPS_DENOMINATOR / 1e18;
        uint256 overCollateralizationAmount = (borrowed * (BPS_DENOMINATOR - COLLATERAL_RATIO)) / COLLATERAL_RATIO;
        uint256 burnFee = ((borrowed + overCollateralizationAmount) * burnFeeBps) / BPS_DENOMINATOR;

        // Assume you have 100 AVAX worth of SNOW
        // Borrow 99 AVAX
        // If I sold my SNOW, I would get 100 AVAX - 2.69% burn fee = 97.31 AVAX
        // If I borrow AVAX against that same SNOW, I should receive no more than 97.31 AVAX
        // If I borrow 99 AVAX, that means there is 1 AVAX overCollateralizationAmount
        // Interest Fee should be at least (99 - 97.31) = 1.69 AVAX
        // Ensure that borrowing + letting yourself get liquidated isn't cheaper than burning
        if (burnFee <= overCollateralizationAmount) {
            return interestFee;
        } else if (interestFee >= burnFee - overCollateralizationAmount) {
            return interestFee;
        } else {
            return burnFee - overCollateralizationAmount;
        }
    }

    /// @notice Checks if a loan for a specific address has expired
    /// @param _address Address to check
    /// @return True if the loan has expired, false otherwise
    function isLoanExpired(address _address) public view returns (bool) {
        return activeLoans[_address].endDate < block.timestamp;
    }

    /// @notice Calculates the total backing value of the protocol
    /// @return Sum of contract balance and total borrowed amount
    function getBacking() public view returns (uint256) {
        return KHYPE.balanceOf(address(this)) + totalLoans;
    }

    /// @notice Converts SNOW tokens to AVAX
    /// @dev Round down user amount (in favor of protocol)
    /// @param value Amount of SNOW to convert
    /// @return Equivalent amount in AVAX
    function SNOWtoAVAXFloor(uint256 value) public view returns (uint256) {
        return Math.mulDiv(value, getBacking(), totalSupply(), Math.Rounding.Floor);
    }

    /// @notice Converts AVAX to SNOW tokens, To be used when Avax is already received from the user.
    /// @dev Rounds down user amount (in  favor of protocol).
    /// @param value Amount of AVAX to convert
    /// @return Equivalent amount in SNOW
    function AVAXtoSNOWFloor(uint256 value) public view returns (uint256) {
        return Math.mulDiv(value, totalSupply(), getBacking() - value, Math.Rounding.Floor);
    }

    /// @notice Converts AVAX to SNOW tokens with leverage fee consideration.
    /// @dev Rounds down user amount (in favor of protocol).
    /// @param value Amount of AVAX to convert
    /// @param totalAvaxRequired Net fee + overcollaterization amount received from the user
    /// @return Equivalent amount in SNOW
    function AVAXtoSNOWLev(uint256 value, uint256 totalAvaxRequired) public view returns (uint256) {
        uint256 backing = getBacking() - totalAvaxRequired;
        return Math.mulDiv(value, totalSupply(), backing, Math.Rounding.Floor);
    }

    /// @notice Converts AVAX to SNOW without receiving AVAX, Rounds up.
    /// @param value Amount of AVAX to convert
    /// @return Equivalent amount in SNOW (rounded up)
    function AVAXtoSNOWNoTradeCeil(uint256 value) public view returns (uint256) {
        uint256 backing = getBacking();
        return Math.mulDiv(value, totalSupply(), backing, Math.Rounding.Ceil);
    }

    /// @notice Converts AVAX to SNOW without receiving AVAX. Rounds down.
    /// @param value Amount of AVAX to convert
    /// @return Equivalent amount in SNOW
    function AVAXtoSNOWNoTradeFloor(uint256 value) public view returns (uint256) {
        uint256 backing = getBacking();
        return Math.mulDiv(value, totalSupply(), backing, Math.Rounding.Floor);
    }

    //***************************************************
    //  Frontend View functions

    /// @notice Calculates the maximum borrowable amount and borrow details
    /// @param _user Address of the user
    /// @param _numberOfDays Duration of the loan in days
    function getMaxBorrow(address _user, uint256 _numberOfDays)
        external
        view
        returns (uint256 userAvax, uint256 userBorrow, uint256 interestFee)
    {
        uint256 userSnowBalance = balanceOf(_user) + getFreeCollateral(_user);
        userAvax = SNOWtoAVAXFloor(userSnowBalance);
        userBorrow = (userAvax * COLLATERAL_RATIO) / BPS_DENOMINATOR;
        interestFee = getInterestFee(userBorrow, _numberOfDays);
    }

    /// @notice Return the free collateral for a user that can be withdrawn via removeCollateral()
    /// @param user The address of the user
    /// @return The amount of free collateral in SNOW
    function getFreeCollateral(address user) public view returns (uint256) {
        if (isLoanExpired(user)) {
            return 0;
        }
        uint256 userCollateral = activeLoans[user].collateral;
        uint256 userBorrowed = activeLoans[user].borrowed;

        // Note this is the same calculation as in increaseBorrow
        uint256 userBorrowedInSnow = AVAXtoSNOWNoTradeCeil(userBorrowed); //Rounds up borrow amount (in favor of protocol)
        return userCollateral - Math.mulDiv(userBorrowedInSnow, BPS_DENOMINATOR, COLLATERAL_RATIO, Math.Rounding.Ceil); //Rounds up (in favor of protocol)
    }

    /// @notice Calculates the amount of SNOW you get by buying with AVAX
    /// @param avaxAmount Amount of AVAX to spend
    /// @return Amount of SNOW user would receive
    function getAmountOutBuy(uint256 avaxAmount) external view returns (uint256) {
        uint256 snowAmount = AVAXtoSNOWNoTradeFloor(avaxAmount);
        return (snowAmount * (BPS_DENOMINATOR - freezeFeeBps)) / BPS_DENOMINATOR;
    }

    /// @notice Calculates the amount of AVAX you get by selling SNOW
    /// @param snowAmount Amount of SNOW to sell
    /// @return Amount of AVAX user would receive
    function getAmountOutSell(uint256 snowAmount) external view returns (uint256) {
        uint256 avaxAmount = SNOWtoAVAXFloor(snowAmount);
        return (avaxAmount * (BPS_DENOMINATOR - burnFeeBps)) / BPS_DENOMINATOR;
    }

    /// @notice Calculates the input Avax to call in loopCalcs given the totalAvaxRequired
    /// @param totalAvaxRequired = freezeFee + interest + overcollateralizationAmount
    /// @param numberOfDays Duration of the loan in days
    function inverseLoopCalc(uint256 totalAvaxRequired, uint256 numberOfDays) public view returns (uint256 avax) {
        uint256 low = totalAvaxRequired * 5; //initial guess (5x - 100x leverage, it should always be within these bounds)
        uint256 high = totalAvaxRequired * 100;
        uint256 mid;
        while (low < high) {
            mid = (low + high + 1) / 2; // Bias towards upper range to avoid infinite loops
            (uint256 freezeFee,, uint256 overCollateralizationAmount, uint256 interest) = loopCalcs(mid, numberOfDays);
            uint256 calculatedTotal = interest + overCollateralizationAmount + freezeFee;
            if (calculatedTotal < totalAvaxRequired) {
                low = mid; // Move upwards
            } else {
                high = mid - 1; // Move downwards
            }
        }
        return low;
    }

    //***************************************************
    /// @notice Fallback function to receive AVAX
    receive() external payable {}

    //***************************************************
    //  Events

    /// @notice Emitted when the price of SNOW changes
    /// @param time Timestamp of the price change
    /// @param price New price of SNOW in AVAX
    /// @param volumeInAvax Volume of the transaction in AVAX
    event PriceUpdated(uint256 time, uint256 price, uint256 volumeInAvax);

    /// @notice Emitted when a user freezes SNOW
    /// @param receiver Address of the buyer
    /// @param amount Amount of AVAX spent
    /// @param snow Amount of SNOW received
    event Freeze(address indexed receiver, uint256 amount, uint256 snow);

    /// @notice Emitted when a user burns SNOW
    /// @param seller Address of the seller
    /// @param avax Amount of AVAX received
    /// @param snow Amount of SNOW sold
    event Burn(address indexed seller, uint256 avax, uint256 snow);

    /// @notice Emitted when a user takes a leveraged position in SNOW
    /// @param user Address of the user
    /// @param avax Amount of AVAX used for leverage
    /// @param numberOfDays Duration of leverage in days
    /// @param userSnow Amount of SNOW held by the user before leverage
    /// @param userBorrow Total borrowed AVAX after leverage
    /// @param fee Fee charged for leverage
    event Loop(
        address indexed user, uint256 avax, uint256 numberOfDays, uint256 userSnow, uint256 userBorrow, uint256 fee
    );

    /// @notice Emitted when a user borrows AVAX against SNOW collateral
    /// @param user Address of the borrower
    /// @param avax Amount of AVAX borrowed
    /// @param numberOfDays Duration of the loan in days
    /// @param userSnow Amount of SNOW held as collateral
    /// @param newUserBorrow Total outstanding debt after borrowing
    /// @param fee Fee charged for borrowing
    event Borrow(
        address indexed user, uint256 avax, uint256 numberOfDays, uint256 userSnow, uint256 newUserBorrow, uint256 fee
    );

    /// @notice Emitted when a user removes collateral
    /// @param user Address of the user
    /// @param amount Amount of collateral removed
    event RemoveCollateral(address indexed user, uint256 amount);

    /// @notice Emitted when a user repays their loan
    /// @param user Address of the borrower
    /// @param amount Amount of AVAX repaid
    /// @param newBorrow Remaining outstanding debt after repayment
    event Repay(address indexed user, uint256 amount, uint256 newBorrow);

    /// @notice Emitted when a user closes a leveraged position using a flash loan
    /// @param user Address of the user
    /// @param borrowed Amount of AVAX borrowed via flash loan
    /// @param collateral Amount of SNOW collateral liquidated
    /// @param toUser Amount returned to the user after closing position
    /// @param fee Fee charged for using the flash loan
    event FlashBurn(address indexed user, uint256 borrowed, uint256 collateral, uint256 toUser, uint256 fee);

    /// @notice Emitted when a loan is extended
    /// @param user Address of the borrower
    /// @param numberOfDays Additional loan duration in days
    /// @param collateral Amount of SNOW held as collateral
    /// @param borrowed Amount of AVAX borrowed
    /// @param fee Fee charged for the extension
    event LoanExtended(address indexed user, uint256 numberOfDays, uint256 collateral, uint256 borrowed, uint256 fee);

    /// @notice Emitted when the max supply is updated
    /// @param max New maximum supply
    event MaxFreezeUpdated(uint256 max);

    /// @notice Emitted when freezer contract is updated
    /// @param freezer New freezer address
    event FreezerSet(address freezer);

    /// @notice Emitted when the sell fee is updated
    /// @param sellFee New sell fee
    event BurnFeeUpdated(uint256 sellFee);

    /// @notice Emitted when the fee address is updated
    /// @param _address New fee address
    event SnowTreasuryUpdated(address _address);

    /// @notice Emitted when the freeze fee is updated
    /// @param freezeFee New freeze fee
    event FreezeFeeUpdated(uint256 freezeFee);

    /// @notice Emitted when the leverage fee is updated
    /// @param leverageFee New leverage fee
    event LeverageFeeUpdated(uint256 leverageFee);

    /// @notice Emitted when trading is started
    /// @param started Whether trading has started
    event Started(bool started);

    /// @notice Triggered when borrowing is enabled
    /// @param enabled Whether borrowing is enabled
    event BorrowingEnabled(bool enabled);

    /// @notice Emitted when loans are liquidateed
    /// @param time Timestamp of liquidate
    /// @param amount Amount of AVAX liquidateed
    event Liquidate(uint256 indexed time, uint256 amount);

    /// @notice Emitted when loan data is updated
    /// @param collateralByDate Total collateral amount for a specific date
    /// @param borrowedByDate Total borrowed amount for a specific date
    /// @param totalBorrowed Total borrowed amount
    /// @param totalCollateral Total collateral amount
    event LoanDataUpdate(
        uint256 collateralByDate, uint256 borrowedByDate, uint256 totalBorrowed, uint256 totalCollateral
    );

    /// @notice Emitted when AVAX is sent
    /// @param to Recipient address
    /// @param amount Amount of AVAX sent
    event SendAvax(address to, uint256 amount);

    /// @notice Emitted when fees are collected
    /// @param sender Address of the sender
    /// @param bounty Amount of AVAX paid as bounty
    /// @param tokens List of ERC-20 tokens collected
    /// @param amounts Amounts of ERC-20 tokens collected
    event BountyCollected(address indexed sender, uint256 indexed bounty, address[] tokens, uint256[] amounts);

    /// @notice Emitted when the bribe bounty is updated
    /// @param amount New bribe bounty amount
    event BribeBountyUpdated(uint256 amount);

    /// @notice Emitted when the token locker fee is updated
    /// @param tokenLockerFee New token locker fee
    event TokenLockerFeeUpdated(uint256 tokenLockerFee);

    /// @notice Emitted when a token is locked
    /// @param sender Address of the user
    /// @param token Address of the token
    /// @param lockAmount Amount of tokens locked
    /// @param unlockTime Time when the tokens can be unlocked
    event TokenLocked(address indexed sender, address indexed token, uint256 lockAmount, uint256 unlockTime);

    /// @notice Emitted when a token is unlocked
    /// @param sender Address of the user
    /// @param token Address of the token
    /// @param amount Amount of tokens unlocked
    event TokenUnlocked(address indexed sender, address indexed token, uint256 amount);

    /// @notice Emitted when SNOW is staked for iSNOW
    /// @param sender Address of the user
    /// @param snowAmount Amount of SNOW to stake
    /// @param iSnowAmount Amount of iSnow received
    event Staked(address indexed sender, uint256 snowAmount, uint256 iSnowAmount);

    /// @notice Emitted when iSnow is requested to be unstaked
    /// @param user Address of the user
    /// @param iSnowAmount Amount of iSnow to unstake
    event UnstakeRequested(address indexed user, uint256 iSnowAmount);

    /// @notice Emitted when iSnow is unstaked for SNOW
    /// @param sender Address of the user
    /// @param snowAmount Amount of SNOW received
    /// @param iSnowAmount Amount of iSnow unstaked
    event Unstaked(address indexed sender, uint256 snowAmount, uint256 iSnowAmount);

    /// @notice Triggered when SNOW staking is enabled
    /// @param enabled Whether staking is enabled
    event StakingEnabled(bool enabled);

    /// @notice Triggered when SnowGT is enabled
    /// @param enabled Whether SnowGT is enabled
    event SnowGTEnabled(bool enabled);

    /// @notice Emitted when the POL fee is updated
    /// @param polFee New POL fee
    event PolFeeUpdated(uint256 polFee);

    /// @notice Emitted when SnowGT is minted
    /// @param user Address of the user
    /// @param amount Amount of SnowGT minted
    event SnowGTMinted(address indexed user, uint256 amount);
    //
    //    /// @notice Emitted when SnowGT is requested to be redeemed
    //    /// @param user Address of the user
    //    /// @param amount Amount of SnowGT redemption requested
    //    event SnowGTRequested(address indexed user, uint256 amount);
    //
    //    /// @notice Emitted when SnowGT is redeemed
    //    /// @param user Address of the user
    //    /// @param amount Amount of SnowGT redeemed
    //    event SnowGTFulfilled(address indexed user, uint256 amount, uint256 snowAmount);
}
