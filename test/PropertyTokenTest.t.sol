// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {PropertyToken} from "../src/PropertyToken.sol";
import {WhitelistValidator} from "../src/WhitelistValidator.sol";
import {IComplianceValidator} from "../src/interfaces/IComplianceValidator.sol";

contract PropertyTokenTest is Test {
    //////////////////////////////////////
    ////////// STATE VARIABLES ///////////
    //////////////////////////////////////

    PropertyToken public token;
    WhitelistValidator public validator;

    uint256 public constant MAX_SUPPLY = 1_000_000e18;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    //////////////////////////////////////
    /////////////// EVENTS ///////////////
    //////////////////////////////////////

    event ComplianceValidatorUpdated(address indexed complianceValidator);

    //////////////////////////////////////
    /////////////// SET UP ///////////////
    //////////////////////////////////////

    function setUp() public {
        vm.startPrank(admin);
        validator = new WhitelistValidator(admin);
        token = new PropertyToken("Property Token", "PPT", admin, address(validator), MAX_SUPPLY);
        vm.stopPrank();
    }

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    function test_Constructor_RevertWhen_ZeroMaxSupply() public {
        address newValidator = makeAddr("newValidator");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.PropertyToken__MaxSupplyCannotBeZero.selector));
        new PropertyToken("name", "symbol", admin, newValidator, 0);
    }

    //////////////////////////////////////
    //////////////// MINT ////////////////
    //////////////////////////////////////

    function test_Mint_IncreasesBalance(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), amount);
    }

    function test_Mint_SucceedsAtExactlyMaxSupply() public {
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, token.getMaxSupply());
        vm.stopPrank();

        assertEq(token.balanceOf(alice), token.getMaxSupply());
    }

    function test_Mint_AutoDelegatesToItself(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        vm.stopPrank();

        assertEq(token.delegates(alice), alice);
    }

    function test_Mint_MakesVotingPowerQueryable(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        vm.stopPrank();

        uint256 timepoint = block.number;

        vm.roll(timepoint + 1);
        assertEq(token.getPastVotes(alice, timepoint), amount);
    }

    function test_Mint_EmitsDelegateChangedOnFirstReceipt(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        vm.prank(admin);
        validator.addToWhitelist(alice);

        vm.expectEmit(true, true, true, true, address(token));
        emit IVotes.DelegateChanged(alice, address(0), alice);

        vm.prank(admin);
        token.mint(alice, amount);
    }

    function test_Mint_RevertWhen_ToNonWhitelistedAccount(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.PropertyToken__TransferNotCompliant.selector, address(0), alice, amount
            )
        );
        token.mint(alice, amount);
    }

    function test_Mint_RevertWhen_NotByIssuer(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        bytes32 differentRole = keccak256("DIFFERENT_ROLE");
        vm.prank(admin);
        token.grantRole(differentRole, bob);

        // Account without role
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, amount);

        // Account with different role
        vm.prank(bob);
        vm.expectRevert();
        token.mint(bob, amount);
    }

    function test_Mint_RevertWhen_ExceedsMaxSupply(uint256 amount) public {
        amount = bound(amount, token.getMaxSupply() + 1, type(uint128).max);

        vm.startPrank(admin);
        validator.addToWhitelist(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.PropertyToken__MaxSupplyExceeded.selector, amount, token.getMaxSupply()
            )
        );
        token.mint(alice, amount);
        vm.stopPrank();
    }

    //////////////////////////////////////
    //////////// SET VALIDATOR ///////////
    //////////////////////////////////////

    function test_SetComplianceValidator() public {
        // Note: we assume that `admin` uses a valid and trustworthy validator address
        address newValidator = makeAddr("newValidator");
        vm.prank(admin);
        token.setComplianceValidator(newValidator);

        assertEq(address(token.validator()), newValidator);
    }

    function test_SetComplianceValidator_EmitsExpectedEvent() public {
        address newValidator = makeAddr("newValidator");

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(token));
        emit PropertyToken.ComplianceValidatorUpdated(newValidator);
        token.setComplianceValidator(newValidator);
    }

    function test_SetComplianceValidator_RevertWhen_NotByAdmin() public {
        address newValidator = makeAddr("newValidator");
        bytes32 differentRole = keccak256("DIFFERENT_ROLE");
        vm.prank(admin);
        token.grantRole(differentRole, bob);

        // Account without role
        vm.prank(alice);
        vm.expectRevert();
        token.setComplianceValidator(newValidator);

        // Account with different role
        vm.prank(bob);
        vm.expectRevert();
        token.setComplianceValidator(newValidator);
    }

    //////////////////////////////////////
    ////////////// TRANSFER //////////////
    //////////////////////////////////////

    function test_Transfer_BothPartiesWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        // Add both to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        validator.addToWhitelist(bob);
        vm.stopPrank();

        // Transfer from `alice` to `bob`
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);

        // Transfer from `bob` to `alice`
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(alice), amount);
    }

    function test_Transfer_DoesNotOverrideExistingDelegation(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply() / 2 - 1);

        // Add both to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount); // `alice` has voting power of `amount`
        validator.addToWhitelist(bob);
        vm.stopPrank();

        // `alice` delegates voting power to `bob`
        vm.prank(alice);
        token.delegate(bob);

        // `alice` receives more tokens
        vm.prank(admin);
        token.mint(alice, amount);

        assertEq(token.delegates(alice), bob); // must still point to `bob`
    }

    function test_Transfer_MovesVotingPowerBetweenHolders(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        // Add both to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount); // `alice` has voting power of `amount`
        validator.addToWhitelist(bob);
        vm.stopPrank();

        uint256 amountToSend = amount * 40 / 100; // send 40% of the tokens

        // Transfer from `alice` to `bob`
        vm.prank(alice);
        token.transfer(bob, amountToSend);
        uint256 amountRemains = amount - amountToSend; // 60% should remain

        uint256 timepoint = block.number;

        vm.roll(timepoint + 1);
        assertEq(token.getPastVotes(alice, timepoint), amountRemains);
        assertEq(token.getPastVotes(bob, timepoint), amountToSend);
    }

    function test_Transfer_RevertWhen_NeitherPartyWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        // Transfer from `alice` to `bob`
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, alice, bob, amount)
        );
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);

        // Transfer from `bob` to `alice`
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, bob, alice, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Transfer_RevertWhen_OnlySenderWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        // Add `alice` (sender) to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        vm.stopPrank();

        // Transfer from `alice` to `bob`
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, alice, bob, amount)
        );
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Transfer_RevertWhen_OnlyRecipientWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        // Add `bob` (recipient) to whitelist
        vm.prank(admin);
        validator.addToWhitelist(bob);

        // Transfer from `alice` to `bob`
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, alice, bob, amount)
        );
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Transfer_RevertWhen_SenderWhitelistRevokedAfterHoldingTokens(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());

        // Add `alice` to whitelist, mint tokens and then remove from whitelist
        // Add `bob` to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        validator.removeFromWhitelist(alice); // revoked after getting tokens
        validator.addToWhitelist(bob);
        vm.stopPrank();

        // Transfer from `alice` to `bob`
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, alice, bob, amount)
        );
        token.transfer(bob, amount);
    }

    //////////////////////////////////////
    /////////// TRANSFER FROM ////////////
    //////////////////////////////////////

    function test_TransferFrom_BothPartiesWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());
        address spender = makeAddr("spender");

        // Approve `amount` to `spender`
        vm.prank(alice);
        token.approve(spender, amount);
        vm.prank(bob);
        token.approve(spender, amount);

        // Add both to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        validator.addToWhitelist(bob);
        vm.stopPrank();

        // Transfer from `alice` to `bob`
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);

        // Transfer from `bob` to `alice`
        vm.prank(spender);
        token.transferFrom(bob, alice, amount);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(alice), amount);
    }

    function test_TransferFrom_RevertWhen_NeitherPartyWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());
        address spender = makeAddr("spender");

        // Approve `amount` to `spender`
        vm.prank(alice);
        token.approve(spender, amount);
        vm.prank(bob);
        token.approve(spender, amount);

        // Transfer from `alice` to `bob`
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, alice, bob, amount)
        );
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);

        // Transfer from `bob` to `alice`
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, bob, alice, amount)
        );
        token.transferFrom(bob, alice, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFrom_RevertWhen_OnlySenderWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());
        address spender = makeAddr("spender");

        // Approve `amount` to `spender`
        vm.prank(alice);
        token.approve(spender, amount);

        // Add `alice` (sender) to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, amount);
        vm.stopPrank();

        // Transfer from `alice` to `bob`
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, alice, bob, amount)
        );
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFrom_RevertWhen_OnlyRecipientWhitelisted(uint256 amount) public {
        amount = bound(amount, 1, token.getMaxSupply());
        address spender = makeAddr("spender");

        // Approve `amount` to `spender`
        vm.prank(alice);
        token.approve(spender, amount);

        // Add `bob` (recipient) to whitelist
        vm.startPrank(admin);
        validator.addToWhitelist(bob);
        vm.stopPrank();

        // Transfer from `alice` to `bob`
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.PropertyToken__TransferNotCompliant.selector, alice, bob, amount)
        );
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }
}
