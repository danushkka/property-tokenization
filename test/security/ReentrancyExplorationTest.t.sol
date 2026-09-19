// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {MaliciousReentrantToken, ReentrantClaimer} from "../mocks/ReentrancyExploration.sol";
import {PropertyToken} from "../../src/PropertyToken.sol";
import {WhitelistValidator} from "../../src/WhitelistValidator.sol";
import {RevenueVault} from "../../src/RevenueVault.sol";
import {DividendDistributor} from "../../src/DividendDistributor.sol";

contract ReentrancyExplorationTest is Test {
    MaliciousReentrantToken public evilStablecoin;
    PropertyToken public token;
    WhitelistValidator public validator;
    ReentrantClaimer public attacker;
    RevenueVault public evilVault;
    DividendDistributor public evilDistributor;

    address admin = makeAddr("admin");

    uint256 public constant STARTING_BALANCE = 100e18;

    function setUp() public {
        evilStablecoin = new MaliciousReentrantToken();
        vm.startPrank(admin);

        validator = new WhitelistValidator(admin);
        token = new PropertyToken("Property Token", "PPT", admin, address(validator), 1_000_000e18);
        evilVault = new RevenueVault(admin, address(evilStablecoin));
        evilDistributor = new DividendDistributor(address(token), address(evilVault), admin);

        evilVault.grantRole(evilVault.DISTRIBUTOR_ROLE(), address(evilDistributor));
        attacker = new ReentrantClaimer(address(evilDistributor), 1);
        vm.stopPrank();
    }

    function test_Claim_ReentrantAttemptFailsWithoutBreakingLegitimateClaim() public {
        vm.startPrank(admin);
        validator.addToWhitelist(address(attacker));
        token.mint(address(attacker), STARTING_BALANCE);
        vm.stopPrank();

        // Declare round 0
        vm.roll(block.number + 1);

        vm.startPrank(admin);
        uint256 dividendAmount = evilDistributor.getMinDividendAmount();
        evilStablecoin.mint(admin, dividendAmount * 2);
        evilStablecoin.approve(address(evilVault), dividendAmount * 2);
        evilVault.deposit(dividendAmount * 2);

        evilDistributor.declareDividends(dividendAmount);
        vm.stopPrank();

        // Declare round 1
        vm.roll(block.number + 1);

        vm.prank(admin);
        evilDistributor.declareDividends(dividendAmount);

        // Malicious claim attempt of round 1 by initially claming round 0
        attacker.claimRound(0);

        assertTrue(attacker.attackAttempted()); // assert that attack has definitely been attempted
        assertTrue(evilDistributor.claimed(address(attacker), 0)); // assert that `attacker` received legitimately claimed dividends
        assertFalse(evilDistributor.claimed(address(attacker), 1)); // assert that `attacker` has not received maliciously claimed dividends
    }
}
