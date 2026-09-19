// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {CommonBase} from "forge-std/Base.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address stablecoinAddress;
        address treasury;
        address[] guardians;
        address deployer;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getConfig() external view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        address deployer = vm.envAddress("DEPLOYER");

        return NetworkConfig({
            stablecoinAddress: vm.envAddress("SEPOLIA_STABLECOIN_ADDRESS"),
            treasury: vm.envAddress("TREASURY"),
            guardians: _resolveGuardians(deployer),
            deployer: deployer
        });
    }

    function getMainnetEthConfig() public view returns (NetworkConfig memory) {
        address deployer = vm.envAddress("DEPLOYER");

        return NetworkConfig({
            stablecoinAddress: vm.envAddress("ETH_MAINNET_STABLECOIN_ADDRESS"),
            treasury: vm.envAddress("TREASURY"),
            guardians: _resolveGuardians(deployer),
            deployer: deployer
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        address deployer = vm.envOr("ANVIL_DEPLOYER", DEFAULT_SENDER);
        address[] memory guardians = new address[](3);

        guardians[0] = makeAddr("guardian1");
        guardians[1] = makeAddr("guardian2");
        guardians[2] = makeAddr("guardian3");

        vm.startBroadcast();
        ERC20Mock mockStablecoin = new ERC20Mock();
        vm.stopBroadcast();

        return NetworkConfig({
            stablecoinAddress: address(mockStablecoin),
            treasury: makeAddr("treasury"),
            guardians: guardians,
            deployer: deployer
        });
    }

    function _resolveGuardians(address deployer) private view returns (address[] memory) {
        address[] memory guardians = new address[](3);

        address guardian1 = vm.envOr("GUARDIAN_1", deployer);
        address guardian2 = vm.envOr("GUARDIAN_2", deployer);
        address guardian3 = vm.envOr("GUARDIAN_3", deployer);

        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        return guardians;
    }
}
