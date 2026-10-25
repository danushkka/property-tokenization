// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployTokenizedProperty} from "../../script/DeployTokenizedProperty.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

import {WhitelistValidator} from "../../src/WhitelistValidator.sol";
import {PropertyToken} from "../../src/PropertyToken.sol";
import {PropertyIssuance} from "../../src/PropertyIssuance.sol";
import {RevenueVault} from "../../src/RevenueVault.sol";
import {DividendDistributor} from "../../src/DividendDistributor.sol";

contract DeployTest is Test {
    /////////////////////////////////////
    ////////// STATE VARIABLES //////////
    /////////////////////////////////////

    DeployTokenizedProperty public deployScript;
    HelperConfig public helperConfig;

    address stablecoinAddress;
    WhitelistValidator validator;
    PropertyToken token;
    PropertyIssuance issuer;
    RevenueVault vault;
    DividendDistributor distributor;
    TimelockController timelock;
    HelperConfig.NetworkConfig config;
    address deployer;

    //////////////////////////////////////
    /////////////// SET UP ///////////////
    //////////////////////////////////////

    function setUp() public {
        vm.setEnv("ANVIL_DEPLOYER", vm.toString(DEFAULT_SENDER));
        deployScript = new DeployTokenizedProperty();

        (validator, token, issuer, vault, distributor, timelock, config) = deployScript.run();
        stablecoinAddress = config.stablecoinAddress;
        deployer = config.deployer;
    }

    //////////////////////////////////////
    ////////// CONTRACT LINKING //////////
    //////////////////////////////////////

    function test_Deploy_TokenPointsToCorrectValidator() public view {
        assertEq(address(validator), address(token.validator()));
    }

    function test_Deploy_VaultPointsToCorrectStablecoin() public view {
        assertEq(address(vault.i_stablecoin()), stablecoinAddress);
    }

    function test_Deploy_DistributorPointsToCorrectTokenAndVault() public view {
        assertEq(address(distributor.i_token()), address(token));
        assertEq(address(distributor.i_vault()), address(vault));
    }

    function test_Deploy_IssuerPointsToCorrectDependencies() public view {
        assertEq(address(issuer.i_token()), address(token));
        assertEq(address(issuer.i_stablecoin()), stablecoinAddress);
        assertEq(issuer.i_treasury(), config.treasury);
    }

    //////////////////////////////////////
    ////////// GOVERNANCE ROLES //////////
    //////////////////////////////////////

    function test_Deploy_TimelockHoldsDefaultAdminRoleEverywhere() public view {
        assertTrue(validator.hasRole(validator.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(issuer.hasRole(issuer.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function test_Deploy_DeployerLosesDefaultAdminRoleEverywhere() public view {
        assertFalse(token.hasRole(validator.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(issuer.hasRole(issuer.DEFAULT_ADMIN_ROLE(), deployer));
    }

    //////////////////////////////////////
    ///////// OPERATIONAL ROLES //////////
    //////////////////////////////////////

    function test_Deploy_IssuerHoldsIssuerRoleOnToken() public view {
        assertTrue(token.hasRole(token.ISSUER_ROLE(), address(issuer)));
    }

    function test_Deploy_DistributorHoldsDistributorRoleOnVault() public view {
        assertTrue(vault.hasRole(vault.DISTRIBUTOR_ROLE(), address(distributor)));
    }

    //////////////////////////////////////
    ////////// TIMELOCK CONFIG ///////////
    //////////////////////////////////////

    function test_Deploy_GuardiansHoldCancellerRole() public view {
        for (uint256 i = 0; i < config.guardians.length; i++) {
            assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), config.guardians[i]));
        }
    }
}
