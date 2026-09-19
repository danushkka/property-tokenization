// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RevenueVault} from "./RevenueVault.sol";

/**
 * @title DividendDistributor
 * @author danushkka
 *
 * @notice Tracks dividend rounds and lets token holders claim their proportional share,
 * based on their token balance at the round's snapshot block (not current balance).
 */
contract DividendDistributor is AccessControl, ReentrancyGuard {
    //////////////////////////////////////
    /////////////// TYPES ////////////////
    //////////////////////////////////////

    struct DividendRound {
        uint256 snapshotBlock;
        uint256 totalAmount;
        uint256 totalSupplyAtSnapshot;
    }

    //////////////////////////////////////
    ////////// STATE VARIABLES ///////////
    //////////////////////////////////////

    bytes32 public constant DIVIDEND_MANAGER_ROLE = keccak256("DIVIDEND_MANAGER_ROLE");
    uint256 public constant MIN_PROTECTED_HOLDING = 1e18; // guarantee any holder owning >= 1 whole token gets paid something.
    uint256 public s_totalOwed;

    /// @notice The token whose historical balances determine dividend shares.
    IVotes public immutable i_token;

    /// @notice The vault holding the actual stablecoin funds to be released on claim.
    RevenueVault public immutable i_vault;

    /// @notice An array of all declared rounds.
    DividendRound[] public rounds;

    /**
     * @notice Tracks whether `account` has already claimed dividends of a specific round.
     *
     * @dev Keyed as [account][roundId], retruns `true` if claimed.
     */
    mapping(address account => mapping(uint256 roundId => bool hasClaimed)) public claimed;

    //////////////////////////////////////
    /////////////// EVENTS ///////////////
    //////////////////////////////////////

    /**
     * @notice Is thrown when a new dividend round has been declared.
     *
     * @param roundId A number of the declared round.
     * @param snapshotBlock A block where the round has been declared.
     * @param totalAmount A total amount of dividends declared.
     * @param totalSupplyAtSnapshot A total supply of tokens in the block.
     */
    event DividendDeclared(
        uint256 indexed roundId, uint256 snapshotBlock, uint256 totalAmount, uint256 totalSupplyAtSnapshot
    );

    /**
     * @notice Is thrown when a holder has claimed their dividends on a specific round.
     *
     * @param roundId A number of the claimed round.
     * @param account A holder that has claimed the dividends.
     * @param amount An amount of dividends claimed.
     */
    event DividendClaimed(uint256 indexed roundId, address account, uint256 amount);

    //////////////////////////////////////
    /////////////// ERRORS ///////////////
    //////////////////////////////////////

    error DividendDistributor__ZeroAddress();
    error DividendDistributor__ZeroAmount();

    /**
     * @notice Is thrown if there was no token supply on the block.
     *
     * @param snapshotBlock A number of the block to be checked.
     */
    error DividendDistributor__NoSupplyAtSnapshot(uint256 snapshotBlock);

    /**
     * @notice Id thrown when an amount of dividens is smaller than the minimal amount required.
     *
     * @param amount A declared amount of dividends.
     * @param minRequired The minimal amount of dividends required.
     */
    error DividendDistributor__DividendTooSmallForSupply(uint256 amount, uint256 minRequired);

    /**
     * @notice Is thrown when there is not enough stablecoins in the vault to pay dividends.
     *
     * @param available The current balance of the vault.
     * @param required The minimal amount required to pay dividends.
     */
    error DividendDistributor__InsufficientVaultBalance(uint256 available, uint256 required);

    /// @notice Is thrown when `roundId` does not match the id's of declared rounds (e.g. that round has not yet been declared).
    error DividendDistributor__InvalidRound();

    error DividendDistributor__AlreadyClaimed();

    /// @notice Is thrwon when the caller's computed share is zero -
    /// either because they have no votes on snapshot, or the share has rounded down to zero.
    error DividendDistributor__NothingToClaim();

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    constructor(address tokenAddress, address vaultAddress, address admin) {
        if (tokenAddress == address(0) || vaultAddress == address(0)) revert DividendDistributor__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DIVIDEND_MANAGER_ROLE, admin);

        i_token = IVotes(tokenAddress);
        i_vault = RevenueVault(vaultAddress);
    }

    //////////////////////////////////////
    ///////////// FUNCTIONS //////////////
    //////////////////////////////////////

    /**
     * @notice Declares a new dividend round for `amount`, snapshotting eligibility as of the previous block.
     *
     * @dev Uses `block.number - 1` because IVotes' historical lookups only accept past blocks -
     * the current block's checkpoint isn't considered "finalized" yet.
     *
     * Assumes that `amount` has already been deposited.
     */
    function declareDividends(uint256 amount) external onlyRole(DIVIDEND_MANAGER_ROLE) {
        if (amount == 0) revert DividendDistributor__ZeroAmount();

        uint256 snapshotBlock = block.number - 1;
        uint256 supply = i_token.getPastTotalSupply(snapshotBlock);
        if (supply == 0) revert DividendDistributor__NoSupplyAtSnapshot(snapshotBlock);

        uint256 minRequired = supply / MIN_PROTECTED_HOLDING;
        if (amount < minRequired) revert DividendDistributor__DividendTooSmallForSupply(amount, minRequired);

        uint256 available = i_vault.getTotalRevenue();
        uint256 required = s_totalOwed + amount;
        if (available < required) revert DividendDistributor__InsufficientVaultBalance(available, required);

        s_totalOwed += amount;
        rounds.push(DividendRound({snapshotBlock: snapshotBlock, totalAmount: amount, totalSupplyAtSnapshot: supply}));
        emit DividendDeclared(rounds.length - 1, snapshotBlock, amount, supply);
    }

    /**
     * @notice Claims the caller's proportional share of a specific dividend round.
     *
     * WARNING: Historical eligibility persists even after a holder's current balance changes.
     * For example, even if a holder sells all of their tokens *after* the dividend declaration,
     * they will still be able to claim all the dividends.
     *
     * @param roundId The round to claim from.
     */
    function claim(uint256 roundId) external nonReentrant {
        if (roundId >= rounds.length) revert DividendDistributor__InvalidRound();
        if (claimed[msg.sender][roundId]) revert DividendDistributor__AlreadyClaimed();

        DividendRound memory round = rounds[roundId];

        uint256 votes = i_token.getPastVotes(msg.sender, round.snapshotBlock);
        uint256 owed = Math.mulDiv(votes, round.totalAmount, round.totalSupplyAtSnapshot);
        if (owed == 0) revert DividendDistributor__NothingToClaim();

        claimed[msg.sender][roundId] = true;
        s_totalOwed -= owed;
        emit DividendClaimed(roundId, msg.sender, owed);

        i_vault.withdrawTo(msg.sender, owed);
    }

    /**
     * @notice Returns the minimum dividend amount that would be accepted right now,
     * based on total supply at the most recently finalized block.
     */
    function getMinDividendAmount() external view returns (uint256) {
        uint256 supply = i_token.getPastTotalSupply(block.number - 1);
        return supply / MIN_PROTECTED_HOLDING;
    }

    /**
     * @notice Returns the total number of dividend rounds declared so far.
     */
    function getRoundCount() external view returns (uint256) {
        return rounds.length;
    }

    /**
     * @notice Returns `true` if `account` has claimed dividends of `roundId`.
     *
     * @param account an account to get claimed status of.
     * @param roundId an id of the round to get claimed status from.
     */
    function getClaimedStatus(address account, uint256 roundId) external view returns (bool) {
        return claimed[account][roundId];
    }
}
