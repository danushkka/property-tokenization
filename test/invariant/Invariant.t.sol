// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {WhitelistValidator} from "../../src/WhitelistValidator.sol";
import {PropertyToken} from "../../src/PropertyToken.sol";
import {PropertyIssuance} from "../../src/PropertyIssuance.sol";
import {RevenueVault} from "../../src/RevenueVault.sol";
import {DividendDistributor} from "../../src/DividendDistributor.sol";

import {Handler} from "./Handler.sol";

contract ProtocolInvariant is StdInvariant, Test {
    ERC20Mock usdc;
    WhitelistValidator validator;
    PropertyToken token;
    PropertyIssuance issuer;
    RevenueVault vault;
    DividendDistributor distributor;

    Handler handler;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new ERC20Mock();
        validator = new WhitelistValidator(admin);
        token = new PropertyToken("PropToken", "PPT", admin, address(validator), 1_000_000e18);
        issuer = new PropertyIssuance(address(token), address(usdc), treasury, admin, 10e6, 100_000e18);
        vault = new RevenueVault(admin, address(usdc));
        distributor = new DividendDistributor(address(token), address(vault), admin);

        vm.startPrank(admin);
        token.grantRole(token.ISSUER_ROLE(), address(issuer));
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));
        vm.stopPrank();

        handler = new Handler(usdc, validator, token, issuer, vault, distributor, admin);
        targetContract(address(handler));
    }

    function invariant_SupplyNeverExceedsCap() public view {
        assertLe(token.totalSupply(), token.getMaxSupply());
    }

    function invariant_VaultCoversObligations() public view {
        assertEq(usdc.balanceOf(address(vault)), distributor.s_totalOwed());
    }

    function invariant_TotalOwedMatchesLedger() public view {
        assertEq(distributor.s_totalOwed(), handler.ghost_declared() - handler.ghost_claimed());
    }

    function invariant_RoundPayoutsNeverExceedRoundTotal() public view {
        for (uint256 id; id < distributor.getRoundCount(); id++) {
            (, uint256 total,) = distributor.rounds(id);
            assertLe(handler.ghost_paidInRound(id), total);
        }
    }

    function invariant_NobodyDelegatesAway() public view {
        for (uint256 i; i < handler.actorsCount(); i++) {
            address holder = handler.actors(i);
            if (token.balanceOf(holder) > 0) assertEq(token.delegates(holder), holder);
        }
    }
}
