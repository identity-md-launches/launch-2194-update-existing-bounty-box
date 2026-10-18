// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {BountyBox} from "../src/BountyBox.sol";
import {RobinhoodConfig} from "./RobinhoodConfig.sol";

/// @notice Robinhood-only deployment entry point. No environment reads or private keys in source.
contract DeployBountyBox is Script {
    error WrongChain(uint256 actual, uint256 expected);
    error UnsafeDeployerFallback(address sender);

    /// @notice Deploys with the launch owner as admin: the same address the launch manifest's
    /// `$owner` resolves to, so a script deployment and the factory launch install one admin.
    function run() external returns (BountyBox box) {
        _checkChain();
        vm.startBroadcast();
        box = deploy(RobinhoodConfig.ADMIN);
        vm.stopBroadcast();
    }

    /// @notice Testable deployment logic. A nonzero `admin_` is installed as given. A zero `admin_`
    /// applies the brief's fallback: the admin is the deployer, meaning the wallet calling this
    /// function, resolved here because the constructor would otherwise see this script contract as
    /// `msg.sender`. The fallback refuses Foundry's default script sender (no `--sender` given) and
    /// any contract caller such as a factory, since neither is a wallet anyone controls as admin.
    function deploy(address admin_) public returns (BountyBox box) {
        _checkChain();
        address admin = admin_;
        if (admin == address(0)) {
            admin = msg.sender;
            if (admin == DEFAULT_SENDER || admin.code.length != 0) revert UnsafeDeployerFallback(admin);
        }
        box = new BountyBox(RobinhoodConfig.ORACLE, admin);
    }

    function network() external pure returns (uint256 chainId, string memory rpc, string memory explorer) {
        return (RobinhoodConfig.CHAIN_ID, RobinhoodConfig.RPC_URL, RobinhoodConfig.EXPLORER_URL);
    }

    function _checkChain() private view {
        if (block.chainid != RobinhoodConfig.CHAIN_ID) revert WrongChain(block.chainid, RobinhoodConfig.CHAIN_ID);
    }
}
