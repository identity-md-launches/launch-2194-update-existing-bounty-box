// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The only deployment network configuration.
/// @dev Sources: chain ID, RPC and explorer are Robinhood Chain's public values. ORACLE is the
/// platform reviewer EOA named in the update brief. ADMIN is the launch owner stated in the IMD
/// launch policy for this job ("Owner: 0x0165e692ebd858a81820c151c95760b5dd141323"), the address
/// the launch manifest's `$owner` placeholder resolves to. It is not taken from the job page or the
/// update brief, which name no admin wallet. If the launch owner changes, change it here so that the
/// script deployment and the manifest deployment install the same admin.
library RobinhoodConfig {
    uint256 internal constant CHAIN_ID = 4663;
    string internal constant RPC_URL = "https://rpc.mainnet.chain.robinhood.com";
    string internal constant EXPLORER_URL = "https://robin.etherscan.io";
    address internal constant ORACLE = 0xEB3e371d6830d20353b15304217be669E02a3136;
    address internal constant ADMIN = 0x0165e692EbD858a81820C151c95760b5DD141323;
}
