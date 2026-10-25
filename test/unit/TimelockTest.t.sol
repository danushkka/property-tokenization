// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {WhitelistValidator} from "../../src/WhitelistValidator.sol";
import {PropertyToken} from "../../src/PropertyToken.sol";
import {PropertyIssuance} from "../../src/PropertyIssuance.sol";
import {RevenueVault} from "../../src/RevenueVault.sol";
import {DividendDistributor} from "../../src/DividendDistributor.sol";

contract TimelockTest is Test {
    /////////////////////////////////////
    ////////// STATE VARIABLES //////////
    /////////////////////////////////////

    ERC20Mock public stablecoin;
    WhitelistValidator public validator;
    PropertyToken public token;
    PropertyIssuance public issuer;
    RevenueVault public vault;
    DividendDistributor public distributor;

    TimelockController public timelock;

    address treasury = makeAddr("treasury");

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    address guardian1 = makeAddr("guardian1");
    address guardian2 = makeAddr("guardian2");
    address guardian3 = makeAddr("guardian3");

    uint256 public constant MIN_DELAY = 72 hours;
    uint256 public constant INITIAL_PRICE = 10e6; // $10 in USDC
    uint256 public constant MAX_PURCHASE_PER_TX = 10_000e18; // 10_000 tokens

    //////////////////////////////////////
    /////////////// SET UP ///////////////
    //////////////////////////////////////

    function setUp() public {
        vm.startPrank(admin);
        stablecoin = new ERC20Mock();
        validator = new WhitelistValidator(admin);
        token = new PropertyToken("PropToken", "PPT", admin, address(validator), 1_000_000e18);
        issuer = new PropertyIssuance(
            address(token), address(stablecoin), treasury, admin, INITIAL_PRICE, MAX_PURCHASE_PER_TX
        );
        vault = new RevenueVault(admin, address(stablecoin));
        distributor = new DividendDistributor(address(token), address(vault), admin);
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));
        validator.addToWhitelist(admin);
        vm.stopPrank();

        address[] memory proposers = new address[](1);
        proposers[0] = admin;

        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone can execute once the delay passes

        vm.prank(admin);
        timelock = new TimelockController(MIN_DELAY, proposers, executors, admin);

        vm.startPrank(admin);

        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian1);
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian2);
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian3);

        token.grantRole(token.ISSUER_ROLE(), address(issuer));
        token.revokeRole(token.ISSUER_ROLE(), admin);
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), address(timelock));
        token.revokeRole(token.DEFAULT_ADMIN_ROLE(), admin);

        issuer.grantRole(issuer.DEFAULT_ADMIN_ROLE(), address(timelock));
        issuer.revokeRole(issuer.DEFAULT_ADMIN_ROLE(), admin);

        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(timelock));
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), admin);

        distributor.grantRole(distributor.DEFAULT_ADMIN_ROLE(), address(timelock));
        distributor.revokeRole(distributor.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopPrank();
    }

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    function test_Constructor_GrantsCancellerRoleToAllGuardians() public view {
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian1));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian2));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian3));
    }

    function test_Constructor_AdminHoldsProposerRole() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), admin));
    }

    //////////////////////////////////////
    ///////////// GRANT ROLE /////////////
    //////////////////////////////////////

    function test_RevertWhen_AdminDirectlyGrantsRoleOnIssuer() public {
        address newIssuer = makeAddr("newIssuer");
        bytes32 issuerRole = token.ISSUER_ROLE();

        vm.prank(admin);
        vm.expectRevert();
        token.grantRole(issuerRole, newIssuer);
    }

    function test_RevertWhen_AdminDirectlyGrantsRoleOnVault() public {
        address newDistributor = makeAddr("newDistributor");
        bytes32 distributorRole = vault.DISTRIBUTOR_ROLE();

        vm.prank(admin);
        vm.expectRevert();
        vault.grantRole(distributorRole, newDistributor);
    }

    function test_RevertWhen_AdminDirectlyGrantsRoleOnDistributor() public {
        bytes32 someRole = keccak256("someRole");

        vm.prank(admin);
        vm.expectRevert();
        distributor.grantRole(someRole, address(distributor));
    }

    function test_RevertWhen_AdminDirectlySetsComplianceValidator() public {
        address maliciousValidator = makeAddr("maliciousValidator");

        vm.prank(admin);
        vm.expectRevert();
        token.setComplianceValidator(maliciousValidator);
    }

    function test_RevertWhen_AdminDirectlyForceUpdatesPrice() public {
        uint256 newPrice = 100e6;

        vm.prank(admin);
        vm.expectRevert();
        issuer.forceUpdatePrice(newPrice);
    }

    //////////////////////////////////////
    /////////////// DELAY ////////////////
    //////////////////////////////////////

    function test_Timelock_RevertWhen_ExecutedOneSecondBeforeDelay() public {
        address newValidator = makeAddr("newValidator");
        uint256 newPrice = 100e6;

        bytes memory setValidatorData = abi.encodeWithSelector(token.setComplianceValidator.selector, newValidator);
        bytes memory forceUpdatePriceData = abi.encodeWithSelector(issuer.forceUpdatePrice.selector, newPrice);

        vm.startPrank(admin);
        timelock.schedule(address(token), 0, setValidatorData, bytes32(0), bytes32(0), MIN_DELAY);
        timelock.schedule(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY - 1);

        vm.expectRevert();
        timelock.execute(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
        vm.expectRevert();
        timelock.execute(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));
    }

    function test_Timelock_ExecutesSuccessfullyAfterDelayPassed() public {
        address newValidator = makeAddr("newValidator");
        uint256 newPrice = 100e6;

        bytes memory setValidatorData = abi.encodeWithSelector(token.setComplianceValidator.selector, newValidator);
        bytes memory forceUpdatePriceData = abi.encodeWithSelector(issuer.forceUpdatePrice.selector, newPrice);

        vm.startPrank(admin);
        timelock.schedule(address(token), 0, setValidatorData, bytes32(0), bytes32(0), MIN_DELAY);
        timelock.schedule(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        timelock.execute(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
        timelock.execute(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));

        assertEq(address(token.validator()), newValidator);
        assertEq(issuer.s_pricePerToken(), newPrice);
    }

    //////////////////////////////////////
    ///////////// GUARDIANS //////////////
    //////////////////////////////////////

    function test_Guardians_CanCancelIndependently() public {
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        address newValidator = makeAddr("newValidator");
        uint256 newPrice = 100e6;

        bytes memory setValidatorData = abi.encodeWithSelector(token.setComplianceValidator.selector, newValidator);
        bytes memory forceUpdatePriceData = abi.encodeWithSelector(issuer.forceUpdatePrice.selector, newPrice);

        for (uint256 i; i < guardians.length; i++) {
            vm.startPrank(admin);
            bytes32 setValidatorOperationId =
                timelock.hashOperation(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
            timelock.schedule(address(token), 0, setValidatorData, bytes32(0), bytes32(0), MIN_DELAY);

            bytes32 forceUpdatePriceOperationId =
                timelock.hashOperation(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));
            timelock.schedule(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0), MIN_DELAY);
            vm.stopPrank();

            vm.startPrank(guardians[i]);
            timelock.cancel(setValidatorOperationId);
            timelock.cancel(forceUpdatePriceOperationId);
            vm.stopPrank();

            vm.warp(block.timestamp + MIN_DELAY);

            vm.expectRevert();
            timelock.execute(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
            vm.expectRevert();
            timelock.execute(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));

            // The validator and the token price were never actually changed
            assertTrue(address(token.validator()) != newValidator);
            assertTrue(issuer.s_pricePerToken() != newPrice);
        }
    }

    function test_Guardians_RevertWhen_ExecutingCancelledOperation_EvenAfterDelay() public {
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        address newValidator = makeAddr("newValidator");
        uint256 newPrice = 100e6;

        bytes memory setValidatorData = abi.encodeWithSelector(token.setComplianceValidator.selector, newValidator);
        bytes memory forceUpdatePriceData = abi.encodeWithSelector(issuer.forceUpdatePrice.selector, newPrice);

        for (uint256 i; i < guardians.length; i++) {
            vm.startPrank(admin);
            bytes32 setValidatorOperationId =
                timelock.hashOperation(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
            timelock.schedule(address(token), 0, setValidatorData, bytes32(0), bytes32(0), MIN_DELAY);

            bytes32 forceUpdatePriceOperationId =
                timelock.hashOperation(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));
            timelock.schedule(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0), MIN_DELAY);
            vm.stopPrank();

            vm.startPrank(guardians[i]);
            timelock.cancel(setValidatorOperationId);
            timelock.cancel(forceUpdatePriceOperationId);
            vm.stopPrank();

            vm.warp(block.timestamp + MIN_DELAY);

            vm.expectRevert();
            timelock.execute(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
            vm.expectRevert();
            timelock.execute(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));

            // the replacement should not succeed
            assertTrue(address(token.validator()) != newValidator);
            assertTrue(issuer.s_pricePerToken() != newPrice);
        }
    }

    function test_Guardians_RevertWhen_NonGuardianAttemptsCancel() public {
        address newValidator = makeAddr("newValidator");
        uint256 newPrice = 100e6;

        bytes memory setValidatorData = abi.encodeWithSelector(token.setComplianceValidator.selector, newValidator);
        bytes memory forceUpdatePriceData = abi.encodeWithSelector(issuer.forceUpdatePrice.selector, newPrice);

        vm.startPrank(admin);
        bytes32 setValidatorOperationId =
            timelock.hashOperation(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
        timelock.schedule(address(token), 0, setValidatorData, bytes32(0), bytes32(0), MIN_DELAY);

        bytes32 forceUpdatePriceOperationId =
            timelock.hashOperation(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));
        timelock.schedule(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0), MIN_DELAY);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert();
        timelock.cancel(setValidatorOperationId);

        vm.expectRevert();
        timelock.cancel(forceUpdatePriceOperationId);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        timelock.execute(address(token), 0, setValidatorData, bytes32(0), bytes32(0));
        timelock.execute(address(issuer), 0, forceUpdatePriceData, bytes32(0), bytes32(0));

        // the replacement should succeed
        assertEq(address(token.validator()), newValidator);
        assertEq(issuer.s_pricePerToken(), newPrice);
    }

    //////////////////////////////////////
    //////////// NO TIMELOCK /////////////
    //////////////////////////////////////

    ///// Property Token /////

    function test_Mint_StillWorksDirectlyWithoutTimelock() public {
        uint256 amount = 100 ether;

        vm.prank(admin);
        validator.addToWhitelist(alice);

        vm.prank(address(issuer));
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount);
    }

    ///// PropertyIssuance /////

    function test_UpdatePrice_StillWorksDirectlyWithoutTimelock() public {
        uint256 newPrice = INITIAL_PRICE + 1;

        vm.prank(admin);
        issuer.updatePrice(newPrice);

        assertEq(issuer.s_pricePerToken(), newPrice);
    }

    ///// Revenue Vault /////

    function test_Deposit_StillWorksDirectlyWithoutTimelock() public {
        uint256 amount = 100e6; // $100 in USDC

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);

        vault.deposit(amount);
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(address(vault)), amount);
    }

    function test_WithdrawTo_StillWorksDirectlyWithoutTimelock() public {
        uint256 amount = 100e6; // $100 in USDC

        vm.startPrank(admin);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        vm.prank(address(distributor));
        vault.withdrawTo(admin, amount / 2);

        assertEq(stablecoin.balanceOf(address(vault)), amount / 2);
        assertEq(stablecoin.balanceOf(admin), amount / 2);
    }

    ///// Dividend Distributor /////

    function test_DeclareDividends_StillWorksDirectlyWithoutTimelock() public {
        uint256 amount = 100 ether;

        vm.startPrank(admin);
        validator.addToWhitelist(alice);
        stablecoin.mint(admin, amount);
        stablecoin.approve(address(vault), amount);

        vault.deposit(amount);
        vm.stopPrank();

        vm.prank(address(issuer));
        token.mint(alice, amount);

        vm.roll(block.number + 1);
        vm.prank(admin);
        distributor.declareDividends(amount);

        assertEq(distributor.getRoundCount(), 1);
    }
}
