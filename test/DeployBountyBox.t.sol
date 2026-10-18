// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BountyBox} from "../src/BountyBox.sol";
import {DeployBountyBox} from "../script/DeployBountyBox.s.sol";
import {RobinhoodConfig} from "../script/RobinhoodConfig.sol";

contract DeployBountyBoxTest is Test {
    /// @dev The launch owner from the IMD launch policy for this job, the value `$owner` resolves to.
    /// Spelled out here so the configured constant is checked against the policy, not against itself.
    address constant LAUNCH_OWNER = 0x0165e692EbD858a81820C151c95760b5DD141323;
    /// @dev The platform reviewer EOA named in the update brief.
    address constant BRIEF_ORACLE = 0xEB3e371d6830d20353b15304217be669E02a3136;

    DeployBountyBox deployment;

    function setUp() public {
        deployment = new DeployBountyBox();
    }

    function test_RunPathInstallsBriefOracleAndLaunchOwnerAdmin() public {
        vm.chainId(RobinhoodConfig.CHAIN_ID);
        address caller = makeAddr("independent deployment caller");
        vm.expectEmit(true, true, true, true);
        emit BountyBox.AdminSet(LAUNCH_OWNER);
        vm.prank(caller);
        BountyBox box = deployment.deploy(RobinhoodConfig.ADMIN);
        assertEq(box.oracle(), BRIEF_ORACLE);
        assertEq(box.admin(), LAUNCH_OWNER);
        assertEq(RobinhoodConfig.ORACLE, BRIEF_ORACLE);
        assertEq(RobinhoodConfig.ADMIN, LAUNCH_OWNER);
        assertTrue(box.admin() != address(deployment));
        assertTrue(box.admin() != caller);
        assertLe(address(box).code.length, 24_576);
        assertEq(box.jobCount(), 0);
        assertEq(address(box).balance, 0);
    }

    function test_ZeroAdminFallsBackToDeployingWallet() public {
        vm.chainId(RobinhoodConfig.CHAIN_ID);
        address deployer = makeAddr("deployer wallet");
        vm.expectEmit(true, true, true, true);
        emit BountyBox.AdminSet(deployer);
        vm.prank(deployer);
        BountyBox box = deployment.deploy(address(0));
        assertEq(box.admin(), deployer);
        assertEq(box.oracle(), BRIEF_ORACLE);
        assertTrue(box.admin() != address(deployment));
        assertTrue(box.admin() != LAUNCH_OWNER);
    }

    function test_ZeroAdminRejectsFoundryDefaultSender() public {
        vm.chainId(RobinhoodConfig.CHAIN_ID);
        vm.prank(DEFAULT_SENDER);
        vm.expectRevert(abi.encodeWithSelector(DeployBountyBox.UnsafeDeployerFallback.selector, DEFAULT_SENDER));
        deployment.deploy(address(0));
    }

    function test_ZeroAdminRejectsContractCaller() public {
        vm.chainId(RobinhoodConfig.CHAIN_ID);
        // This test contract has code, standing in for a factory or any other contract deployer.
        vm.expectRevert(abi.encodeWithSelector(DeployBountyBox.UnsafeDeployerFallback.selector, address(this)));
        deployment.deploy(address(0));
    }

    function test_ExplicitAdminIsInstalledEvenWhenCallerIsAContract() public {
        vm.chainId(RobinhoodConfig.CHAIN_ID);
        address chosen = makeAddr("explicitly chosen admin");
        BountyBox box = deployment.deploy(chosen);
        assertEq(box.admin(), chosen);
    }

    function test_RejectsEthereumMainnetAndBase() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployBountyBox.WrongChain.selector, 1, RobinhoodConfig.CHAIN_ID));
        deployment.deploy(RobinhoodConfig.ADMIN);
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(DeployBountyBox.WrongChain.selector, 8453, RobinhoodConfig.CHAIN_ID));
        deployment.deploy(RobinhoodConfig.ADMIN);
    }

    function test_RunRejectsWrongChainBeforeBroadcast() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployBountyBox.WrongChain.selector, 1, RobinhoodConfig.CHAIN_ID));
        deployment.run();
    }

    function test_NetworkComesFromSingleConfiguration() public view {
        (uint256 chainId, string memory rpc, string memory explorer) = deployment.network();
        assertEq(chainId, RobinhoodConfig.CHAIN_ID);
        assertEq(chainId, 4663);
        assertEq(rpc, RobinhoodConfig.RPC_URL);
        assertEq(explorer, RobinhoodConfig.EXPLORER_URL);
    }
}
