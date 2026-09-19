// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IComplianceValidator} from "./interfaces/IComplianceValidator.sol";

/**
 * @title PropertyToken
 * @author danushkka
 *
 * @notice A compliance-gated, ERC20Votes-based token representing fractional ownership of a
 * real-world property, issuable only to whitelisted holders up to a fixed maximum supply.
 *
 * @dev Holders are auto-delegated to themselves on first receipt so their historical balance
 * is checkpointed automatically, enabling snapshot-based dividend distribution without requiring
 * a separate delegate() transaction.
 */
contract PropertyToken is ERC20, ERC20Votes, AccessControl {
    //////////////////////////////////////
    ////////// STATE VARIABLES ///////////
    //////////////////////////////////////

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// @notice maximum supply of a token.
    uint256 public immutable i_maxSupply;

    /// @notice A comliance validator that controls transactions between accounts.
    IComplianceValidator public validator;

    //////////////////////////////////////
    /////////////// EVENTS ///////////////
    //////////////////////////////////////

    /**
     * @notice Is thrown when a new compliance validator has been updated.
     *
     * @param validator Compliance validator that has been updated.
     */
    event ComplianceValidatorUpdated(address indexed validator);

    //////////////////////////////////////
    /////////////// ERRORS ///////////////
    //////////////////////////////////////

    error PropertyToken__MaxSupplyCannotBeZero();

    /**
     * @notice Is thrown when a number of minted tokens exceeds the maximum allowed supply.
     *
     * @param requested An amount of tokens to potentially be minted.
     * @param maxSupply A maximum amount of tokens allowed to be minted overall.
     */
    error PropertyToken__MaxSupplyExceeded(uint256 requested, uint256 maxSupply);

    /**
     * @notice Is thrown when a compliance validator has blocked the transaction.
     *
     * @dev See {IComplianceValidator} for more information.
     *
     * @param from Sender of the transaction.
     * @param to Recipient of the transaction.
     * @param amount An amount to be sent.
     */
    error PropertyToken__TransferNotCompliant(address from, address to, uint256 amount);

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    constructor(string memory name, string memory symbol, address admin, address validatorAddress, uint256 maxSupply)
        ERC20(name, symbol)
        EIP712(name, "1.0")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, admin);
        validator = IComplianceValidator(validatorAddress);

        if (maxSupply == 0) revert PropertyToken__MaxSupplyCannotBeZero();
        i_maxSupply = maxSupply;
    }

    //////////////////////////////////////
    ///////////// FUNCTIONS //////////////
    //////////////////////////////////////

    /**
     * @notice Mints the token `amount` to `to`, only ISSUER_ROLE can mint.
     *
     * @param to Recipient of the tokens.
     * @param amount An amount to be minted.
     */
    function mint(address to, uint256 amount) public onlyRole(ISSUER_ROLE) {
        uint256 newSupply = totalSupply() + amount;
        if (newSupply > i_maxSupply) revert PropertyToken__MaxSupplyExceeded(newSupply, i_maxSupply);
        _mint(to, amount);
    }

    /**
     * @notice Allows contract or EOA with DEFAULT_ADMIN_ROLE to set a new validator.
     *
     * @dev Emits an event if successful.
     *
     * @param newValidator Address of the new validator.
     */
    function setComplianceValidator(address newValidator) public onlyRole(DEFAULT_ADMIN_ROLE) {
        validator = IComplianceValidator(newValidator);
        emit ComplianceValidatorUpdated(newValidator);
    }

    /**
     * @notice Enforces comliance before any balance change (mint, burn, transfer).
     *
     * @dev Implements an additional compliance check.
     * @dev Overrides both ERC20's and ERC20Votes' _update.
     *
     * @param from Sender address.
     * @param to Recipient address.
     * @param amount An amount to be sent.
     */
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        if (!validator.canTransfer(from, to, amount)) {
            revert PropertyToken__TransferNotCompliant(from, to, amount);
        }

        // Auto-delegate new holders to themselves so their balance is checkpointed
        // without requiring a separate delegate() transaction.
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
        super._update(from, to, amount);
    }

    /// @notice Returns max supply of the token.
    function getMaxSupply() external view returns (uint256) {
        return i_maxSupply;
    }
}
