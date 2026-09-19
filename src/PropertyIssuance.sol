// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {console2} from "forge-std/console2.sol";

import {PropertyToken} from "./PropertyToken.sol";

/**
 * @title PropertyIssuance
 * @author danushkka
 *
 * @notice Issues newly minted Property Tokens to whitelisted buyers after they purchased,
 * all the funds go directly to a separate treasury address.
 *
 * Allows to update the price either via deviation check by the holder of PRICE_ORACLE_ROLE
 * or via a forced update, if the new price exceeds the previous one by more than 5%.
 *
 * @dev Holds ISSUER_ROLE on Property Token. Compliance and max-supply enforcement are not duplicated here,
 * they are already governed by the PropertyToken.mint() itself.
 */
contract PropertyIssuance is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //////////////////////////////////////
    ////////// STATE VARIABLES ///////////
    //////////////////////////////////////

    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");
    uint256 public constant MAX_INSTANT_DEVIATION_BPS = 500; // 500 basis points == 5%
    uint256 public constant BPS_DENOMINATOR = 10_000; // 10_000 basis points == 100%
    uint256 public constant TOKEN_PRECISION = 1e18;
    uint256 public constant STABLECOIN_PRECISION = 1e6;

    /// @notice Token that represents a RWA.
    PropertyToken public immutable i_token;

    /// @notice Stablecoin that is used to pay for tokens.
    IERC20 public immutable i_stablecoin;

    /// @notice Address that stores all stablecoins received from holders.
    address public immutable i_treasury;

    /// @notice Max amount of tokens to be purchased during one attempt.
    uint256 public immutable i_maxPurchasePerTx;

    /// @notice Price per whole token (1e18 units of Property Token) in the stablecoin's smallest unit (usually 1e6).
    uint256 public s_pricePerToken;

    //////////////////////////////////////
    /////////////// EVENTS ///////////////
    //////////////////////////////////////

    /**
     * @notice Is emitted when a purchase has been completed.
     *
     * @param buyer An address of the holder who purchased tokens.
     * @param tokenAmount An amount of purchased tokens.
     * @param cost Total amount of stablecoins to be paid for tokens.
     */
    event Purchased(address indexed buyer, uint256 tokenAmount, uint256 cost);

    /**
     * @notice Is emitted when a price has been updated.
     *
     * @param oldPrice A price before the update.
     * @param newPrice The new updated price.
     * @param wasForced Whether the price was updated forcefully.
     * `false` if updated via `updatePrice()`, `true` if updated via `forceUpdatePrice()`.
     */
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, bool wasForced);

    //////////////////////////////////////
    /////////////// ERRORS ///////////////
    //////////////////////////////////////

    error PropertyIssuance__ZeroAddress();
    error PropertyIssuance__ZeroAmount();

    /**
     * @notice Is thrown when a purchase exceeds the defined purchase limit.
     *
     * @param required An amount the buyer is trying to purchase.
     * @param maxPurchasePerTx A purchase limit for a single transaction (in token's 1e18 units).
     */
    error PropertyIssuance__ExceedsMaxPurchasePerTx(uint256 required, uint256 maxPurchasePerTx);

    error PropertyIssuance__CostRoundsToZero();
    error PropertyIssuance__ZeroPrice();

    /**
     * @notice Thrown when the new price has deviated too much from the previous one.
     *
     * @param attempted The new price attempted to be set.
     * @param maxAllowedDeviationBps The defined limit of the price deviation in bps (e.g. 500 for 5%).
     */
    error PropertyIssuance__PriceDeviationTooLarge(uint256 attempted, uint256 maxAllowedDeviationBps);

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    constructor(
        address tokenAddress,
        address stablecoinAddress,
        address treasury,
        address admin,
        uint256 initialPricePerToken,
        uint256 maxPurchasePerTx
    ) {
        if (tokenAddress == address(0) || stablecoinAddress == address(0) || treasury == address(0)) {
            revert PropertyIssuance__ZeroAddress();
        }
        if (initialPricePerToken == 0 || maxPurchasePerTx == 0) revert PropertyIssuance__ZeroAmount();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PRICE_ORACLE_ROLE, admin);

        i_token = PropertyToken(tokenAddress);
        i_stablecoin = IERC20(stablecoinAddress);
        i_treasury = treasury;
        s_pricePerToken = initialPricePerToken;
        i_maxPurchasePerTx = maxPurchasePerTx;
    }

    //////////////////////////////////////
    ///////////// FUNCTIONS //////////////
    //////////////////////////////////////

    /**
     * @notice Purchases `tokenAmount` at the last `s_pricePerToken`, paid in accepted stablecoin.
     *
     * @dev Reverts atomically if the buyer is not whitelisted or the purchase would exceed max supply.
     * No funds will be moved unless the mint itself suceeds.
     * @dev Emits an event if successful.
     *
     * @param tokenAmount amount of token to be purchased.
     */
    function purchase(uint256 tokenAmount) external nonReentrant {
        if (tokenAmount == 0) revert PropertyIssuance__ZeroAmount();
        if (tokenAmount > i_maxPurchasePerTx) {
            revert PropertyIssuance__ExceedsMaxPurchasePerTx(tokenAmount, i_maxPurchasePerTx);
        }

        uint256 cost = Math.mulDiv(tokenAmount, s_pricePerToken, TOKEN_PRECISION);
        if (cost == 0) revert PropertyIssuance__CostRoundsToZero();

        emit Purchased(msg.sender, tokenAmount, cost);

        i_stablecoin.safeTransferFrom(msg.sender, i_treasury, cost);
        i_token.mint(msg.sender, tokenAmount); // reverts if buyer is not whitelisted or exceeds max supply
    }

    /**
     * @notice Updates the price of one token instantly, if it does not exceed 5% deviation to the previous price.
     * Designed to be used by default with no additional cooldown period.
     *
     * @dev Emits an event if successful.
     *
     * @param newPrice New price to be set.
     */
    function updatePrice(uint256 newPrice) external onlyRole(PRICE_ORACLE_ROLE) {
        if (newPrice == 0) revert PropertyIssuance__ZeroPrice();

        uint256 oldPrice = s_pricePerToken;
        uint256 allowedDeviation = Math.mulDiv(oldPrice, MAX_INSTANT_DEVIATION_BPS, BPS_DENOMINATOR); // should be within 5%
        uint256 deviation = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;

        if (deviation > allowedDeviation) {
            revert PropertyIssuance__PriceDeviationTooLarge(deviation, allowedDeviation);
        }

        s_pricePerToken = newPrice;
        emit PriceUpdated(oldPrice, newPrice, false);
    }

    /**
     * @notice Updates the price of one token manually, by design if `updatePrice()` reverted due to exceeding 5% deviation.
     * @notice Passes no deviation check.
     *
     * @dev Sets a delay before executing, since Timelock Controller holds DEFAULT_ADMIN_ROLE.
     * @dev Emits an event if successful.
     *
     * @param newPrice New price to be set.
     */
    function forceUpdatePrice(uint256 newPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newPrice == 0) revert PropertyIssuance__ZeroPrice();

        uint256 oldPrice = s_pricePerToken;
        s_pricePerToken = newPrice;
        emit PriceUpdated(oldPrice, newPrice, true);
    }

    /// @notice Returns the minimun token amount to be purchased without the cost rounding to zero
    function getMinPurchaseAmount() external view returns (uint256) {
        uint256 price = s_pricePerToken;
        return Math.ceilDiv(TOKEN_PRECISION, price);
    }
}
