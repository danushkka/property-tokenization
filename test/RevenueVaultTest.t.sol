// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {RevenueVault} from "../src/RevenueVault.sol";

contract RevenueVaultTest is Test {
    /////////////////////////////////////
    ////////// STATE VARIABLES //////////
    /////////////////////////////////////

    RevenueVault public vault;
    ERC20Mock public stablecoin;

    address public admin = makeAddr("admin");
    address public distributor = makeAddr("distributor");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    //////////////////////////////////////
    /////////////// SET UP ///////////////
    //////////////////////////////////////

    function setUp() public {
        vm.startPrank(admin);
        stablecoin = new ERC20Mock();
        vault = new RevenueVault(admin, address(stablecoin));
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();

        stablecoin.mint(admin, type(uint128).max);
    }

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    function test_Constructor_RevertWhen_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.RevenueVault__ZeroAddress.selector));
        new RevenueVault(admin, address(0));
    }

    //////////////////////////////////////
    ////////////// DEPOSIT ///////////////
    //////////////////////////////////////

    function test_Deposit_ChangesBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.startPrank(admin);
        vault.grantRole(vault.DEPOSITOR_ROLE(), alice);
        vm.stopPrank();

        stablecoin.mint(alice, amount);
        uint256 aliceBalanceBefore = stablecoin.balanceOf(alice);

        vm.startPrank(alice);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
        uint256 aliceBalanceAfter = stablecoin.balanceOf(alice);

        assertEq(aliceBalanceAfter, aliceBalanceBefore - amount);
        assertEq(stablecoin.balanceOf(address(vault)), amount);
    }

    function test_Deposit_ChangesBalanceAfterMutipleDeposits(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.startPrank(admin);
        vault.grantRole(vault.DEPOSITOR_ROLE(), alice);
        vault.grantRole(vault.DEPOSITOR_ROLE(), bob);
        vm.stopPrank();

        stablecoin.mint(alice, amount);
        stablecoin.mint(bob, amount);
        uint256 aliceBalanceBefore = stablecoin.balanceOf(alice);
        uint256 bobBalanceBefore = stablecoin.balanceOf(bob);

        // `alice` deposits `amount`
        vm.startPrank(alice);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
        uint256 aliceBalanceAfter = stablecoin.balanceOf(alice);

        assertEq(aliceBalanceAfter, aliceBalanceBefore - amount);
        assertEq(stablecoin.balanceOf(address(vault)), amount);

        // `bob` deposits `amount`
        vm.startPrank(bob);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
        uint256 bobBalanceAfter = stablecoin.balanceOf(bob);

        assertEq(bobBalanceAfter, bobBalanceBefore - amount);
        assertEq(stablecoin.balanceOf(address(vault)), 2 * amount);
    }

    function test_Deposit_EmitsExpectedEvent(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.startPrank(admin);
        stablecoin.approve(address(vault), amount);

        vm.expectEmit();
        emit RevenueVault.Deposited(admin, amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_NotByDepositor(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        bytes32 differentRole = keccak256("DIFFERENT_ROLE");

        // Deposit with no role
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(amount);

        // Grant `differentRole` to `alice`
        vm.prank(admin);
        vault.grantRole(differentRole, alice);

        // Deposit with `differentRole`
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(amount);
    }

    function test_Deposit_RevertWhen_ZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.RevenueVault__ZeroAmount.selector));
        vault.deposit(0);
    }

    //////////////////////////////////////
    ////////////// WITHDRAW //////////////
    //////////////////////////////////////

    function test_WithdrawTo_ChangesBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        uint256 adminBalanceBefore = stablecoin.balanceOf(admin);

        vm.startPrank(admin);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
        uint256 adminBalanceAfter = stablecoin.balanceOf(admin);

        assertEq(adminBalanceAfter, adminBalanceBefore - amount);
        assertEq(stablecoin.balanceOf(address(vault)), amount);

        vm.prank(distributor);
        vault.withdrawTo(alice, amount);

        assertEq(stablecoin.balanceOf(alice), amount);
        assertEq(stablecoin.balanceOf(address(vault)), 0);
    }

    function test_WithdrawTo_EmitsExpectedEvent(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.startPrank(admin);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        vm.prank(distributor);
        vm.expectEmit();
        emit RevenueVault.WithdrawnTo(distributor, alice, amount);
        vault.withdrawTo(alice, amount);
    }

    function test_WithdrawTo_RevertWhen_NotByDistributor(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        bytes32 differentRole = keccak256("DIFFERENT_ROLE");

        vm.startPrank(admin);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        // Withdraw with no role
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawTo(alice, amount);

        // Grant `differentRole` to `alice`
        vm.prank(admin);
        vault.grantRole(differentRole, alice);

        // Withdraw with `differentRole`
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawTo(alice, amount);
    }

    function test_WithdrawTo_RevertWhen_ZeroAddress(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.startPrank(admin);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.RevenueVault__ZeroAddress.selector));
        vault.withdrawTo(address(0), amount);
    }

    function test_WithdrawTo_RevertWhen_ZeroAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.startPrank(admin);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.RevenueVault__ZeroAmount.selector));
        vault.withdrawTo(alice, 0);
    }

    //////////////////////////////////////
    ////////////// GETTERS ///////////////
    //////////////////////////////////////

    function test_GetTotalRevenue(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.startPrank(admin);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        assertEq(vault.getTotalRevenue(), stablecoin.balanceOf(address(vault)));
        assertEq(vault.getTotalRevenue(), amount);
    }
}
