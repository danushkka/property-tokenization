// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {DevOpsTools} from "foundry-devops/src/DevOpsTools.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PropertyToken} from "../src/PropertyToken.sol";
import {PropertyIssuance} from "../src/PropertyIssuance.sol";
import {WhitelistValidator} from "../src/WhitelistValidator.sol";
import {DividendDistributor} from "../src/DividendDistributor.sol";
import {RevenueVault} from "../src/RevenueVault.sol";

/**
 * @title PurchaseTokens
 *
 * @notice Self-contained demo script: whitelists the broadcaster, checks if they have
 * enough value in stablecoin on Sepolia, and purchases PropertyToken through the live PropertyIssuance contract.
 */
contract PurchaseTokens is Script {
    uint256 public constant PURCHASE_AMOUNT = 5e18;

    function purchaseTokens(address issuerAddr) public {
        PropertyIssuance issuer = PropertyIssuance(issuerAddr);
        WhitelistValidator validator = WhitelistValidator(address(issuer.i_token().validator()));
        IERC20 stablecoin = IERC20(issuer.i_stablecoin());

        address buyer = msg.sender;
        if (!validator.isWhitelisted(buyer)) {
            validator.addToWhitelist(buyer);
            console2.log("Whitelisted buyer:", buyer);
        }

        uint256 cost = Math.mulDiv(PURCHASE_AMOUNT, issuer.s_pricePerToken(), 1e18);
        require(stablecoin.balanceOf(buyer) >= cost, "Insufficient USDC balance - fund via faucet.circle.com first");

        stablecoin.approve(issuerAddr, cost);
        issuer.purchase(PURCHASE_AMOUNT);
        console2.log("Purchased 5 tokens for", cost, "USDC units");
    }

    function run() external {
        address issuerAddr = DevOpsTools.get_most_recent_deployment("PropertyIssuance", block.chainid);
        vm.startBroadcast();
        purchaseTokens(issuerAddr);
        vm.stopBroadcast();
    }
}

/**
 * @title DeclareDividend
 * @notice Deposits mock rental income (in USDC) into the vault and declares a dividend round for it.
 */
contract DeclareDividend is Script {
    uint256 public constant DIVIDEND_AMOUNT = 25e6; // 25 USDC (6 decimals)

    function declareDividend(address distributorAddr) public {
        DividendDistributor distributor = DividendDistributor(distributorAddr);

        uint256 supply = PropertyToken(address(distributor.i_token())).totalSupply();
        require(supply > 0, "No PropertyToken supply yet - run PurchaseTokens first");

        RevenueVault vault = distributor.i_vault();
        IERC20 stablecoin = IERC20(vault.i_stablecoin());

        require(
            stablecoin.balanceOf(msg.sender) >= DIVIDEND_AMOUNT,
            "Insufficient USDC balance - fund via faucet.circle.com first"
        );

        stablecoin.approve(address(vault), DIVIDEND_AMOUNT);
        vault.deposit(DIVIDEND_AMOUNT);

        distributor.declareDividends(DIVIDEND_AMOUNT);
        console2.log("Declared dividend of", DIVIDEND_AMOUNT, "as round", distributor.getRoundCount() - 1);
    }

    function run() external {
        address distributorAddr = DevOpsTools.get_most_recent_deployment("DividendDistributor", block.chainid);
        vm.startBroadcast();
        declareDividend(distributorAddr);
        vm.stopBroadcast();
    }
}

/**
 * @title ClaimDividend
 * @notice Claims the most recently declared dividend round on behalf of the broadcaster.
 */
contract ClaimDividend is Script {
    function claimDividend(address distributorAddr) public {
        DividendDistributor distributor = DividendDistributor(distributorAddr);
        uint256 latestRound = distributor.getRoundCount() - 1;

        distributor.claim(latestRound);
        console2.log("Claimed dividend round", latestRound, "as", msg.sender);
    }

    function run() external {
        address distributorAddr = DevOpsTools.get_most_recent_deployment("DividendDistributor", block.chainid);

        vm.startBroadcast();
        claimDividend(distributorAddr);
        vm.stopBroadcast();
    }
}
