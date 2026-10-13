// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title ReentrancyExploration
 *
 * @notice An educational contract that simuates a reentrancy attempt to prove a trust boundary
 * in Tokenization project.
 */

interface IReentrancyCallback {
    function onTokensReceived() external;
}

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Simulates a hook-style token (like ERC-777) that notifies the recipient
 * on every transfer — used only to test whether nonReentrant actually protects
 * against a stablecoin integration that behaves unlike a plain ERC-20.
 */
contract MaliciousReentrantToken is ERC20 {
    constructor() ERC20("Evil Token", "EVIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to.code.length > 0) {
            try IReentrancyCallback(to).onTokensReceived() {} catch {}
        }
    }
}

import {DividendDistributor} from "../../src/DividendDistributor.sol";

/**
 * @notice Implements a malicious holder's behaviour that tries to reenter `claim()` function and get
 * dividends from another round while running the current one.
 */
contract ReentrantClaimer is IReentrancyCallback {
    DividendDistributor public immutable i_distributor;
    uint256 public immutable i_roundToReenter;
    bool public attackAttempted;

    constructor(address distriblutor, uint256 roundToReenter) {
        i_distributor = DividendDistributor(distriblutor);
        i_roundToReenter = roundToReenter;
    }

    function claimRound(uint256 roundId) external {
        i_distributor.claim(roundId);
    }

    function onTokensReceived() external {
        attackAttempted = true;
        try i_distributor.claim(i_roundToReenter) {} catch {}
    }
}
