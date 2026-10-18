// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The only deployment network configuration. Values come from the assignment.
library RobinhoodConfig {
    uint256 internal constant CHAIN_ID = 4663;
    string internal constant RPC_URL = "https://rpc.mainnet.chain.robinhood.com";
    string internal constant EXPLORER_URL = "https://robin.etherscan.io";
    address internal constant ORACLE = 0xEB3e371d6830d20353b15304217be669E02a3136;
    address internal constant ADMIN = 0x0165e692EbD858a81820C151c95760b5DD141323;
}
