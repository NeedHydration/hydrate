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
import {IStakeHub} from "./interfaces/IStakeHub.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IQuoter} from "@v3-periphery/interfaces/IQuoter.sol";
import {ISwapRouter} from "@v3-periphery/interfaces/ISwapRouter.sol";

contract Hydrate is ERC20, Ownable, ReentrancyGuard, Multicallable {
    using SafeTransferLib for address;
    using SafeERC20 for IERC20;

    /// @notice Struct representing a user's loan
    /// @param collateral Amount of tokens staked as collateral
    /// @param borrowed Amount of kHYPE borrowed against the collateral
    /// @param endDate Timestamp when the loan expires
    /// @param numberOfDays Duration of the loan in days
    struct Loan {
        uint256 collateral;
        uint256 borrowed;
        uint256 endDate;
        uint256 numberOfDays;
        uint256 lastTimeCreated;
    }

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

    address payable public hydrateTreasury;
    // TODO: confirm these
    uint256 public hydrateFeeBps = 250;
    uint256 public burnFeeBps = 250;
    uint256 public leverageFeeBps = 142;
    address public hydrater;

    //Global state variables
    bool public started;
    uint256 public totalLoans;
    uint256 public totalCollateral;
    uint256 public maxHydrate;
    uint256 public totalHydrated;
    uint256 public prevPrice;

    //User state variables
    mapping(address => Loan) public activeLoans;

    //Global by date state variables
    mapping(uint256 => uint256) public loansByDate;
    mapping(uint256 => uint256) public collateralByDate;
    uint256 public lastLiquidateDate;

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
        hydrateTreasury = payable(_treasury);
        KHYPE = IERC20(_KHYPE);
        stakeHub = IStakeHub(_stakeHub);
        quoter = IQuoter(_quoter);
        swapRouter = ISwapRouter(_swapRouter);
    }

    function name() public pure override returns (string memory) {
        return "Hydrate";
    }

    function symbol() public pure override returns (string memory) {
        return "H2O";
    }


    // TODO: move me
    function _start(uint256 amount) internal {
        require(!started && maxHydrate == 0, "Trading already initialized");
        require(amount == 6900 ether, "Must send 6900 KHYPE to start trading");

        started = true;
        borrowingEnabled = true;

        uint256 masterHydraterHydrate = amount; // sets initial price to 1 KHYPE
        maxHydrate = masterHydraterHydrate;

        _hydrate(msg.sender, masterHydraterHydrate);

        emit MaxHydrateUpdated(masterHydraterHydrate);
        emit Started(true);
    }

    function setStartKHYPE(uint256 amount) public payable onlyOwner {
        _start(amount);
        KHYPE.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Starts freezing and burning for the H2O token
    /// @dev Requires that fee address is set and must send 6900 KHYPE 
    /// @dev Requires that the maxSupply is 0 and trading hasn't already started
    /// Mints initial H2O to the owner and burns 0.1 H2O
    function setStart() public payable onlyOwner {
        _start(msg.value);
        stakeHub.stake{value: msg.value}();
    }

    /// @notice Sets the hydrater address
    /// @param _hydrater The address of the hydrater contract
    /// @dev The hydrater contract can mint and increase total supply atomically
    function setHydrater(address _hydrater) external onlyOwner {
        hydrater = _hydrater;
        emit HydraterSet(_hydrater);
    }

    /// @notice Increase the maxHydrate
    /// @param _maxHydrate The new maximum supply of H2O 
    /// @dev Requires its increasing and higher than total hydrated
    function increaseMaxSupply(uint256 _maxHydrate) external onlyOwner {
        require(_maxHydrate > totalHydrated, "Max supply must be greater than total hydrated");
        require(_maxHydrate > maxHydrate, "Increase only");
        maxHydrate = _maxHydrate;
        emit MaxHydrateUpdated(_maxHydrate);
    }

    /// @notice Sets the fee recipient address
    /// @param _address The new fee address
    /// @dev Cannot be the zero address
    function setHydrateTreasury(address _address) external onlyOwner {
        require(_address != address(0), "Can't set treasury address to 0 address");
        hydrateTreasury = payable(_address);
        emit HydrateTreasuryUpdated(_address);
    }

    /// @notice Sets the hydrate fee
    /// @param amount The new hydrate fee
    /// @dev Fee is in basis points, must be between 1-5%
    function setHydrateFee(uint256 amount) external onlyOwner {
        require(amount >= 100, "hydrate fee must be greater than 1%");
        require(amount <= 500, "hydrate fee must be less than 5%");
        require(amount >= leverageFeeBps, "hydrate fee must be greater than leverage fee");
        hydrateFeeBps = amount;
        emit HydrateFeeUpdated(amount);
    }

    /// @notice Sets the leverage fee
    /// @param amount The new leverage fee
    /// @dev Fee is in basis points, must be between 0.5% and 2.5%
    function setLeverageFee(uint256 amount) external onlyOwner {
        require(amount >= 50, "leverage fee must be greater than 0.5%");
        require(amount <= 250, "leverage fee must be less than 2.5%");
        require(amount <= hydrateFeeBps, "leverage fee must be less than hydrate fee");
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

    /// @notice Recover ERC20 tokens from the contract after H2O is hydrated
    /// @param _token Address of the token to recover
    /// @dev Unruggable because it can only recover erc20s that are not H2O (mistakenly donated or farmed tokens)
    function recoverERC20(address _token) external onlyOwner {
        require(_token != address(this), "Hydrate: can only recover erc20s that are not ");
        _token.safeTransfer(msg.sender, _token.balanceOf(address(this)));
    }

    //***************************************************
    //  External functions

    function hydrateKHYPE(address receiver, uint256 amount) external nonReentrant {
        KHYPE.transferFrom(msg.sender, address(this), amount);
        _hydrateH2O(receiver, amount);
    }

    /// @notice Buys H2O tokens with HYPE
    /// @param receiver The address to receive the H2O tokens
    /// @dev Requires trading to be started
    /// Mints H2O to the receiver based on the current price
    function hydrate(address receiver) external payable nonReentrant {
        uint256 amount = msg.value;
        stakeHub.stake{value: amount}();
        _hydrateH2O(receiver, amount);
    }

    function _hydrateH2O(address receiver, uint256 amount) internal {
        liquidate();
        require(started, "Trading must be initialized");

        require(receiver != address(0), "Receiver cannot be 0 address");

        // Calculate amount of H2O to recieve
        uint256 H2O = KHYPEtoH2OFloor(amount);
        uint256 H2OToHydrate = (H2O * (BPS_DENOMINATOR - hydrateFeeBps)) / BPS_DENOMINATOR;

        if (msg.sender == hydrater) {
            // check if we need to increase max supply
            if (totalHydrated + H2OToHydrate > maxHydrate) {
                uint256 _maxHydrate = maxHydrate + H2OToHydrate;
                maxHydrate = _maxHydrate;
                emit MaxHydrateUpdated(_maxHydrate);
            }
        }

        // Mint H2O to receiver
        _hydrate(receiver, H2OToHydrate);

        // Calculate Treasury Fee and deduct
        uint256 treasuryAmount = (amount * hydrateFeeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "must trade over min");
        KHYPE.safeTransfer(hydrateTreasury, treasuryAmount);

        _riseOnly(amount);
        emit Hydrated(receiver, amount, H2OToHydrate);
    }

    /// @notice Sells H2O tokens for KHYPE
    /// @param h2o The amount of H2O to sell
    /// @dev Burns H2O and sends KHYPE to the sender based on the current price
    function burn(uint256 h2o) external nonReentrant {
        liquidate();

        // Total KHYPE to be sent
        uint256 khype = H2OtoKHYPEFloor(h2o); //Rounds down user amount (in favor of protocol)

        // Burn 
        _burn(msg.sender, h2o);

        // Payment to sender
        uint256 khypeToPay = (khype * (BPS_DENOMINATOR - burnFeeBps)) / BPS_DENOMINATOR;
        KHYPE.safeTransfer(msg.sender, khypeToPay);

        // Treasury fee
        uint256 treasuryAmount = (khype * burnFeeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "must trade over min");
        KHYPE.safeTransfer(hydrateTreasury, treasuryAmount);

        _riseOnly(khype);
        emit Burn(msg.sender, khypeToPay, h2o);
    }

    // TODO: natspec
    function burnHype(uint256 h2o) external nonReentrant {
        liquidate();

        // Total Hype to be sent
        uint256 hype = H2OtoKHYPEFloor(h2o);

        // Burn H2O
        _burn(msg.sender, h2o);

        // Handle fees before swapping
        // Treasury fee
        uint256 treasuryAmount = (hype * burnFeeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "must trade over min");
        KHYPE.safeTransfer(hydrateTreasury, treasuryAmount);

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
        emit Burn(msg.sender, hypeToSwap, h2o);
    }

    /// @notice Creates a leveraged position
    /// @param khype The amount of khype to loop
    /// @param numberOfDays The duration of the loan in days
    /// @dev Requires trading to be started
    ///     Creates a loan with collateral and borrowed amount
    function loop(uint256 khype, uint256 numberOfDays) public nonReentrant {
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

        (uint256 hydrateFee, uint256 userBorrow, uint256 overCollateralizationAmount, uint256 interestFee) =
            loopCalcs(khype, numberOfDays);

        uint256 totalKHYPERequired = overCollateralizationAmount + hydrateFee + interestFee;
        KHYPE.safeTransferFrom(msg.sender, address(this), totalKHYPERequired);

        uint256 userKHYPE = khype - hydrateFee;
        uint256 userH2O = KHYPEtoH2OLev(userKHYPE, totalKHYPERequired);
        _hydrate(address(this), userH2O);

        uint256 treasuryAmount = ((hydrateFee + interestFee) * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;
        require(treasuryAmount > DUST, "Fees must be higher than dust");
        KHYPE.safeTransfer(hydrateTreasury, treasuryAmount);

        _addLoansOnDate(userBorrow, userH2O, endDate);
        activeLoans[msg.sender] = Loan({
            collateral: userH2O,
            borrowed: userBorrow,
            endDate: endDate,
            numberOfDays: numberOfDays,
            lastTimeCreated: block.timestamp
        });

        _riseOnly(khype);
        emit Loop(msg.sender, khype, numberOfDays, userKHYPE, userBorrow, totalKHYPERequired);
    }

    /// @notice Creates a loan by borrowing KHYPE against H2O collateral
    /// @param khype The amount of KHYPE to borrow
    /// @param numberOfDays The duration of the loan in days
    /// @dev Requires no existing loan
    /// @dev Use increaseBorrow with existing loan
    function borrow(uint256 khype, uint256 numberOfDays) public nonReentrant {
        require(borrowingEnabled, "Borrowing is disabled");
        require(numberOfDays <= 365, "Max borrow/extension must be 365 days or less");
        require(khype != 0, "Must borrow more than 0");
        if (isLoanExpired(msg.sender)) {
            delete activeLoans[msg.sender];
        }
        require(activeLoans[msg.sender].borrowed == 0, "Use increaseBorrow to borrow more");

        liquidate();
        uint256 endDate = getDayStart((numberOfDays * 1 days) + block.timestamp);

        uint256 newUserBorrow = (khype * COLLATERAL_RATIO) / BPS_DENOMINATOR;

        uint256 khypeFee = getInterestFee(newUserBorrow, numberOfDays);

        uint256 treasuryFee = (khypeFee * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;

        uint256 userH2O = KHYPEtoH2OLev(khype, khypeFee); //Rounds up borrow amount (in favor of protocol)

        activeLoans[msg.sender] = Loan({
            collateral: userH2O,
            borrowed: newUserBorrow,
            endDate: endDate,
            numberOfDays: numberOfDays,
            lastTimeCreated: block.timestamp
        });

        _transfer(msg.sender, address(this), userH2O);
        require(treasuryFee > DUST, "Fees must be higher than dust");

        KHYPE.safeTransfer(msg.sender, newUserBorrow - khypeFee);
        KHYPE.safeTransfer(hydrateTreasury, treasuryFee);

        _addLoansOnDate(newUserBorrow, userH2O, endDate);

        _riseOnly(khype);
        emit Borrow(msg.sender, khype, numberOfDays, userH2O, newUserBorrow, khypeFee);
    }

    /// @notice Increases an existing loan by borrowing more KHYPE 
    /// @param khype The additional amount of KHYPE to borrow
    /// @dev Requires an active non-expired loan
    function increaseBorrow(uint256 khype) public nonReentrant {
        require(borrowingEnabled, "Borrowing is disabled");
        require(!isLoanExpired(msg.sender), "Loan expired use borrow");
        require(khype != 0, "Must borrow more than 0");
        liquidate();
        uint256 userBorrowed = activeLoans[msg.sender].borrowed;
        uint256 userCollateral = activeLoans[msg.sender].collateral;
        uint256 userEndDate = activeLoans[msg.sender].endDate;

        uint256 todayMidnight = getDayStart(block.timestamp);
        uint256 newBorrowLength = (userEndDate - todayMidnight) / 1 days;

        uint256 newUserBorrow = (khype * COLLATERAL_RATIO) / BPS_DENOMINATOR;
        uint256 khypeFee = getInterestFee(newUserBorrow, newBorrowLength);

        uint256 userBorrowedInH2O = KHYPEtoH2ONoTradeCeil(userBorrowed); //Rounds up borrow amount (in favor of protocol)
        uint256 userExcessInH2O =
            userCollateral - Math.mulDiv(userBorrowedInH2O, BPS_DENOMINATOR, COLLATERAL_RATIO, Math.Rounding.Ceil); //Rounds up (in favor of protocol)

        uint256 userH2O = KHYPEtoH2ONoTradeCeil(khype); //Rounds up borrow amount (in favor of protocol)
        uint256 requireCollateralFromUser = userExcessInH2O >= userH2O ? 0 : userH2O - userExcessInH2O;

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
            uint256 treasuryFee = (khypeFee * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;
            require(treasuryFee > DUST, "Fees must be higher than dust");
            KHYPE.safeTransfer(hydrateTreasury, treasuryFee);
        }

        KHYPE.safeTransfer(msg.sender, newUserBorrow - khypeFee);
        _addLoansOnDate(newUserBorrow, requireCollateralFromUser, userEndDate);

        _riseOnly(khype);
        emit Borrow(msg.sender, khype, newBorrowLength, userH2O, newUserBorrow, khypeFee);
    }

    /// @notice Removes collateral from an active loan
    /// @param amount The amount of H2O collateral to remove
    /// @dev Requires an active non-expired loan and maintains collateralization ratio
    function removeCollateral(uint256 amount) public nonReentrant {
        require(!isLoanExpired(msg.sender), "No active loans");
        liquidate();
        uint256 collateral = activeLoans[msg.sender].collateral;
        uint256 remainingCollateralInKHYPE = H2OtoKHYPEFloor(collateral - amount); //Rounds down user amount (in favor of protocol)

        require(
            activeLoans[msg.sender].borrowed <= (remainingCollateralInKHYPE * COLLATERAL_RATIO) / BPS_DENOMINATOR,
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

    /// @notice Allows users to close their loan positions by using their H2O collateral directly
    /// @dev Requires an active non-expired loan with sufficient collateral value
    function flashBurn() public nonReentrant {
        require(!isLoanExpired(msg.sender), "No active loan");
        liquidate();
        uint256 borrowed = activeLoans[msg.sender].borrowed;
        uint256 collateral = activeLoans[msg.sender].collateral;

        uint256 collateralInKHYPE = H2OtoKHYPEFloor(collateral); //Rounds down user amount (in favor of protocol)
        _burn(address(this), collateral);

        uint256 burnFee = (collateralInKHYPE * burnFeeBps) / BPS_DENOMINATOR;
        uint256 collateralInKHYPEAfterFee = collateralInKHYPE - burnFee;

        require(collateralInKHYPEAfterFee >= borrowed, "Not enough collateral to close position"); //This seems redundant, but fine to keep

        uint256 toUser = collateralInKHYPEAfterFee - borrowed;
        uint256 treasuryFee = (burnFee * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOMINATOR;

        if (toUser > 0) {
            KHYPE.safeTransfer(msg.sender, toUser);
        }

        require(treasuryFee > DUST, "Fees must be higher than dust");
        KHYPE.safeTransfer(hydrateTreasury, treasuryFee);
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
        KHYPE.safeTransfer(hydrateTreasury, treasuryFee);

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

    /// @notice Mints H2O tokens to a specified address
    /// @param to Address to receive the minted tokens
    /// @param value Amount of tokens to mint
    /// @dev Updates totalMinted, enforces max supply, and prevents minting to zero address
    function _hydrate(address to, uint256 value) private {
        require(to != address(0), "Can't mint to 0 address");
        totalHydrated = totalHydrated + value;

        require(totalHydrated <= maxHydrate, "NO MORE H2O");

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
    /// @param khype Amount of KHYPE involved in the operation
    /// @dev Ensures contract balance covers all collateral, price only increases, and emits Price event
    function _riseOnly(uint256 khype) private {
        uint256 newPrice = (getBacking() * 1 ether) / totalSupply();
        uint256 _totalCollateral = balanceOf(address(this));
        require(
            _totalCollateral >= totalCollateral,
            "The H2O balance of the contract must be greater than or equal to the collateral"
        );
        require(prevPrice <= newPrice, "The price of H2O cannot decrease");
        prevPrice = newPrice;
        emit PriceUpdated(block.timestamp, newPrice, khype);
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
    /// @param khype Amount of KHYPE to borrow
    /// @param numberOfDays Duration of the loan in days
    function loopCalcs(uint256 khype, uint256 numberOfDays)
        public
        view
        returns (uint256 hydrateFee, uint256 userBorrow, uint256 overCollateralizationAmount, uint256 interest)
    {
        hydrateFee = (khype * leverageFeeBps) / BPS_DENOMINATOR;
        uint256 userKHYPE = khype - hydrateFee;
        userBorrow = (userKHYPE * COLLATERAL_RATIO) / BPS_DENOMINATOR;
        overCollateralizationAmount = userKHYPE - userBorrow;
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

    /// @notice Converts H2O tokens to KHYPE
    /// @dev Round down user amount (in favor of protocol)
    /// @param value Amount of H2O to convert
    /// @return Equivalent amount in KHYPE 
    function H2OtoKHYPEFloor(uint256 value) public view returns (uint256) {
        return Math.mulDiv(value, getBacking(), totalSupply(), Math.Rounding.Floor);
    }

    /// @notice Converts KHYPE to H2O tokens, To be used when KHYPE is already received from the user.
    /// @dev Rounds down user amount (in  favor of protocol).
    /// @param value Amount of KHYPE to convert
    /// @return Equivalent amount in H2O
    function KHYPEtoH2OFloor(uint256 value) public view returns (uint256) {
        return Math.mulDiv(value, totalSupply(), getBacking() - value, Math.Rounding.Floor);
    }

    /// @notice Converts KHYPE to H2O tokens with leverage fee consideration.
    /// @dev Rounds down user amount (in favor of protocol).
    /// @param value Amount of KHYPE to convert
    /// @param totalKHYPERequired Net fee + overcollaterization amount received from the user
    /// @return Equivalent amount in H2O
    function KHYPEtoH2OLev(uint256 value, uint256 totalKHYPERequired) public view returns (uint256) {
        uint256 backing = getBacking() - totalKHYPERequired;
        return Math.mulDiv(value, totalSupply(), backing, Math.Rounding.Floor);
    }

    /// @notice Converts KHYPE to H2O tokens without receiving KHYPE, Rounds up.
    /// @param value Amount of KHYPE to convert
    /// @return Equivalent amount in H2O (rounded up)
    function KHYPEtoH2ONoTradeCeil(uint256 value) public view returns (uint256) {
        uint256 backing = getBacking();
        return Math.mulDiv(value, totalSupply(), backing, Math.Rounding.Ceil);
    }

    /// @notice Converts KHYPE to H2O tokens without receiving KHYPE. Rounds down.
    /// @param value Amount of KHYPE to convert
    /// @return Equivalent amount in H2O
    function KHYPEtoH2ONoTradeFloor(uint256 value) public view returns (uint256) {
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
        returns (uint256 userKHYPE, uint256 userBorrow, uint256 interestFee)
    {
        uint256 userH2OBalance = balanceOf(_user) + getFreeCollateral(_user);
        userKHYPE = H2OtoKHYPEFloor(userH2OBalance);
        userBorrow = (userKHYPE * COLLATERAL_RATIO) / BPS_DENOMINATOR;
        interestFee = getInterestFee(userBorrow, _numberOfDays);
    }

    /// @notice Return the free collateral for a user that can be withdrawn via removeCollateral()
    /// @param user The address of the user
    /// @return The amount of free collateral in H2O 
    function getFreeCollateral(address user) public view returns (uint256) {
        if (isLoanExpired(user)) {
            return 0;
        }           
        uint256 userCollateral = activeLoans[user].collateral;
        uint256 userBorrowed = activeLoans[user].borrowed;

        // Note this is the same calculation as in increaseBorrow
        uint256 userBorrowedInH2O = KHYPEtoH2ONoTradeCeil(userBorrowed); //Rounds up borrow amount (in favor of protocol)
        return userCollateral - Math.mulDiv(userBorrowedInH2O, BPS_DENOMINATOR, COLLATERAL_RATIO, Math.Rounding.Ceil); //Rounds up (in favor of protocol)
    }

    /// @notice Calculates the amount of H2O you get by buying with KHYPE 
    /// @param khypeAmount Amount of KHYPE to spend
    /// @return Amount of H2O user would receive
    function getAmountOutBuy(uint256 khypeAmount) external view returns (uint256) {
        uint256 h2oAmount = KHYPEtoH2ONoTradeFloor(khypeAmount);
        return (h2oAmount * (BPS_DENOMINATOR - hydrateFeeBps)) / BPS_DENOMINATOR;
    }

    /// @notice Calculates the amount of KHYPE you get by selling H2O
    /// @param h2oAmount Amount of H2O to sell
    /// @return Amount of KHYPE user would receive
    function getAmountOutSell(uint256 h2oAmount) external view returns (uint256) {
        uint256 khypeAmount = H2OtoKHYPEFloor(h2oAmount);
        return (khypeAmount * (BPS_DENOMINATOR - burnFeeBps)) / BPS_DENOMINATOR;
    }

    /// @notice Calculates the input KHYPE to call in loopCalcs given the totalKHYPERequired 
    /// @param totalKHYPERequired = hydrateFee + interest + overcollateralizationAmount
    /// @param numberOfDays Duration of the loan in days
    function inverseLoopCalc(uint256 totalKHYPERequired, uint256 numberOfDays) public view returns (uint256 khype) {
        uint256 low = totalKHYPERequired * 5; //initial guess (5x - 100x leverage, it should always be within these bounds)
        uint256 high = totalKHYPERequired * 100;
        uint256 mid;
        while (low < high) {
            mid = (low + high + 1) / 2; // Bias towards upper range to avoid infinite loops
            (uint256 hydrateFee,, uint256 overCollateralizationAmount, uint256 interest) = loopCalcs(mid, numberOfDays);
            uint256 calculatedTotal = interest + overCollateralizationAmount + hydrateFee;
            if (calculatedTotal < totalKHYPERequired) {
                low = mid; // Move upwards
            } else {
                high = mid - 1; // Move downwards
            }
        }
        return low;
    }

    //***************************************************
    /// @notice Fallback function to receive KHYPE
    receive() external payable {}

    //***************************************************
    //  Events

    /// @notice Emitted when the price of H2O changes
    /// @param time Timestamp of the price change
    /// @param price New price of H2O in KHYPE
    /// @param volumeInKHYPE Volume of the transaction in KHYPE
    event PriceUpdated(uint256 time, uint256 price, uint256 volumeInKHYPE);

    /// @notice Emitted when a user hydrates H2O
    /// @param receiver Address of the buyer
    /// @param amount Amount of KHYPE spent
    /// @param h2o Amount of H2O received
    event Hydrated(address indexed receiver, uint256 amount, uint256 h2o);

    /// @notice Emitted when a user burns H2O
    /// @param seller Address of the seller
    /// @param avax Amount of KHYPE received
    /// @param h2o Amount of H2O sold
    event Burn(address indexed seller, uint256 avax, uint256 h2o);

    /// @notice Emitted when a user takes a leveraged position in H2O
    /// @param user Address of the user
    /// @param avax Amount of KHYPE used for leverage
    /// @param numberOfDays Duration of leverage in days
    /// @param userH2O Amount of H2O held by the user before leverage
    /// @param userBorrow Total borrowed KHYPE after leverage
    /// @param fee Fee charged for leverage
    event Loop(
        address indexed user, uint256 avax, uint256 numberOfDays, uint256 userH2O, uint256 userBorrow, uint256 fee
    );

    /// @notice Emitted when a user borrows KHYPE against H2O collateral
    /// @param user Address of the borrower
    /// @param avax Amount of KHYPE borrowed
    /// @param numberOfDays Duration of the loan in days
    /// @param userH2O Amount of H2O held as collateral
    /// @param newUserBorrow Total outstanding debt after borrowing
    /// @param fee Fee charged for borrowing
    event Borrow(
        address indexed user, uint256 avax, uint256 numberOfDays, uint256 userH2O, uint256 newUserBorrow, uint256 fee
    );

    /// @notice Emitted when a user removes collateral
    /// @param user Address of the user
    /// @param amount Amount of collateral removed
    event RemoveCollateral(address indexed user, uint256 amount);

    /// @notice Emitted when a user repays their loan
    /// @param user Address of the borrower
    /// @param amount Amount of KHYPE repaid
    /// @param newBorrow Remaining outstanding debt after repayment
    event Repay(address indexed user, uint256 amount, uint256 newBorrow);

    /// @notice Emitted when a user closes a leveraged position using a flash loan
    /// @param user Address of the user
    /// @param borrowed Amount of KHYPE borrowed via flash loan
    /// @param collateral Amount of H2O collateral liquidated
    /// @param toUser Amount returned to the user after closing position
    /// @param fee Fee charged for using the flash loan
    event FlashBurn(address indexed user, uint256 borrowed, uint256 collateral, uint256 toUser, uint256 fee);

    /// @notice Emitted when a loan is extended
    /// @param user Address of the borrower
    /// @param numberOfDays Additional loan duration in days
    /// @param collateral Amount of H2O held as collateral
    /// @param borrowed Amount of KHYPE borrowed
    /// @param fee Fee charged for the extension
    event LoanExtended(address indexed user, uint256 numberOfDays, uint256 collateral, uint256 borrowed, uint256 fee);

    /// @notice Emitted when the max supply is updated
    /// @param max New maximum supply
    event MaxHydrateUpdated(uint256 max);

    /// @notice Emitted when hydrater contract is updated
    /// @param hydrater New hydrater address
    event HydraterSet(address hydrater);

    /// @notice Emitted when the sell fee is updated
    /// @param sellFee New sell fee
    event BurnFeeUpdated(uint256 sellFee);

    /// @notice Emitted when the fee address is updated
    /// @param _address New fee address
    event HydrateTreasuryUpdated(address _address);

    /// @notice Emitted when the hydrate fee is updated
    /// @param hydrateFee New hydrate fee
    event HydrateFeeUpdated(uint256 hydrateFee);

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
    /// @param amount Amount of KHYPE liquidateed
    event Liquidate(uint256 indexed time, uint256 amount);

    /// @notice Emitted when loan data is updated
    /// @param collateralByDate Total collateral amount for a specific date
    /// @param borrowedByDate Total borrowed amount for a specific date
    /// @param totalBorrowed Total borrowed amount
    /// @param totalCollateral Total collateral amount
    event LoanDataUpdate(
        uint256 collateralByDate, uint256 borrowedByDate, uint256 totalBorrowed, uint256 totalCollateral
    );

    /// @notice Emitted when KHYPE is sent
    /// @param to Recipient address
    /// @param amount Amount of KHYPE sent
    event SendAvax(address to, uint256 amount);

    /// @notice Emitted when fees are collected
    /// @param sender Address of the sender
    /// @param bounty Amount of KHYPE paid as bounty
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


}
