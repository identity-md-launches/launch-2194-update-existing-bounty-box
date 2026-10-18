// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BountyBox} from "../src/BountyBox.sol";
import {DeployBountyBox} from "../script/DeployBountyBox.s.sol";
import {RobinhoodConfig} from "../script/RobinhoodConfig.sol";

contract DeployBountyBoxTest is Test {
    DeployBountyBox deployment;

    function setUp() public {
        deployment = new DeployBountyBox();
    }

    function test_DeployOnRobinhoodUsesSpecifiedOracleAndLaunchAdmin() public {
        vm.chainId(RobinhoodConfig.CHAIN_ID);
        vm.prank(makeAddr("independent deployment caller"));
        BountyBox box = deployment.deploy(RobinhoodConfig.ADMIN);
        assertEq(box.oracle(), RobinhoodConfig.ORACLE);
        assertEq(box.admin(), RobinhoodConfig.ADMIN);
        assertEq(box.oracle(), 0xEB3e371d6830d20353b15304217be669E02a3136);
        assertEq(box.admin(), 0x0165e692EbD858a81820C151c95760b5DD141323);
        assertTrue(box.admin() != address(deployment));
        assertLe(address(box).code.length, 24_576);
        assertEq(box.jobCount(), 0);
        assertEq(address(box).balance, 0);
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

    function test_DeployRequiresExplicitAdmin() public {
        vm.chainId(RobinhoodConfig.CHAIN_ID);
        vm.expectRevert(DeployBountyBox.ExplicitAdminRequired.selector);
        deployment.deploy(address(0));
    }

    function test_NetworkComesFromSingleConfiguration() public view {
        (uint256 chainId, string memory rpc, string memory explorer) = deployment.network();
        assertEq(chainId, RobinhoodConfig.CHAIN_ID);
        assertEq(chainId, 4663);
        assertEq(rpc, RobinhoodConfig.RPC_URL);
        assertEq(explorer, RobinhoodConfig.EXPLORER_URL);
    }
}
