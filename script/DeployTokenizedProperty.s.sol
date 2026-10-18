// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HelperConfig} from "../script/HelperConfig.s.sol";

import {WhitelistValidator} from "../src/WhitelistValidator.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {PropertyIssuance} from "../src/PropertyIssuance.sol";
import {RevenueVault} from "../src/RevenueVault.sol";
import {DividendDistributor} from "../src/DividendDistributor.sol";

/**
 * @title DeployTokenizedProperty
 *
 * @notice Deploys WhitelistValidator, PropertyToken, PropertyIssuance, RevenueVault, DividendDistributor and TimelockController.
 * Requires a specific deployment sequence in order to correctly link all the contracts to each other.
 *
 * Deployment sequence:
 * 1. Get the required parameters from HelperConfig;
 * 2. Deploy WhitelistValidator;
 * 3. Deploy PropertyToken;
 * 4. Deploy PropertyIssuance;
 * 5. Reassign token's ISSUER_ROLE from the deployer to the issuer;
 * 6. Deploy RevenueVault;
 * 7. Deploy DividendDistributor;
 * 8. Reassign vault's DISTRIBUTOR_ROLE from the deployer to the distributor;
 * 9. Deploy TimelockController;
 * 10. Assign timelock's CANCELLER_ROLEs to guardians;
 * 11. Reassign all DEFAULT_ADMIN_ROLEs from the deployer to the timelock.
 */
contract DeployTokenizedProperty is Script {
    uint256 public constant MAX_SUPPLY = 1_000_000e18;
    uint256 public constant INITIAL_TOKEN_PRICE = 10e6;
    uint256 public constant MAX_PURCHASE_PER_TX = 100_000e18;
    uint256 public constant MIN_DELAY = 72 hours;

    function run()
        public
        returns (
            // address stablecoinAddress,
            WhitelistValidator validator,
            PropertyToken token,
            PropertyIssuance issuer,
            RevenueVault vault,
            DividendDistributor distributor,
            TimelockController timelock,
            HelperConfig.NetworkConfig memory config
            // address deployer
        )
    {
        HelperConfig helperConfig = new HelperConfig();
        config = helperConfig.getConfig();

        address stablecoinAddress = config.stablecoinAddress;
        address treasury = config.treasury;
        address[] memory guardians = config.guardians;
        address deployer = config.deployer;

        vm.startBroadcast();

        validator = new WhitelistValidator(deployer);
        console2.log("Whitelist Validator deployed at:", address(validator));

        token = new PropertyToken("DaniKo PropToken", "DKPT", deployer, address(validator), MAX_SUPPLY);
        console2.log("Property Token deployed at:", address(token));

        issuer = new PropertyIssuance(
            address(token), stablecoinAddress, treasury, deployer, INITIAL_TOKEN_PRICE, MAX_PURCHASE_PER_TX
        );
        console2.log("Property Issuance deployed at:", address(issuer));

        token.grantRole(token.ISSUER_ROLE(), address(issuer));
        token.revokeRole(token.ISSUER_ROLE(), deployer);

        vault = new RevenueVault(deployer, stablecoinAddress);
        console2.log("Revenue Vault deployed at:", address(vault));

        distributor = new DividendDistributor(address(token), address(vault), deployer);
        console2.log("Dividend Distributor deployed at:", address(distributor));

        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone can execute once the delay has passed

        timelock = new TimelockController(MIN_DELAY, proposers, executors, deployer);

        for (uint256 i; i < guardians.length; i++) {
            timelock.grantRole(timelock.CANCELLER_ROLE(), guardians[i]);
        }

        token.grantRole(token.DEFAULT_ADMIN_ROLE(), address(timelock));
        token.revokeRole(token.DEFAULT_ADMIN_ROLE(), deployer);

        issuer.grantRole(issuer.DEFAULT_ADMIN_ROLE(), address(timelock));
        issuer.revokeRole(issuer.DEFAULT_ADMIN_ROLE(), deployer);

        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(timelock));
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), deployer);

        distributor.grantRole(distributor.DEFAULT_ADMIN_ROLE(), address(timelock));
        distributor.revokeRole(distributor.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console2.log("--- Deployment complete ---");
        console2.log("Deployer (retains PRICE_ORACLE_ROLE, DEPOSITOR_ROLE, DIVIDEND_MANAGER_ROLE):", deployer);
    }
}
