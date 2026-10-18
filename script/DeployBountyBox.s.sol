// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {BountyBox} from "../src/BountyBox.sol";
import {RobinhoodConfig} from "./RobinhoodConfig.sol";

/// @notice Robinhood-only deployment entry point. No environment reads or private keys in source.
contract DeployBountyBox is Script {
    error WrongChain(uint256 actual, uint256 expected);
    error ExplicitAdminRequired();

    function run() external returns (BountyBox box) {
        _checkChain();
        vm.startBroadcast();
        box = deploy(RobinhoodConfig.ADMIN);
        vm.stopBroadcast();
    }

    /// @notice Testable deployment logic; also supports a separately confirmed explicit admin.
    /// Never use the constructor's deployer fallback through a factory or this script contract.
    function deploy(address admin_) public returns (BountyBox box) {
        _checkChain();
        if (admin_ == address(0)) revert ExplicitAdminRequired();
        box = new BountyBox(RobinhoodConfig.ORACLE, admin_);
    }

    function network() external pure returns (uint256 chainId, string memory rpc, string memory explorer) {
        return (RobinhoodConfig.CHAIN_ID, RobinhoodConfig.RPC_URL, RobinhoodConfig.EXPLORER_URL);
    }

    function _checkChain() private view {
        if (block.chainid != RobinhoodConfig.CHAIN_ID) revert WrongChain(block.chainid, RobinhoodConfig.CHAIN_ID);
    }
}
