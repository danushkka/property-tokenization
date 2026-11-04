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
    uint256 public ghost_underpaid; // keep track of the max cost rounding
    uint256 public ghost_usdcMinted; // total USDC minted by the handler
    uint256 public ghost_totalCost; // cumulative cost paid by buyers
    uint256 public ghost_totalDeposited; // cumulative USDC deposited into the vault
    uint256 public ghost_expectedClaim; // cumulative expected claim amounts (sum of owed)
    uint256 public ghost_breaches; // total attempts of unauthorized actions

    mapping(address => mapping(uint256 => uint256)) public ghost_claimCount;

    mapping(uint256 => uint256) public ghost_roundSnapshot; // roundId => snapshotBlock
    mapping(uint256 => uint256) public ghost_roundSupply; // roundId => totalSupplyAtSnapshot

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

    function setComplianceValidator(uint256 seed) external {
        // Fuzz between a valid actor address and address(0)
        address newValidator = seed % 10 == 0 ? address(0) : _actors(seed % actors.length);

        vm.prank(admin);
        try token.setComplianceValidator(newValidator) {
        // If the contract allows it, the invariant must catch the brick scenario
        }
            catch {
            // If the contract reverts on zero, that's also fine
        }
    }

    function buy(uint256 seed, uint256 amount) external {
        address actor = _actors(seed);
        if (!validator.isWhitelisted(actor)) return;

        uint256 minAmount = issuer.getMinPurchaseAmount();
        uint256 maxAmount = token.getMaxSupply() - token.totalSupply();
        amount = bound(amount, minAmount, maxAmount);
        uint256 cost = Math.mulDiv(amount, issuer.s_pricePerToken(), issuer.TOKEN_PRECISION());

        uint256 usdcBalanceBefore = usdc.balanceOf(actor);
        _mintUsdc(actor, cost);
        vm.startPrank(actor);
        usdc.approve(address(issuer), cost);
        issuer.purchase(amount);
        vm.stopPrank();
        uint256 usdcBalanceAfter = usdc.balanceOf(actor);
        ghost_underpaid = Math.max(usdcBalanceAfter - usdcBalanceBefore, 1);

        ghost_totalCost += cost;

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

    function declareDividend(uint256 amount) external {
        vm.roll(block.number + 1);

        if (token.getPastTotalSupply(block.number - 1) == 0) return;

        uint256 minAmount = Math.max(distributor.getMinDividendAmount(), 1);
        amount = bound(amount, minAmount, Math.max(minAmount, 1_000_000e6));

        _mintUsdc(admin, amount);
        vm.startPrank(admin);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        distributor.declareDividends(amount);
        vm.stopPrank();

        ghost_declared += amount;
        ghost_totalDeposited += amount;

        uint256 roundId = distributor.getRoundCount() - 1;
        // Snapshot is block.number - 1 per DividendDistributor.declareDividends.
        // Store the same values so the invariant can recompute votes.
        ghost_roundSnapshot[roundId] = block.number - 1;
        ghost_roundSupply[roundId] = token.getPastTotalSupply(block.number - 1);
    }

    function claimDividend(uint256 seed, uint256 roundId) external {
        uint256 rounds = distributor.getRoundCount();
        if (rounds == 0) return;

        roundId = bound(roundId, 0, rounds - 1);
        address actor = _actors(seed);
        if (distributor.getClaimedStatus(actor, roundId)) return;

        (, uint256 totalAmount,) = distributor.rounds(roundId);
        uint256 votes = token.getPastVotes(actor, ghost_roundSnapshot[roundId]);
        if (votes == 0) return;

        uint256 owed = Math.mulDiv(votes, totalAmount, ghost_roundSupply[roundId]);

        uint256 balanceBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        try distributor.claim(roundId) {
            uint256 received = usdc.balanceOf(actor) - balanceBefore;
            ghost_claimCount[actor][roundId]++;
            ghost_paidInRound[roundId] += owed;
            ghost_claimed += owed;
            ghost_expectedClaim += received;
        } catch {} // A legitimate revert (e.g. NothingToClaim)
    }

    function tryDelegate(uint256 actorSeed, uint256 delegateeSeed) external {
        address actor = _actors(actorSeed);
        address delegatee = _actors(delegateeSeed);

        vm.prank(actor);
        try token.delegate(delegatee) {} catch {}
    }

    function tryZeroValidator() external {
        vm.prank(admin);
        try token.setComplianceValidator(address(0)) {} catch {}
    }

    function tryUnauthorizedBuy(uint256 seed) external {
        address buyer = _actors(seed);
        if (validator.isWhitelisted(buyer)) return;

        uint256 amount = issuer.getMinPurchaseAmount();
        uint256 cost = Math.mulDiv(amount, issuer.s_pricePerToken(), issuer.TOKEN_PRECISION());
        _mintUsdc(buyer, cost);

        vm.startPrank(buyer);
        usdc.approve(address(issuer), cost);
        try issuer.purchase(amount) {
            ghost_breaches++;
        } catch {}
        vm.stopPrank();
    }

    function tryUnauthorizedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actors(fromSeed);
        address to = _actors(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0 || (validator.isWhitelisted(from) && validator.isWhitelisted(to))) return;

        amount = bound(amount, 1, balance);
        vm.prank(from);
        try token.transfer(to, amount) {
            ghost_breaches++;
        } catch {}
    }

    function _mintUsdc(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        ghost_usdcMinted += amount;
    }
}
