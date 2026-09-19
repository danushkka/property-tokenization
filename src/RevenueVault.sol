// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RevenueVault
 * @author danushkka
 *
 * @notice Holds a single accepted stablecoin as custody for a property's real-world income.
 *
 * Allows to deposit the custody into the vault, which is later to be distributed to holders
 * by the trusted distributor with DISTRIBUTOR_ROLE.
 *
 * @dev Deliberately "dumb" about accounting - it only knows how to receive and release funds.
 */
contract RevenueVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //////////////////////////////////////
    ////////// STATE VARIABLES ///////////
    //////////////////////////////////////

    bytes32 public DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    /// @notice The single stablecoin this vault accepts, fixed at deployment.
    IERC20 public immutable i_stablecoin;

    //////////////////////////////////////
    /////////////// EVENTS ///////////////
    //////////////////////////////////////

    event Deposited(address indexed from, uint256 amount);
    event WithdrawnTo(address indexed from, address indexed to, uint256 amount);

    //////////////////////////////////////
    /////////////// ERRORS ///////////////
    //////////////////////////////////////

    error RevenueVault__ZeroAddress();
    error RevenueVault__ZeroAmount();

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    constructor(address admin, address stablecoinAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPOSITOR_ROLE, admin);

        if (stablecoinAddress == address(0)) revert RevenueVault__ZeroAddress();
        i_stablecoin = IERC20(stablecoinAddress);
    }

    //////////////////////////////////////
    ///////////// FUNCTIONS //////////////
    //////////////////////////////////////

    /**
     * @notice Deposits stablecoin income into the vault, to later be distributed to token holders.
     *
     * @dev Caller must have approved this contract to spend `amount` beforehand.
     * @dev Emits an event if successful.
     *
     * @param amount The amount of stablecoin to deposit.
     */
    function deposit(uint256 amount) external onlyRole(DEPOSITOR_ROLE) {
        if (amount == 0) revert RevenueVault__ZeroAmount();

        emit Deposited(msg.sender, amount);
        i_stablecoin.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Releases funds to a specific recipient, callable only by the trusted DividendDistributor.
     *
     * @dev The vault does not decide *how much* any individual is owed - that logic lives entirely
     *      in whichever contract holds DISTRIBUTOR_ROLE. The vault only enforces *who* may withdraw.
     * @dev Emits an event if successful.
     *
     * @param recipient The address to receive the funds.
     * @param amount The amount to release.
     */
    function withdrawTo(address recipient, uint256 amount) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant {
        if (recipient == address(0)) revert RevenueVault__ZeroAddress();
        if (amount == 0) revert RevenueVault__ZeroAmount();

        emit WithdrawnTo(msg.sender, recipient, amount);
        i_stablecoin.safeTransfer(recipient, amount);
    }

    /// @notice Returns the vault's current stablecoin balance.
    function getTotalRevenue() public view returns (uint256) {
        return i_stablecoin.balanceOf(address(this));
    }
}
