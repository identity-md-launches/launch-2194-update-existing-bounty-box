// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BountyBox} from "../src/BountyBox.sol";
import {DeployBountyBox} from "../script/DeployBountyBox.s.sol";

/// @notice Exercises the script's real `run()` entry point end to end on the Robinhood chain ID,
/// including the broadcast, rather than only the `deploy` helper.
contract DeployBountyBoxRunTest is Test {
    address constant LAUNCH_OWNER = 0x0165e692EbD858a81820C151c95760b5DD141323;
    address constant BRIEF_ORACLE = 0xEB3e371d6830d20353b15304217be669E02a3136;

    function test_RunDeploysOnRobinhoodWithBriefOracleAndLaunchOwner() public {
        DeployBountyBox deployment = new DeployBountyBox();
        vm.chainId(4663);
        vm.expectEmit(true, true, true, true);
        emit BountyBox.AdminSet(LAUNCH_OWNER);
        BountyBox box = deployment.run();
        assertEq(box.oracle(), BRIEF_ORACLE);
        assertEq(box.admin(), LAUNCH_OWNER);
        assertEq(box.pendingOracle(), address(0));
        assertTrue(address(box).code.length > 0);
        assertTrue(box.admin() != address(deployment));
    }

    function test_RunRejectsBaseBeforeBroadcast() public {
        DeployBountyBox deployment = new DeployBountyBox();
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(DeployBountyBox.WrongChain.selector, 8453, 4663));
        deployment.run();
    }
}
