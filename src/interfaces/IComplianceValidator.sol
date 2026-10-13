// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IComplianceValidator {
    /**
     * @notice Checks whether a transfer between two parties is compliant with this token's rules
     * @dev Called by the token's `_update` hook on every transfer, mint, and burn
     * `from == address(0)` signals a mint; `to == address(0)` signals a burn
     *
     * @param from The sender's address (zero address if minting)
     * @param to The recipient's address (zero address if burning)
     * @param amount The amount being transferred, in the token's smallest unit
     * @return True if the transfer is permitted, false otherwise
     */
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);
}
