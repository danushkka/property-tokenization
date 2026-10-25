// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {PropertyToken} from "../../src/PropertyToken.sol";
import {WhitelistValidator} from "../../src/WhitelistValidator.sol";
import {RevenueVault} from "../../src/RevenueVault.sol";
import {DividendDistributor} from "../../src/DividendDistributor.sol";

contract DividendDistributorTest is Test {
    /////////////////////////////////////
    ////////// STATE VARIABLES //////////
    /////////////////////////////////////

    ERC20Mock public stablecoin;
    WhitelistValidator public validator;
    PropertyToken public token;
    RevenueVault public vault;
    DividendDistributor public distributor;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 public constant STARTING_BALANCE = 100e18;
    uint256 public constant MAX_SUPPLY = 1_000_000e18;

    /////////////////////////////////////
    ///////////// MODIFIERS /////////////
    /////////////////////////////////////

    modifier deposited() {
        // `admin` deposits the maximum possible balance (e.g. MAX_SUPPLY == 1_000_000e18)
        vm.startPrank(admin);
        stablecoin.mint(admin, MAX_SUPPLY);
        stablecoin.approve(address(vault), MAX_SUPPLY);
        vault.deposit(MAX_SUPPLY);
        vm.stopPrank();
        _;
    }

    modifier whitelistedAndMinted(address account) {
        vm.startPrank(admin);
        validator.addToWhitelist(account);
        token.mint(alice, MAX_SUPPLY);
        vm.stopPrank();
        _;
    }

    //////////////////////////////////////
    /////////////// SET UP ///////////////
    //////////////////////////////////////

    function setUp() public {
        stablecoin = new ERC20Mock();

        vm.startPrank(admin);

        validator = new WhitelistValidator(admin);
        token = new PropertyToken("PropToken", "PPT", admin, address(validator), MAX_SUPPLY);
        vault = new RevenueVault(admin, address(stablecoin));
        distributor = new DividendDistributor(address(token), address(vault), admin);

        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));
        validator.addToWhitelist(admin);

        vm.stopPrank();
    }

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    function test_Constructor_RevertWhen_TokenIsZeroAddress() public {
        address newVault = makeAddr("newVault");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.DividendDistributor__ZeroAddress.selector));
        new DividendDistributor(address(0), newVault, admin);
    }

    function test_Constructor_RevertWhen_VaultIsZeroAddress() public {
        address newToken = makeAddr("newToken");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.DividendDistributor__ZeroAddress.selector));
        new DividendDistributor(newToken, address(0), admin);
    }

    //////////////////////////////////////
    ///////// DECLARE DIVIDENDS //////////
    //////////////////////////////////////

    function test_DeclareDividends_SetsDividendRound(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.prank(admin);
        distributor.declareDividends(amount);

        (uint256 snapshotBlock, uint256 totalAmount, uint256 totalSupply) = distributor.rounds(0);

        assertEq(snapshotBlock, block.number - 1);
        assertEq(totalAmount, amount);
        assertEq(totalSupply, MAX_SUPPLY); // MAX_SUPPLY == 1_000_000e18
    }

    function test_DeclareDividends_IncreasesTotalOwed(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY / 2 - 1); // ensure that depositing twice does not exceed MAX_SUPPLY

        vm.prank(admin);
        distributor.declareDividends(amount);
        assertEq(distributor.s_totalOwed(), amount);

        vm.roll(block.number + 1);
        vm.prank(admin);
        distributor.declareDividends(amount);
        assertEq(distributor.s_totalOwed(), amount * 2);
    }

    function test_DeclareDividends_EmitsExpectedEvent(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.roll(block.number + 1);
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit DividendDistributor.DividendDeclared(0, block.number - 1, amount, MAX_SUPPLY);
        distributor.declareDividends(amount);
        vm.stopPrank();
    }

    function test_DeclareDividends_RevertWhen_NotByDividendManager(uint256 amount)
        public
        deposited
        whitelistedAndMinted(alice)
    {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert();
        distributor.declareDividends(amount);
    }

    function test_DeclareDividends_RevertWhen_ZeroAmount() public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.DividendDistributor__ZeroAmount.selector));
        distributor.declareDividends(0);
    }

    function test_DeclareDividends_RevertWhen_NoSupplyAtSnapshot() public deposited {
        vm.roll(block.number + 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistributor.DividendDistributor__NoSupplyAtSnapshot.selector, block.number - 1
            )
        );
        distributor.declareDividends(MAX_SUPPLY);
    }

    function test_DeclareDividends_RevertWhen_DividendTooSmallForSupply(uint256 amount)
        public
        deposited
        whitelistedAndMinted(alice)
    {
        vm.roll(block.number + 1);
        uint256 minDividendRequired = distributor.getMinDividendAmount();
        amount = bound(amount, 1, minDividendRequired - 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistributor.DividendDistributor__DividendTooSmallForSupply.selector, amount, minDividendRequired
            )
        );
        distributor.declareDividends(amount);
    }

    function test_DeclareDividends_RevertWhen_InsufficientVaultBalance(uint256 amount)
        public
        whitelistedAndMinted(alice)
    {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistributor.DividendDistributor__InsufficientVaultBalance.selector, 0, amount
            )
        );
        distributor.declareDividends(amount);
        vm.stopPrank();
    }

    //////////////////////////////////////
    /////////////// CLAIM ////////////////
    //////////////////////////////////////

    function test_Claim_DividendClaimed(uint256 amount) public whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);
        uint256 balanceBefore = stablecoin.balanceOf(alice);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claim(0);

        uint256 balanceAfter = stablecoin.balanceOf(alice);

        assertEq(balanceAfter, balanceBefore + amount);
    }

    function test_Claim_DividendClaimedByMultipleHolders(uint256 amount) public {
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        validator.addToWhitelist(bob);
        token.mint(alice, MAX_SUPPLY * 60 / 100);
        token.mint(bob, MAX_SUPPLY * 40 / 100);
        vm.stopPrank();

        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        uint256 aliceBalanceBefore = stablecoin.balanceOf(alice);
        uint256 bobBalanceBefore = stablecoin.balanceOf(bob);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claim(0);

        vm.prank(bob);
        distributor.claim(0);

        assertEq(stablecoin.balanceOf(alice), aliceBalanceBefore + amount * 60 / 100);
        assertEq(stablecoin.balanceOf(bob), bobBalanceBefore + amount * 40 / 100);
    }

    function test_Claim_DividendClaimedAfterMultipleBlocks(uint256 amount, uint256 blocksToRoll)
        public
        whitelistedAndMinted(alice)
    {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);
        blocksToRoll = bound(blocksToRoll, 1, type(uint32).max);
        uint256 balanceBefore = stablecoin.balanceOf(alice);

        vm.roll(block.number + blocksToRoll);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claim(0);
        uint256 balanceAfter = stablecoin.balanceOf(alice);

        assertEq(balanceAfter, balanceBefore + amount);
    }

    function test_Claim_DividendClaimedAfterMultipleRounds(uint256 amount) public whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);
        uint256 balanceBefore = stablecoin.balanceOf(alice);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.roll(block.number + 1);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claim(0);
        uint256 balanceAfterFirstRound = stablecoin.balanceOf(alice);
        assertEq(balanceAfterFirstRound, balanceBefore + amount);

        vm.roll(block.number + 1);
        vm.prank(alice);
        distributor.claim(1);
        uint256 balanceAfterSecondRound = stablecoin.balanceOf(alice);
        assertEq(balanceAfterSecondRound, balanceAfterFirstRound + amount);
    }

    function test_Claim_AllowsToClaimAfterDelegationAttempt(uint256 amount)
        public
        deposited
        whitelistedAndMinted(alice)
    {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);
        uint256 balanceBefore = stablecoin.balanceOf(alice);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        // An attempt of delegating to another address
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.PropertyToken__DelegationDisabled.selector));
        vm.prank(alice);
        token.delegate(bob);

        vm.prank(alice);
        distributor.claim(0);
        uint256 balanceAfter = stablecoin.balanceOf(alice);

        assertEq(balanceAfter, balanceBefore + amount);
    }

    function test_Claim_DecreasesTotalOwed(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        uint256 totalOwedBefore = distributor.s_totalOwed();

        vm.prank(alice);
        distributor.claim(0);

        assertEq(distributor.s_totalOwed(), totalOwedBefore - amount);
    }

    function test_Claim_EmitsExpectedEvent(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit DividendDistributor.DividendClaimed(0, alice, amount);
        distributor.claim(0);
    }

    function test_Claim_SetsClaimedStatus(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claim(0);

        assertTrue(distributor.getClaimedStatus(alice, 0));
    }

    function test_Claim_RevertWhen_InvalidRound(uint256 amount, uint256 invalidRoundId)
        public
        deposited
        whitelistedAndMinted(alice)
    {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        invalidRoundId = bound(amount, 1, MAX_SUPPLY);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.DividendDistributor__InvalidRound.selector));
        distributor.claim(invalidRoundId);
    }

    function test_Claim_RevertWhen_AlreadyClaimed(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claim(0);

        // Another dividend round
        vm.roll(block.number + 1);

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.DividendDistributor__AlreadyClaimed.selector));
        distributor.claim(0);
    }

    function test_Claim_RevertWhen_NothingToClaim(uint256 amount) public deposited whitelistedAndMinted(alice) {
        vm.prank(admin);
        validator.addToWhitelist(bob);

        vm.roll(block.number + 1);
        amount = bound(amount, distributor.getMinDividendAmount(), MAX_SUPPLY);

        vm.prank(admin);
        distributor.declareDividends(amount);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.DividendDistributor__NothingToClaim.selector));
        distributor.claim(0);
    }

    //////////////////////////////////////
    ////////////// GETTERS ///////////////
    //////////////////////////////////////

    function test_GetMinDividendAmount() public whitelistedAndMinted(alice) {
        vm.roll(block.number + 1);
        uint256 supply = token.getPastTotalSupply(block.number - 1);

        assertEq(supply / distributor.MIN_PROTECTED_HOLDING(), distributor.getMinDividendAmount());
    }

    function test_GetMinDividendAmount_ScalesWithSupply() public {
        uint256 partialAmount = MAX_SUPPLY / 4;
        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        token.mint(alice, partialAmount);
        vm.stopPrank();

        vm.roll(block.number + 1);

        assertEq(distributor.getMinDividendAmount(), partialAmount / distributor.MIN_PROTECTED_HOLDING());
    }

    function test_GetRoundCount() public whitelistedAndMinted(alice) {
        uint256 roundsToTest = 100;
        vm.roll(block.number + 1);
        uint256 amount = distributor.getMinDividendAmount();

        for (uint256 i = 1; i <= roundsToTest; i++) {
            vm.roll(block.number + 1);

            vm.startPrank(admin);
            stablecoin.mint(admin, amount);
            stablecoin.approve(address(vault), amount);
            vault.deposit(amount);
            distributor.declareDividends(amount);
            vm.stopPrank();

            assertEq(distributor.getRoundCount(), i);
        }
    }
}
