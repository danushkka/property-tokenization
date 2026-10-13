// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IComplianceValidator} from "./interfaces/IComplianceValidator.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title WhitelistValidator
 * @author danushkka
 *
 * @notice Compliance validator that allows COMPLIANCE_ADMIN_ROLE to add or remove holders
 * from a whitelist, used to regulate transactions between holders.
 *
 * @dev Enforced only at mint, burn, and transfer time via PropertyToken's compliance hook.
 *
 * It is NOT checked at dividend claim time - a holder's eligibility for a given round is
 * locked in at that round's snapshot block, and later whitelist removal does not retroactively
 * revoke a claim they already qualified for. See DividendDistributor's NatSpec for details.
 */
contract WhitelistValidator is IComplianceValidator, AccessControl {
    bytes32 public constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");

    mapping(address => bool) private s_whitelisted;

    event AddedToWhitelist(address indexed account);
    event RemovedFromWhitelist(address indexed account);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
    }

    /**
     * @notice Defines that `account` is whitelisted and can send or receive this token.
     *
     * @param account an account to be added to the White List.
     */
    function addToWhitelist(address account) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        s_whitelisted[account] = true;
        emit AddedToWhitelist(account);
    }

    /**
     * @notice Defines that `account` is no more whitelisted and can no longer send or receive the token.
     *
     * @param account an account to be removed from the Whitelist.
     */
    function removeFromWhitelist(address account) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        s_whitelisted[account] = false;
        emit RemovedFromWhitelist(account);
    }

    /**
     * @notice Checks if `account` was whitelisted.
     *
     * @param account an account to be checked on being whitelisted.
     *
     * @return True if `account` is whitelisted.
     */
    function isWhitelisted(address account) public view returns (bool) {
        return s_whitelisted[account];
    }

    /// @inheritdoc IComplianceValidator
    function canTransfer(
        address from,
        address to,
        uint256 /* amount */
    )
        external
        view
        override
        returns (bool)
    {
        // Mint: check if `to` is whitelisted (there is no sender)
        if (from == address(0)) {
            return s_whitelisted[to];
        }
        // Burn: check if `from` is whitelisted (there is no recipient)
        if (to == address(0)) {
            return s_whitelisted[from];
        }
        // Transfer: check if both parties are whitelisted
        return s_whitelisted[from] && s_whitelisted[to];
    }
}
