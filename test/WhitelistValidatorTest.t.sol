// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {WhitelistValidator} from "../src/WhitelistValidator.sol";

contract WhitelistValidatorTest is Test {
    /////////////////////////////////////
    ////////// STATE VARIABLES //////////
    /////////////////////////////////////

    WhitelistValidator public validator;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /////////////////////////////////////
    ////////////// EVENTS ///////////////
    /////////////////////////////////////

    event AddedToWhitelist(address indexed account);
    event RemovedFromWhitelist(address indexed account);

    /////////////////////////////////////
    ///////////// MODIFIERS /////////////
    /////////////////////////////////////

    modifier addedToWhitelist(address account) {
        vm.prank(admin);
        validator.addToWhitelist(account);
        _;
    }

    //////////////////////////////////////
    /////////////// SET UP ///////////////
    //////////////////////////////////////

    function setUp() public {
        vm.prank(admin);
        validator = new WhitelistValidator(admin);
    }

    //////////////////////////////////////
    ////////// ADD TO WHITELIST //////////
    //////////////////////////////////////

    function test_AddToWhitelist_SetsAccountAsWhitelisted() public {
        vm.prank(admin);
        validator.addToWhitelist(alice);
        assertTrue(validator.isWhitelisted(alice));
    }

    function test_AddToWhitelist_SetsMultipleAccountsAsWhitelisted() public {
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        validator.addToWhitelist(bob);
        vm.stopPrank();

        assertTrue(validator.isWhitelisted(alice));
        assertTrue(validator.isWhitelisted(bob));
    }

    function test_AddToWhitelist_AfterRemoval() public addedToWhitelist(alice) {
        vm.prank(admin);
        validator.removeFromWhitelist(alice);
        assertFalse(validator.isWhitelisted(alice));

        vm.prank(admin);
        validator.addToWhitelist(alice);
        assertTrue(validator.isWhitelisted(alice));
    }

    function test_AddToWhitelist_EmitsExpectedEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(validator));
        emit WhitelistValidator.AddedToWhitelist(alice);
        validator.addToWhitelist(alice);
    }

    function test_AddToWhitelist_RevertWhen_NotByAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        validator.addToWhitelist(bob);
    }

    //////////////////////////////////////
    //////// REMOVE FROM WHITELIST ///////
    //////////////////////////////////////

    function test_RemoveFromWhitelist_SetsAccountAsNotWhitelisted() public addedToWhitelist(alice) {
        vm.prank(admin);
        validator.removeFromWhitelist(alice);
        assertFalse(validator.isWhitelisted(alice));
    }

    function test_RemoveFromWhitelist_SetsMultipleAccountsAsNotWhitelisted() public {
        // Whitelist both alices
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        validator.addToWhitelist(bob);
        vm.stopPrank();
        assertTrue(validator.isWhitelisted(alice));
        assertTrue(validator.isWhitelisted(bob));

        // Remove `bob`
        vm.prank(admin);
        validator.removeFromWhitelist(bob);
        assertTrue(validator.isWhitelisted(alice));
        assertFalse(validator.isWhitelisted(bob));

        // Remove `alice`
        vm.prank(admin);
        validator.removeFromWhitelist(alice);
        assertFalse(validator.isWhitelisted(alice));
        assertFalse(validator.isWhitelisted(bob));
    }

    function test_RemoveFromWhitelist_EmitsExpectedEvent() public addedToWhitelist(alice) {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(validator));
        emit WhitelistValidator.RemovedFromWhitelist(alice);
        validator.removeFromWhitelist(alice);
    }

    function test_RemoveFromWhitelist_RevertWhen_NotByAdmin() public addedToWhitelist(bob) {
        vm.prank(alice);
        vm.expectRevert();
        validator.removeFromWhitelist(bob);
    }

    //////////////////////////////////////
    //////////// CAN TRANSFER ////////////
    //////////////////////////////////////

    function test_CanMint_IfWhitelisted(uint256 amountToTransfer) public addedToWhitelist(alice) {
        amountToTransfer = bound(amountToTransfer, 1, type(uint128).max);
        assertTrue(validator.canTransfer(address(0), alice, amountToTransfer));
    }

    function test_CanBurn_IfWhitelisted(uint256 amountToTransfer) public addedToWhitelist(alice) {
        amountToTransfer = bound(amountToTransfer, 1, type(uint128).max);
        assertTrue(validator.canTransfer(alice, address(0), amountToTransfer));
    }

    function test_CanTransfer_IfBothPartiesAreWhitelisted(uint256 amountToTransfer)
        public
        addedToWhitelist(alice)
        addedToWhitelist(bob)
    {
        amountToTransfer = bound(amountToTransfer, 1, type(uint128).max);

        assertTrue(validator.canTransfer(alice, bob, amountToTransfer));
        assertTrue(validator.canTransfer(bob, alice, amountToTransfer));
    }

    function test_CanTransfer_ReturnsFalse_WhenMintToNonWhitelistedAddress(uint256 amountToTransfer)
        public
        addedToWhitelist(alice)
    {
        amountToTransfer = bound(amountToTransfer, 1, type(uint128).max);
        vm.prank(admin);
        validator.removeFromWhitelist(alice);

        assertFalse(validator.canTransfer(address(0), alice, amountToTransfer));
    }

    function test_CanTransfer_ReturnsFalse_WhenBurningToNonWhitelistedAddress(uint256 amountToTransfer)
        public
        addedToWhitelist(alice)
    {
        amountToTransfer = bound(amountToTransfer, 1, type(uint128).max);
        vm.prank(admin);
        validator.removeFromWhitelist(alice);

        assertFalse(validator.canTransfer(alice, address(0), amountToTransfer));
    }

    function test_CanTransfer_ReturnsFalse_WhenBothPartiesNonWhitelisted(uint256 amountToTransfer)
        public
        addedToWhitelist(alice)
    {
        amountToTransfer = bound(amountToTransfer, 1, type(uint128).max);

        // `bob` is not whitelisted
        assertFalse(validator.canTransfer(alice, bob, amountToTransfer));
        assertFalse(validator.canTransfer(bob, alice, amountToTransfer));

        // Remove `alice`
        vm.prank(admin);
        validator.removeFromWhitelist(alice);

        // Both are not whitelisted
        assertFalse(validator.canTransfer(alice, bob, amountToTransfer));
        assertFalse(validator.canTransfer(bob, alice, amountToTransfer));
    }

    function test_CanTransfer_ReturnsFalse_WhenBothAreZeroAddresses(uint256 amountToTransfer) public view {
        amountToTransfer = bound(amountToTransfer, 1, type(uint128).max);
        assertFalse(validator.canTransfer(address(0), address(0), amountToTransfer));
    }
}
