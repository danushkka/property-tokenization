// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    function invariant_NobodyOperatesIfNotWhitelisted() public view {
        assertEq(handler.ghost_breaches(), 0);
    }

    function invariant_RoundPayoutsNeverExceedRoundTotal() public view {
        for (uint256 id; id < distributor.getRoundCount(); id++) {
            (, uint256 total,) = distributor.rounds(id);
            assertLe(handler.ghost_paidInRound(id), total);
        }
    }

    function invariant_CostRoundsWithinMinRange() public view {
        assertLe(handler.ghost_underpaid(), 1);
    }

    function invariant_NobodyDelegatesAway() public view {
        for (uint256 i; i < handler.actorsCount(); i++) {
            address holder = handler.actors(i);
            if (token.balanceOf(holder) > 0) assertEq(token.delegates(holder), holder);
        }
    }

    //////////////////////////////////////
    ///////// VOTES CONSERVATION /////////
    //////////////////////////////////////

    /// @notice The sum of all actors' current votes equals total supply.
    /// @dev Relies on the handler only minting to actors and every holder
    ///      self-delegating (PropertyToken auto-delegates on first receive).
    function invariant_VotesSumEqualsSupply() public view {
        if (block.number == 0) return;
        uint256 sum;
        for (uint256 i; i < handler.actorsCount(); i++) {
            sum += token.getPastVotes(handler.actors(i), block.number - 1);
        }
        assertEq(sum, token.getPastTotalSupply(block.number - 1));
    }

    /// @notice Every holder with a positive balance has positive voting power.
    function invariant_HoldersHaveVotes() public view {
        if (block.number == 0) return;
        for (uint256 i; i < handler.actorsCount(); i++) {
            address actor = handler.actors(i);
            if (token.balanceOf(actor) > 0) {
                assertGt(token.getPastVotes(actor, block.number - 1), 0);
            }
        }
    }

    /// @notice At each round's snapshot, the sum of actors' votes equals the stored supply.
    /// @dev Requires a public getter for round.snapshotBlock, or unpack the full struct.
    ///      If your `rounds` public mapping does not expose `snapshotBlock`, replace
    ///      the unpacking below with a dedicated getter.
    function invariant_RoundVotesMatchRoundSupply() public view {
        uint256 count = distributor.getRoundCount();
        for (uint256 id; id < count; id++) {
            uint256 snapshotBlock = handler.ghost_roundSnapshot(id);
            uint256 totalSupplyAtSnapshot = handler.ghost_roundSupply(id);

            uint256 sum;
            for (uint256 i; i < handler.actorsCount(); i++) {
                sum += token.getPastVotes(handler.actors(i), snapshotBlock);
            }
            assertEq(sum, totalSupplyAtSnapshot);
        }
    }

    //////////////////////////////////////
    ///////// TOKEN CONSERVATION /////////
    //////////////////////////////////////

    /// @notice Every minted token sits in an actor's balance (no burn function exists).
    function invariant_SumOfActorBalancesEqualsTotalSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorsCount(); i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// @notice Every holder with a balance has non-zero voting power.
    /// @dev Overlaps with invariant_HoldersHaveVotes; kept as an explicit
    ///      "no silent exclusion" check.

    //////////////////////////////////////
    ///////// USDC CONSERVATION //////////
    //////////////////////////////////////

    /// @notice Total USDC supply equals the ghost-tracked minted amount.
    function invariant_UsdcConservation() public view {
        assertEq(usdc.totalSupply(), handler.ghost_usdcMinted());
    }

    /// @notice Known USDC holders' balances sum to the minted total.
    function invariant_UsdcBalancesSumToMinted() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorsCount(); i++) {
            sum += usdc.balanceOf(handler.actors(i));
        }
        sum += usdc.balanceOf(admin);
        sum += usdc.balanceOf(treasury);
        sum += usdc.balanceOf(address(vault));
        sum += usdc.balanceOf(address(issuer));
        sum += usdc.balanceOf(address(distributor));
        assertEq(sum, handler.ghost_usdcMinted());
    }

    //////////////////////////////////////
    /////////////// CLAIM ////////////////
    //////////////////////////////////////

    /// @notice Each successful claim paid exactly the formula-owed amount.
    function invariant_ClaimPaysExactlyOwed() public view {
        assertEq(handler.ghost_expectedClaim(), handler.ghost_claimed());
    }

    /// @notice No actor has ever claimed the same round twice.
    function invariant_NoDoubleClaim() public view {
        uint256 rounds = distributor.getRoundCount();
        for (uint256 i; i < handler.actorsCount(); i++) {
            address actor = handler.actors(i);
            for (uint256 id; id < rounds; id++) {
                uint256 ghostCount = handler.ghost_claimCount(actor, id);
                assertLe(ghostCount, 1);
            }
        }
    }

    /// @notice On-chain `claimed` mapping agrees with the ghost count.
    function invariant_ClaimedMappingMatchesGhost() public view {
        uint256 rounds = distributor.getRoundCount();
        for (uint256 i; i < handler.actorsCount(); i++) {
            address actor = handler.actors(i);
            for (uint256 id; id < rounds; id++) {
                uint256 ghostCount = handler.ghost_claimCount(actor, id);
                bool onChain = distributor.claimed(actor, id);
                assertEq(onChain, ghostCount > 0);
            }
        }
    }

    //////////////////////////////////////
    ////////// ROUND ACCOUNTING //////////
    //////////////////////////////////////

    /// @notice The sum of round amounts equals the ghost-tracked declared total.
    function invariant_SumOfRoundAmountsEqualsDeclared() public view {
        uint256 sum;
        for (uint256 id; id < distributor.getRoundCount(); id++) {
            (, uint256 totalAmount,) = distributor.rounds(id);
            sum += totalAmount;
        }
        assertEq(sum, handler.ghost_declared());
    }

    /// @notice The sum of per-round payouts equals the ghost-tracked claimed total.
    function invariant_SumOfRoundPayoutsEqualsClaimed() public view {
        uint256 sum;
        uint256 rounds = distributor.getRoundCount();
        for (uint256 id; id < rounds; id++) {
            sum += handler.ghost_paidInRound(id);
        }
        assertEq(sum, handler.ghost_claimed());
    }

    /// @notice Every round has a valid snapshot block, positive supply, and meets the min.
    function invariant_RoundSnapshotsAreValid() public view {
        uint256 rounds = distributor.getRoundCount();
        for (uint256 id; id < rounds; id++) {
            // uint256 snapshotBlock = handler.ghost_roundSnapshot(id);
            // uint256 totalSupplyAtSnapshot = handler.ghost_roundSupply(id);
            // (, uint256 totalAmount,) = distributor.rounds(id);
            (uint256 snapshotBlock, uint256 totalAmount, uint256 totalSupplyAtSnapshot) = distributor.rounds(id);

            assertLt(snapshotBlock, block.number);
            assertGt(totalSupplyAtSnapshot, 0);
            assertEq(totalSupplyAtSnapshot, token.getPastTotalSupply(snapshotBlock));
            assertGe(totalAmount, totalSupplyAtSnapshot / 1e18);
        }
    }

    //////////////////////////////////////
    /////////////// FUNDS ////////////////
    //////////////////////////////////////

    /// @notice The issuer never holds USDC (purchase proceeds go straight to treasury).
    function invariant_IssuerHoldsNoUsdc() public view {
        assertEq(usdc.balanceOf(address(issuer)), 0);
    }

    /// @notice The distributor never holds USDC (claims are paid from the vault).
    function invariant_DistributorHoldsNoUsdc() public view {
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    /// @notice Treasury holds exactly the sum of all purchase proceeds.
    function invariant_TreasuryHoldsAllPurchaseProceeds() public view {
        assertEq(usdc.balanceOf(treasury), handler.ghost_totalCost());
    }

    /// @notice Vault balance equals ghost-tracked deposits minus claims.
    /// @dev Independent of s_totalOwed: catches drift in the distributor's ledger.
    function invariant_VaultBalanceMatchesDepositsMinusClaims() public view {
        assertEq(usdc.balanceOf(address(vault)), handler.ghost_totalDeposited() - handler.ghost_claimed());
    }

    //////////////////////////////////////
    ////////////// SAFETY ////////////////
    //////////////////////////////////////

    /// @notice The compliance validator is never zero (zero would brick transfers).
    function invariant_ValidatorIsNotZero() public view {
        assertTrue(address(token.validator()) != address(0));
    }

    /// @notice The token price is never zero.
    function invariant_PriceIsNotZero() public view {
        assertGt(issuer.s_pricePerToken(), 0);
    }

    /// @notice The minimum purchase cost never rounds to zero.
    function invariant_MinPurchaseCostIsAtLeastOneUnit() public view {
        uint256 minAmount = issuer.getMinPurchaseAmount();
        uint256 cost = Math.mulDiv(minAmount, issuer.s_pricePerToken(), 1e18);
        assertGe(cost, 1);
    }
}
