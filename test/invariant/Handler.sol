// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {WhitelistValidator} from "../../src/WhitelistValidator.sol";
import {PropertyToken} from "../../src/PropertyToken.sol";
import {PropertyIssuance} from "../../src/PropertyIssuance.sol";
import {RevenueVault} from "../../src/RevenueVault.sol";
import {DividendDistributor} from "../../src/DividendDistributor.sol";

contract Handler is Test {
    ERC20Mock public immutable usdc;
    WhitelistValidator public immutable validator;
    PropertyToken public immutable token;
    PropertyIssuance public immutable issuer;
    RevenueVault public immutable vault;
    DividendDistributor public immutable distributor;
    address public immutable admin;

    address[] public actors;

    uint256 public ghost_declared; // keep track of how much has been declared
    uint256 public ghost_claimed; // keep track of how much has been claimed

    mapping(uint256 roundId => uint256 paid) public ghost_paidInRound; // keep track of how puch has been paid in round

    constructor(
        ERC20Mock _usdc,
        WhitelistValidator _validator,
        PropertyToken _token,
        PropertyIssuance _issuer,
        RevenueVault _vault,
        DividendDistributor _distributor,
        address _admin
    ) {
        usdc = _usdc;
        validator = _validator;
        token = _token;
        issuer = _issuer;
        vault = _vault;
        distributor = _distributor;
        admin = _admin;

        for (uint256 i; i < 4; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function _actors(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    function setWhitelisted(uint256 seed, bool status) external {
        address actor = _actors(seed);
        vm.startPrank(admin);
        if (status) validator.addToWhitelist(actor);
        else validator.removeFromWhitelist(actor);
        vm.stopPrank();
    }

    function buy(uint256 seed, uint256 amount) external {
        address actor = _actors(seed);
        if (!validator.isWhitelisted(actor)) return;

        uint256 minAmount = issuer.getMinPurchaseAmount();
        uint256 maxAmount = token.getMaxSupply() - token.totalSupply();
        amount = bound(amount, minAmount, maxAmount);
        uint256 cost = Math.mulDiv(amount, issuer.s_pricePerToken(), issuer.TOKEN_PRECISION());

        usdc.mint(actor, cost);
        vm.startPrank(actor);
        usdc.approve(address(issuer), cost);
        issuer.purchase(amount);
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actors(fromSeed);
        address to = _actors(toSeed);
        uint256 balance = token.balanceOf(from);
        if (from == to || balance == 0) return;
        if (!validator.isWhitelisted(from) || !validator.isWhitelisted(to)) return;

        amount = bound(amount, 1, balance);
        vm.prank(from);
        token.transfer(to, amount);

        vm.roll(block.number + 1);
    }

    function tryDelegate(uint256 actorSeed, uint256 delegateeSeed) external {
        address actor = _actors(actorSeed);
        address delegatee = _actors(delegateeSeed);

        vm.prank(actor);
        try token.delegate(delegatee) {} catch {}
    }

    function declareDividend(uint256 amount) external {
        vm.roll(block.number + 1);

        if (token.getPastTotalSupply(block.number - 1) == 0) return;

        uint256 minAmount = Math.max(distributor.getMinDividendAmount(), 1);
        amount = bound(amount, minAmount, Math.max(minAmount, 1_000_000e6));

        usdc.mint(admin, amount);
        vm.startPrank(admin);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        ghost_declared += amount;
    }

    function claimDividend(uint256 seed, uint256 roundId) external {
        uint256 rounds = distributor.getRoundCount();
        if (rounds == 0) return;

        roundId = bound(roundId, 0, rounds - 1);
        address actor = _actors(seed);
        if (distributor.getClaimedStatus(actor, roundId)) return;

        uint256 balanceBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        try distributor.claim(roundId) {
            uint256 paid = usdc.balanceOf(actor) - balanceBefore;
            ghost_claimed += paid;
            ghost_paidInRound[roundId] += paid;
        } catch {} // A legitimate revert (e.g. NothingToClaim)
    }
}
