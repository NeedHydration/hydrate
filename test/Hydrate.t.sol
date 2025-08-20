// SPDX License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Snow} from "../src/Hydrate.sol";
import {Vm} from "forge-std/Vm.sol";
import {Snow} from "../src/Hydrate.sol";
import {MockStakeHub} from "./mocks/MockStakeHub.sol";
import "./mocks/MockKHYPE.sol";
import {IStakeHub} from "../src/interfaces/IStakeHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/console.sol";
import {IQuoter} from "@v3-periphery/interfaces/IQuoter.sol";
import {ISwapRouter} from "@v3-periphery/interfaces/ISwapRouter.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockQuoter} from "./mocks/MockQuoter.sol";

contract HydrateTest is Test {
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address minter = makeAddr("minter");
    address borrower = makeAddr("borrower");

    Snow hydrate;
    IStakeHub stakeHub;
    IERC20 KHYPE;
    IMockKHYPE WHYPE;
    IQuoter quoter;
    ISwapRouter swapRouter;

    function _setup() internal {
        vm.deal(admin, 1000 ether);
        vm.deal(minter, 1000 ether);

        WHYPE = new MockKHYPE();
        quoter = new MockQuoter();
        swapRouter = new MockSwapRouter(address(WHYPE));
        hydrate = new Snow(admin, treasury, address(KHYPE), address(stakeHub), address(quoter), address(swapRouter));

        vm.startBroadcast(admin);

        IMockKHYPE(address(KHYPE)).mint(admin, 6900 ether);
        IMockKHYPE(address(KHYPE)).mint(minter, 10000 ether);
        IMockKHYPE(address(KHYPE)).mint(borrower, 10000 ether);

        KHYPE.approve(address(hydrate), type(uint256).max);

        // // Enable minting and burning
        // hydrate.{value: 6900 ether}();
        hydrate.setStartKHYPE(6900 ether);

        // // Increase Total supply
        // // TODO: what should the total supply at deployment be?
        uint256 newTotalSupply = hydrate.totalFreezed() * 2;
        hydrate.increaseMaxSupply(newTotalSupply);

        vm.stopBroadcast();
    }

    function test_setStartHype() public {
        address adminTwo = makeAddr("admin");
        address treasuryTwo = makeAddr("treasury");
        vm.deal(adminTwo, 6900 ether);

        IMockKHYPE WHYPETwo = new MockKHYPE();
        IQuoter quoterTwo = new MockQuoter();
        ISwapRouter swapRouterTwo = new MockSwapRouter(address(WHYPETwo));
        IERC20 KHYPETwo = new MockKHYPE();
        IStakeHub stakeHubTwo = new MockStakeHub(address(KHYPETwo));
        Snow hydrateTwo = new Snow(
            adminTwo,
            treasuryTwo,
            address(KHYPETwo),
            address(stakeHubTwo),
            address(quoterTwo),
            address(swapRouterTwo)
        );

        vm.startBroadcast(adminTwo);
        KHYPETwo.approve(address(hydrateTwo), type(uint256).max);
        hydrateTwo.setStart{value: 6900 ether}();

        assertEq(KHYPETwo.balanceOf(address(hydrateTwo)), 6900 ether);
        assertEq(hydrateTwo.balanceOf(adminTwo), 6900 ether);
        assertEq(hydrateTwo.totalFreezed(), 6900 ether);
        assertEq(hydrateTwo.started(), true);
        assertEq(hydrateTwo.borrowingEnabled(), true);
        assertEq(hydrateTwo.maxFreeze(), 6900 ether);
        assertEq(hydrateTwo.totalFreezed(), 6900 ether);

        vm.stopBroadcast();
    }

    function test_mintAndBurn_HYPE() public {
        _setup();

        vm.startBroadcast(minter);
        uint256 preBal = KHYPE.balanceOf(address(hydrate));
        uint256 msgValue = 100 ether;

        // ===== Mint =====
        hydrate.freeze{value: msgValue}(minter);

        // 97.5% of mint goes to minter
        assertEq(97.5 ether, hydrate.balanceOf(minter));

        // (100 * 0.025 * 0.35)
        uint256 expectedTreasury = 0.875 ether;

        // Check backing
        assertEq(preBal + (msgValue - expectedTreasury), KHYPE.balanceOf(address(hydrate)));

        // Check treasury
        assertEq(expectedTreasury, KHYPE.balanceOf(treasury));

        // ===== Burn =====

        preBal = KHYPE.balanceOf(treasury);
        uint256 preBalMinter = KHYPE.balanceOf(minter);
        uint256 preBalHydrate = KHYPE.balanceOf(address(hydrate));
        msgValue = 10 ether;

        hydrate.burn(msgValue);

        // Minter redeems 97.5%
        // Use Gt then due to rounding errors in arithmetic
        assertGt(msgValue, (KHYPE.balanceOf(minter) - preBalMinter));

        // Treasury balance (gets 35% of 2.5% of 10)
        assertLt(preBal, KHYPE.balanceOf(treasury));

        // Backing should increase
        // Assert that the balance after is > burn with no fees
        assertGt(KHYPE.balanceOf(address(hydrate)), preBalHydrate - msgValue);

        vm.stopBroadcast();
    }

    function test_mintAndBurn_KHYPE() public {
        _setup();

        vm.startBroadcast(minter);

        KHYPE.approve(address(hydrate), type(uint256).max);

        uint256 preBal = KHYPE.balanceOf(address(hydrate));
        uint256 msgValue = 100 ether;

        // ===== Mint =====
        hydrate.freezeKHYPE(minter, msgValue);

        // 97.5% of mint goes to minter
        assertEq(97.5 ether, hydrate.balanceOf(minter));

        // (100 * 0.025 * 0.35)
        uint256 expectedTreasury = 0.875 ether;

        // Check backing
        assertEq(preBal + (msgValue - expectedTreasury), KHYPE.balanceOf(address(hydrate)));

        // Check treasury
        assertEq(expectedTreasury, KHYPE.balanceOf(treasury));

        // ===== Burn =====

        preBal = KHYPE.balanceOf(treasury);
        uint256 preBalMinter = KHYPE.balanceOf(minter);
        uint256 preBalHydrate = KHYPE.balanceOf(address(hydrate));
        msgValue = 10 ether;

        hydrate.burn(msgValue);

        // Minter redeems 97.5%
        // Use Gt then due to rounding errors in arithmetic
        assertGt(msgValue, (KHYPE.balanceOf(minter) - preBalMinter));

        // Treasury balance (gets 35% of 2.5% of 10)
        assertGt(KHYPE.balanceOf(treasury), preBal);

        // Backing should increase
        // Assert that the balance after is > burn with no fees
        assertGt(KHYPE.balanceOf(address(hydrate)), preBalHydrate - msgValue);

        vm.stopBroadcast();
    }

    function test_burnHype() public {
        _setup();

        vm.startBroadcast(minter);

        KHYPE.approve(address(hydrate), type(uint256).max);
        hydrate.freezeKHYPE(minter, 100 ether);

        uint256 preBalMinter = IERC20(address(WHYPE)).balanceOf(minter);
        uint256 preBalTreasury = KHYPE.balanceOf(treasury);
        uint256 preBalHydrate = KHYPE.balanceOf(address(hydrate));

        uint256 msgValue = 10 ether;
        hydrate.burnHype(msgValue);

        assertGt(msgValue, IERC20(address(WHYPE)).balanceOf(minter) - preBalMinter);
        assertGt(KHYPE.balanceOf(treasury), preBalTreasury);
        assertGt(KHYPE.balanceOf(address(hydrate)), preBalHydrate - msgValue);

        vm.stopBroadcast();
    }

    // Test all functions that mutate KHYPE balance for borrows
    function test_borrow() public {
        _setup();

        vm.startBroadcast(borrower);

        KHYPE.approve(address(hydrate), type(uint256).max);

        // ===== Mint and borrow =====
        hydrate.freezeKHYPE(borrower, 1000 ether);

        uint256 preBacking = hydrate.balanceOf(address(hydrate));
        uint256 preBal = KHYPE.balanceOf(address(treasury));
        uint256 preBalBorrower = KHYPE.balanceOf(borrower);
        hydrate.borrow(100 ether, 10);

        // 97.5% of borrow goes to borrower
        assertEq(97.5 ether + preBalBorrower, KHYPE.balanceOf(borrower));

        // Treasury collects fee
        assertGt(KHYPE.balanceOf(treasury), preBal);

        // Backing increases
        assertGt(hydrate.balanceOf(address(hydrate)), preBacking);

        // ==== Increase Borrow ====
        preBacking = hydrate.balanceOf(address(hydrate));
        preBal = KHYPE.balanceOf(address(treasury));
        uint256 preBorrower = KHYPE.balanceOf(borrower);

        hydrate.increaseBorrow(1 ether);

        // Borrower recieves more KHYPE
        assertGt(KHYPE.balanceOf(borrower), preBorrower);

        // Treasury collects fee
        assertGt(KHYPE.balanceOf(treasury), preBal);

        // Backing increases
        assertGt(hydrate.balanceOf(address(hydrate)), preBacking);

        // ===== Extend Loan =====
        preBal = KHYPE.balanceOf(address(treasury));
        preBacking = hydrate.balanceOf(address(hydrate));
        (uint256 _collateral, uint256 borrowed, uint256 _time) = hydrate.getLoanByAddress(borrower);
        uint256 loanFee = hydrate.getInterestFee(borrowed, 10);

        hydrate.extendLoan(10, loanFee);

        // Treasury collects fee
        assertGt(KHYPE.balanceOf(treasury), preBal);

        // Backing increases
        assertGt(KHYPE.balanceOf(address(hydrate)), preBacking);

        // ===== Repay =====
        preBacking = KHYPE.balanceOf(address(hydrate));

        hydrate.repay(1 ether);

        assertEq(1 ether + preBacking, KHYPE.balanceOf(address(hydrate)));

        // ===== Close Position =====
        preBacking = KHYPE.balanceOf(address(hydrate));
        preBalBorrower = hydrate.balanceOf(borrower);
        (_collateral, borrowed, _time) = hydrate.getLoanByAddress(borrower);
        hydrate.closePosition(borrowed);

        // Backing increases
        assertEq(preBacking + borrowed, KHYPE.balanceOf(address(hydrate)));

        // Borrower gets collateral back
        assertEq(preBalBorrower + _collateral, hydrate.balanceOf(borrower));
        vm.stopBroadcast();
    }

    function test_loop() public {
        _setup();

        vm.startBroadcast(borrower);
        KHYPE.approve(address(hydrate), type(uint256).max);
        IMockKHYPE(address(KHYPE)).mint(borrower, 9000 ether);
        uint256 preBal = KHYPE.balanceOf(address(hydrate));
        uint256 preBalTreasury = KHYPE.balanceOf(treasury);

        hydrate.loop(1000 ether, 300);

        vm.stopBroadcast();

        // Simulate price appreciation by minting and burning
        vm.startBroadcast(minter);
        KHYPE.approve(address(hydrate), type(uint256).max);
        hydrate.freezeKHYPE(minter, 5000 ether);
        hydrate.burn(4000 ether);
        vm.stopBroadcast();

        vm.startBroadcast(borrower);

        assertGt(KHYPE.balanceOf(address(hydrate)), preBal);
        assertGt(KHYPE.balanceOf(treasury), preBalTreasury);

        uint256 preBalBorrower = KHYPE.balanceOf(borrower);
        preBalTreasury = KHYPE.balanceOf(treasury);
        hydrate.flashBurn();

        assertGt(KHYPE.balanceOf(treasury), preBalTreasury);
        assertGt(KHYPE.balanceOf(borrower), preBalBorrower);

        vm.stopBroadcast();
    }
}
