// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {BountyBox} from "../src/BountyBox.sol";

abstract contract UpdateFixture is Test {
    BountyBox box;
    address admin = makeAddr("admin");
    address reviewer = makeAddr("reviewer");
    address nextReviewer = makeAddr("next reviewer");
    address nextAdmin = makeAddr("next admin");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address outsider = makeAddr("outsider");
    uint256 job;
    bytes32 constant BRIEF = keccak256("acceptance criteria");

    function setUp() public virtual {
        vm.warp(100 days);
        box = new BountyBox(reviewer, admin);
        vm.deal(creator, 100 ether);
        vm.prank(creator);
        job = box.createJob{value: 10 ether}(BRIEF, block.timestamp + 90 days, "acceptance criteria");
    }

    function _submit(address worker) internal returns (uint256) {
        vm.prank(worker);
        return box.submit(job, keccak256(abi.encode(worker)), "ipfs://evidence");
    }

    function _reject(uint256 id) internal {
        vm.prank(creator);
        box.reject(job, id, "needs revision");
    }

    function _dispute(address worker) internal returns (uint256 id) {
        uint256 submission = _submit(worker);
        _reject(submission);
        vm.prank(worker);
        box.escalate(job);
        return box.getJob(job).pendingRequestId;
    }

    function _rotate(address next) internal {
        vm.prank(admin);
        box.proposeOracle(next);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(admin);
        box.confirmOracle();
    }

    function _assertState(uint256 id, BountyBox.SubmissionState expected) internal view {
        assertEq(uint256(box.getSubmission(id).state), uint256(expected));
    }

    function _assertSolvent() internal view {
        assertEq(address(box).balance, box.totalEscrow() + box.totalClaimable());
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) ++count;
        }
    }
}

contract BountyBoxFixesTest is UpdateFixture {
    function test_AbandonmentBoundaryKeepsEscalationRightUntilThirtyDays() public {
        uint256 id = _submit(alice);
        uint256 until = box.getSubmission(id).reviewUntil + 30 days;
        vm.warp(until - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.closeSlot(job, alice);
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        vm.prank(alice);
        box.escalate(job);
        _assertState(id, BountyBox.SubmissionState.Escalated);
        vm.warp(until);
        vm.expectRevert(BountyBox.OraclePending.selector);
        box.closeSlot(job, alice);
        vm.expectRevert(BountyBox.OraclePending.selector);
        vm.prank(creator);
        box.refund(job);
    }

    function test_AnyoneClosesAbandonedSlotAndCreatorRefunds() public {
        uint256 id = _submit(alice);
        vm.warp(box.getSubmission(id).reviewUntil + 30 days);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        vm.prank(alice);
        box.escalate(job);
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.Cancelled(job, id);
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.SlotClosed(job, alice, BountyBox.CloseReason.Abandoned);
        vm.prank(outsider);
        box.closeSlot(job, alice);
        _assertState(id, BountyBox.SubmissionState.Cancelled);
        assertTrue(box.getWorker(job, alice).closed);
        assertEq(box.getJob(job).workerCount, 0);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.approve(job, id);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(alice);
        box.escalate(job);
        vm.prank(creator);
        box.refund(job);
        assertEq(box.claimable(job, creator), 10 ether);
        _assertSolvent();
    }

    function test_RefundClosesAllAbandonedSubmissionsAndEmitsCancellations() public {
        uint256 a = _submit(alice);
        uint256 b = _submit(bob);
        uint256 c = _submit(carol);
        vm.warp(box.getSubmission(a).reviewUntil + 30 days);
        vm.recordLogs();
        vm.prank(creator);
        box.refund(job);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("Cancelled(uint256,uint256)")), 3);
        assertEq(_count(logs, keccak256("SlotClosed(uint256,address,uint8)")), 3);
        assertEq(_count(logs, keccak256("CancelledByApproval(uint256,uint256,uint256)")), 0);
        _assertState(a, BountyBox.SubmissionState.Cancelled);
        _assertState(b, BountyBox.SubmissionState.Cancelled);
        _assertState(c, BountyBox.SubmissionState.Cancelled);
        assertEq(box.getJob(job).workerCount, 0);
        assertEq(box.totalEscrow(), 0);
        assertEq(box.claimable(job, creator), 10 ether);
        _assertSolvent();
    }

    function test_RefundCancelsRejectedAndFailedReviewSubmissions() public {
        uint256 a = _submit(alice);
        _reject(a);
        uint256 r = _dispute(bob);
        uint256 b = box.getRequest(r).submissionId;
        vm.prank(reviewer);
        box.answer(r, false, 0, "failed review reason");
        vm.warp(block.timestamp + 2 days);
        vm.recordLogs();
        vm.prank(creator);
        box.refund(job);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("Cancelled(uint256,uint256)")), 2);
        _assertState(a, BountyBox.SubmissionState.Cancelled);
        _assertState(b, BountyBox.SubmissionState.Cancelled);
        assertEq(box.getSubmission(b).reason, "failed review reason");
        assertEq(box.getWorker(job, bob).failedReviews, 1);
        assertEq(box.claimable(job, creator), 10 ether);
    }

    function test_RefundCannotPartiallyCloseBeforeFindingActiveWorker() public {
        uint256 a = _submit(alice);
        _reject(a);
        _submit(bob);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        assertFalse(box.getWorker(job, alice).closed);
        _assertState(a, BountyBox.SubmissionState.Rejected);
        assertEq(box.getJob(job).workerCount, 2);
        assertEq(box.claimable(job, creator), 0);
    }

    function testFuzz_ApprovePendingAfterReviewWindow(uint32 delay) public {
        uint256 id = _submit(alice);
        vm.warp(box.getSubmission(id).reviewUntil + uint256(delay));
        vm.expectRevert(BountyBox.WindowClosed.selector);
        _reject(id);
        vm.prank(creator);
        box.approve(job, id);
        _assertState(id, BountyBox.SubmissionState.Approved);
        assertEq(box.claimable(job, alice), 10 ether);
        _assertSolvent();
    }

    function test_ApprovalDuringRequestCancelsItAndPreventsAnswerOrSplit() public {
        uint256 a = _submit(alice);
        uint256 r = _dispute(bob);
        uint256 escalated = box.getRequest(r).submissionId;
        vm.warp(block.timestamp + 4 days);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.approve(job, escalated);
        vm.recordLogs();
        vm.prank(creator);
        box.approve(job, a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("CancelledByApproval(uint256,uint256,uint256)")), 1);
        assertEq(logs[logs.length - 1].topics[1], bytes32(job));
        assertEq(logs[logs.length - 1].topics[2], bytes32(escalated));
        assertEq(logs[logs.length - 1].topics[3], bytes32(a));
        assertTrue(box.getRequest(r).resolved);
        assertEq(box.getJob(job).pendingRequestId, 0);
        assertEq(box.claimable(job, alice), 10 ether);
        assertEq(box.claimable(job, bob), 0);
        _assertState(escalated, BountyBox.SubmissionState.Cancelled);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(reviewer);
        box.answer(r, true, 0, "too late");
        vm.warp(box.getRequest(r).settleAfter);
        vm.expectRevert(BountyBox.InvalidState.selector);
        box.settleSplit(job);
        _assertSolvent();
    }

    function test_ApprovalStillWorksAtOracleTimeoutUntilSplitWinsRace() public {
        uint256 a = _submit(alice);
        uint256 r = _dispute(bob);
        vm.warp(box.getRequest(r).settleAfter);
        vm.prank(creator);
        box.approve(job, a);
        assertEq(box.claimable(job, alice), 10 ether);
        vm.expectRevert(BountyBox.InvalidState.selector);
        box.settleSplit(job);
    }

    function test_SplitWinningRacePreventsApproval() public {
        uint256 a = _submit(alice);
        uint256 r = _dispute(bob);
        vm.warp(box.getRequest(r).settleAfter);
        box.settleSplit(job);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.approve(job, a);
        assertEq(box.claimable(job, bob), 4 ether);
        assertEq(box.claimable(job, creator), 6 ether);
    }

    function test_DeadlineCapAcceptsNinetyDaysRejectsOneSecondMore() public {
        assertEq(box.getJob(job).deadline, block.timestamp + 90 days);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(creator);
        box.createJob{value: 1}(BRIEF, block.timestamp + 90 days + 1, "acceptance criteria");
        box.publishJobText("acceptance criteria");
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(creator);
        box.createJob{value: 1}(BRIEF, block.timestamp + 90 days + 1);
        vm.prank(creator);
        box.createJob{value: 1}(BRIEF, block.timestamp + 90 days);
    }

    function test_NinetyDayDeadlineCannotDelaySevenDaySettlement() public {
        uint256 r = _dispute(alice);
        uint256 until = box.getRequest(r).settleAfter;
        assertEq(until, block.timestamp + 7 days);
        assertLt(until, box.getJob(job).deadline);
        vm.warp(until - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.settleSplit(job);
        vm.warp(until);
        vm.prank(outsider);
        box.settleSplit(job);
        assertEq(box.claimable(job, creator), 6 ether);
        assertEq(box.claimable(job, alice), 4 ether);
    }

    function test_ClosingMiddleSlotRecyclesWithoutLosingOtherParticipants() public {
        uint256 a = _submit(alice);
        uint256 b = _submit(bob);
        uint256 c = _submit(carol);
        _reject(b);
        vm.warp(block.timestamp + 2 days);
        box.closeSlot(job, bob);
        address[3] memory participants = box.getParticipants(job);
        assertEq(participants[0], alice);
        assertEq(participants[1], carol);
        assertEq(participants[2], address(0));
        assertEq(box.getJob(job).workerCount, 2);
        uint256 replacement = _submit(outsider);
        assertEq(box.getJob(job).workerCount, 3);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _submit(bob);
        vm.prank(creator);
        box.approve(job, replacement);
        _assertState(a, BountyBox.SubmissionState.Cancelled);
        _assertState(b, BountyBox.SubmissionState.Cancelled);
        _assertState(c, BountyBox.SubmissionState.Cancelled);
        assertEq(box.getWorker(job, bob).submissionCount, 1);
        assertEq(box.getJob(job).submissionCount, 4);
    }

    function test_AbandonedSlotRecyclesBeforeDeadline() public {
        uint256 a = _submit(alice);
        vm.warp(box.getSubmission(a).reviewUntil + 30 days);
        box.closeSlot(job, alice);
        _submit(bob);
        assertEq(box.getJob(job).workerCount, 1);
        assertTrue(box.getWorker(job, alice).closed);
    }

    function test_RecycledSlotDoesNotExtendDeadline() public {
        uint256 a = _submit(alice);
        _reject(a);
        vm.warp(box.getJob(job).deadline);
        box.closeSlot(job, alice);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        _submit(bob);
    }

    function test_RecyclingBeyond255SubmissionsKeepsCountersAndSettlementBounded() public {
        // Fast oracle decisions can recycle many slots without advancing the 90-day deadline.
        for (uint256 i; i < 86; ++i) {
            address worker = address(uint160(10_000 + i));
            for (uint256 attempt; attempt < 3; ++attempt) {
                uint256 id = _submit(worker);
                _reject(id);
                uint256 r = box.getJob(job).pendingRequestId;
                if (r == 0) {
                    vm.prank(worker);
                    box.escalate(job);
                    r = box.getJob(job).pendingRequestId;
                }
                vm.prank(reviewer);
                box.answer(r, false, 0, "failed review");
            }
            assertTrue(box.getWorker(job, worker).closed);
            assertEq(box.getWorker(job, worker).failedReviews, 3);
            assertEq(box.getJob(job).workerCount, 0);
        }
        assertEq(box.getJob(job).submissionCount, 258);
        uint256 winner = _submit(alice);
        _submit(bob);
        vm.prank(creator);
        (bool success,) = address(box).call{gas: 500_000}(abi.encodeCall(box.approve, (job, winner)));
        assertTrue(success, "settlement must not scan historical workers");
        assertEq(box.getJob(job).submissionCount, 260);
        assertEq(box.claimable(job, alice), 10 ether);
        _assertState(box.getWorker(job, bob).latestSubmissionId, BountyBox.SubmissionState.Cancelled);
        _assertSolvent();
    }

    function test_CreatorApprovalCancellationEventIncludesEveryLiveLoser() public {
        uint256 a = _submit(alice);
        uint256 b = _submit(bob);
        uint256 c = _submit(carol);
        _reject(c);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.CancelledByApproval(job, b, a);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.CancelledByApproval(job, c, a);
        vm.prank(creator);
        box.approve(job, a);
        _assertState(b, BountyBox.SubmissionState.Cancelled);
        _assertState(c, BountyBox.SubmissionState.Cancelled);
    }

    function test_OracleApprovalCancellationHasSameDistinctEvent() public {
        uint256 a = _submit(alice);
        uint256 r = _dispute(bob);
        uint256 b = box.getRequest(r).submissionId;
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.CancelledByApproval(job, a, b);
        vm.prank(reviewer);
        box.answer(r, true, 0, "accepted");
        assertEq(box.claimable(job, bob), 10 ether);
    }

    function test_SplitCancellationDoesNotPretendToBeApproval() public {
        _submit(alice);
        uint256 r = _dispute(bob);
        vm.warp(box.getRequest(r).settleAfter);
        vm.recordLogs();
        box.settleSplit(job);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("Cancelled(uint256,uint256)")), 2);
        assertEq(_count(logs, keccak256("CancelledByApproval(uint256,uint256,uint256)")), 0);
    }

    function test_AbandonmentClockPausesWhileOtherRequestOpen() public {
        uint256 a = _submit(alice);
        vm.warp(box.getSubmission(a).reviewUntil + 30 days - 1);
        uint256 r = _dispute(bob);
        uint256 oldUntil = box.getSubmission(a).reviewUntil;
        vm.warp(block.timestamp + 6 days);
        vm.prank(reviewer);
        box.answer(r, false, 0, "no");
        assertEq(box.getSubmission(a).reviewUntil, oldUntil + 6 days);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.closeSlot(job, alice);
        vm.prank(alice);
        box.escalate(job);
    }

    function test_ExpiredAbandonmentIsNotResurrectedByOtherRequest() public {
        uint256 a = _submit(alice);
        uint256 reviewUntil = box.getSubmission(a).reviewUntil;
        vm.warp(reviewUntil + 30 days);
        uint256 r = _dispute(bob);
        vm.warp(block.timestamp + 1 days);
        vm.prank(reviewer);
        box.answer(r, false, 0, "no");
        assertEq(box.getSubmission(a).reviewUntil, reviewUntil);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        vm.prank(alice);
        box.escalate(job);
        box.closeSlot(job, alice);
    }
}

contract BountyBoxAdminTest is UpdateFixture {
    function test_DefaultAdminIsDeployerAndEmitsAdminSet() public {
        vm.expectEmit(true, false, false, true);
        emit BountyBox.AdminSet(outsider);
        vm.prank(outsider);
        BountyBox deployed = new BountyBox(reviewer, address(0));
        assertEq(deployed.admin(), outsider);
        assertEq(deployed.oracle(), reviewer);
    }

    function test_ExplicitAdminIsNotDeployerAndEmitsAdminSet() public {
        vm.expectEmit(true, false, false, true);
        emit BountyBox.AdminSet(admin);
        vm.prank(outsider);
        BountyBox deployed = new BountyBox(reviewer, admin);
        assertEq(deployed.admin(), admin);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(outsider);
        deployed.proposeOracle(nextReviewer);
    }

    function test_ZeroOracleConstructorAndProposalFail() public {
        vm.expectRevert(BountyBox.InvalidInput.selector);
        new BountyBox(address(0), admin);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(admin);
        box.proposeOracle(address(0));
        assertEq(box.oracle(), reviewer);
        assertEq(box.pendingOracle(), address(0));
    }

    function test_ProposeThenConfirmExactlyAfterTwentyFourHours() public {
        uint256 until = block.timestamp + 24 hours;
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.OracleProposed(nextReviewer, until);
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        assertEq(box.oracle(), reviewer);
        assertEq(box.pendingOracle(), nextReviewer);
        assertEq(box.oracleChangeAfter(), until);
        vm.warp(until - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        vm.prank(admin);
        box.confirmOracle();
        vm.warp(until);
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.OracleConfirmed(reviewer, nextReviewer);
        vm.prank(admin);
        box.confirmOracle();
        assertEq(box.oracle(), nextReviewer);
        assertEq(box.pendingOracle(), address(0));
        assertEq(box.oracleChangeAfter(), 0);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(admin);
        box.confirmOracle();
    }

    function test_CancelOracleProposalBeforeDelayAndCannotConfirmIt() public {
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.OracleCancelled(nextReviewer);
        vm.prank(admin);
        box.cancelOracle();
        assertEq(box.oracle(), reviewer);
        assertEq(box.pendingOracle(), address(0));
        assertEq(box.oracleChangeAfter(), 0);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(admin);
        box.confirmOracle();
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(admin);
        box.cancelOracle();
    }

    function test_CancelMatureProposal() public {
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(admin);
        box.cancelOracle();
        assertEq(box.oracle(), reviewer);
        assertEq(box.pendingOracle(), address(0));
    }

    function test_ReplacingProposalRestartsFullDelay() public {
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.warp(block.timestamp + 24 hours);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.OracleCancelled(nextReviewer);
        vm.prank(admin);
        box.proposeOracle(outsider);
        vm.expectRevert(BountyBox.TooEarly.selector);
        vm.prank(admin);
        box.confirmOracle();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(admin);
        box.confirmOracle();
        assertEq(box.oracle(), outsider);
    }

    function testFuzz_AllAdminFunctionsRejectNonAdmin(address caller) public {
        vm.assume(caller != admin && caller != address(vm));
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.prank(admin);
        box.transferAdmin(nextAdmin);
        vm.warp(block.timestamp + 24 hours);
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(box.proposeOracle, (outsider));
        calls[1] = abi.encodeCall(box.confirmOracle, ());
        calls[2] = abi.encodeCall(box.cancelOracle, ());
        calls[3] = abi.encodeCall(box.transferAdmin, (outsider));
        calls[4] = abi.encodeCall(box.cancelAdminTransfer, ());
        calls[5] = abi.encodeCall(box.renounceAdmin, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(caller);
            (bool success, bytes memory reason) = address(box).call(calls[i]);
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(BountyBox.Unauthorized.selector));
        }
        assertEq(box.admin(), admin);
        assertEq(box.pendingAdmin(), nextAdmin);
        assertEq(box.pendingOracle(), nextReviewer);
    }

    function test_AdminHandoverNeedsAcceptanceAndClearsOldProposal() public {
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.AdminTransferProposed(admin, nextAdmin);
        vm.prank(admin);
        box.transferAdmin(nextAdmin);
        assertEq(box.admin(), admin);
        assertEq(box.pendingAdmin(), nextAdmin);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(nextAdmin);
        box.proposeOracle(outsider);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(admin);
        box.acceptAdmin();
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(outsider);
        box.acceptAdmin();
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.AdminSet(nextAdmin);
        vm.prank(nextAdmin);
        box.acceptAdmin();
        assertEq(box.admin(), nextAdmin);
        assertEq(box.pendingAdmin(), address(0));
        assertEq(box.pendingOracle(), address(0));
        assertEq(box.oracleChangeAfter(), 0);
        assertEq(box.oracle(), reviewer);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.prank(nextAdmin);
        box.proposeOracle(nextReviewer);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(nextAdmin);
        box.confirmOracle();
        assertEq(box.oracle(), nextReviewer);
    }

    function test_CancelAdminHandoverPreventsAcceptance() public {
        vm.prank(admin);
        box.transferAdmin(nextAdmin);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.AdminTransferCancelled(nextAdmin);
        vm.prank(admin);
        box.cancelAdminTransfer();
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(nextAdmin);
        box.acceptAdmin();
        assertEq(box.admin(), admin);
        assertEq(box.pendingAdmin(), address(0));
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(admin);
        box.cancelAdminTransfer();
    }

    function test_ReplacingPendingAdminRevokesPreviousNominee() public {
        vm.prank(admin);
        box.transferAdmin(nextAdmin);
        vm.prank(admin);
        box.transferAdmin(outsider);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(nextAdmin);
        box.acceptAdmin();
        vm.prank(outsider);
        box.acceptAdmin();
        assertEq(box.admin(), outsider);
    }

    function test_ZeroAdminHandoverIsRejected() public {
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(admin);
        box.transferAdmin(address(0));
        assertEq(box.admin(), admin);
    }

    function test_NoNomineeCannotAcceptEvenFromZeroAddress() public {
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(nextAdmin);
        box.acceptAdmin();
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(address(0));
        box.acceptAdmin();
        assertEq(box.admin(), admin);
    }

    function test_RenounceClearsProposalsAndPermanentlyFreezesOracle() public {
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.prank(admin);
        box.transferAdmin(nextAdmin);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.AdminSet(address(0));
        vm.prank(admin);
        box.renounceAdmin();
        assertEq(box.admin(), address(0));
        assertEq(box.pendingAdmin(), address(0));
        assertEq(box.pendingOracle(), address(0));
        assertEq(box.oracleChangeAfter(), 0);
        vm.warp(block.timestamp + 100 days);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(admin);
        box.confirmOracle();
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(admin);
        box.transferAdmin(nextAdmin);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(nextAdmin);
        box.acceptAdmin();
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(address(0));
        box.proposeOracle(nextReviewer);
        assertEq(box.oracle(), reviewer);
    }

    function test_RenounceDoesNotDisablePendingOracleAnswerOrClaims() public {
        uint256 r = _dispute(alice);
        vm.prank(admin);
        box.renounceAdmin();
        vm.prank(reviewer);
        box.answer(r, true, 0, "accepted");
        vm.prank(alice);
        box.claim(job, payable(alice));
        assertEq(alice.balance, 10 ether);
        _assertSolvent();
    }

    function test_AdminCannotUseCreatorOracleOrBeneficiaryPowers() public {
        uint256 a = _submit(alice);
        vm.startPrank(admin);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        box.approve(job, a);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        box.reject(job, a, "no");
        vm.expectRevert(BountyBox.Unauthorized.selector);
        box.refund(job);
        vm.expectRevert(BountyBox.NothingToClaim.selector);
        box.claim(job, payable(admin));
        vm.stopPrank();
        _reject(a);
        vm.prank(alice);
        box.escalate(job);
        uint256 requestId = box.getJob(job).pendingRequestId;
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(admin);
        box.answer(requestId, true, 0, "no special privileges");
        _assertSolvent();
    }
}

contract BountyBoxRequestOracleTest is UpdateFixture {
    function test_EscalatedEventOrderAndSnapshot() public {
        uint256 id = _submit(alice);
        _reject(id);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.Escalated(job, id, 1);
        vm.prank(alice);
        box.escalate(job);
        BountyBox.Request memory r = box.getRequest(1);
        assertEq(r.oracle, reviewer);
        assertEq(r.submissionId, id);
        assertEq(r.requestedAt, block.timestamp);
        assertEq(r.settleAfter, block.timestamp + 7 days);
        assertFalse(r.resolved);
    }

    function test_RequestUsesOriginalOracleAfterRotation() public {
        uint256 r = _dispute(alice);
        _rotate(nextReviewer);
        assertEq(box.oracle(), nextReviewer);
        assertEq(box.getRequest(r).oracle, reviewer);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(nextReviewer);
        box.answer(r, true, 0, "replacement cannot decide old request");
        vm.prank(reviewer);
        box.answer(r, true, 0, "original reviewer");
        assertEq(box.claimable(job, alice), 10 ether);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(reviewer);
        box.answer(r, false, 0, "duplicate");
        _assertSolvent();
    }

    function test_NewRequestUsesNewOracleAndOldOracleLosesAuthority() public {
        uint256 old = _dispute(alice);
        _rotate(nextReviewer);
        vm.prank(reviewer);
        box.answer(old, false, 0, "revise");
        uint256 a = _submit(alice);
        _reject(a);
        vm.prank(alice);
        box.escalate(job);
        uint256 current = box.getJob(job).pendingRequestId;
        assertEq(box.getRequest(current).oracle, nextReviewer);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(reviewer);
        box.answer(current, true, 0, "old reviewer");
        vm.prank(nextReviewer);
        box.answer(current, true, 0, "accepted");
        assertEq(box.claimable(job, alice), 10 ether);
    }

    function test_ProposalDoesNotChangeOracleOfNewRequests() public {
        vm.prank(admin);
        box.proposeOracle(nextReviewer);
        vm.warp(block.timestamp + 24 hours);
        uint256 r = _dispute(alice);
        assertEq(box.getRequest(r).oracle, reviewer);
        vm.prank(admin);
        box.confirmOracle();
        assertEq(box.getRequest(r).oracle, reviewer);
    }

    function test_DeadOriginalOracleStillSplitsAtOriginalTimeout() public {
        uint256 r = _dispute(alice);
        uint256 until = box.getRequest(r).settleAfter;
        _rotate(nextReviewer);
        assertEq(box.getRequest(r).settleAfter, until);
        vm.warp(until);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(nextReviewer);
        box.answer(r, true, 0, "cannot take over");
        box.settleSplit(job);
        assertEq(box.claimable(job, creator), 6 ether);
        assertEq(box.claimable(job, alice), 4 ether);
    }

    function test_CreatorOracleCannotAnswerItsOwnJob() public {
        _rotate(creator);
        uint256 r = _dispute(alice);
        assertEq(box.getRequest(r).oracle, creator);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(creator);
        box.answer(r, false, 0, "conflicted");
        assertFalse(box.getRequest(r).resolved);
        vm.warp(box.getRequest(r).settleAfter);
        box.settleSplit(job);
        assertEq(box.claimable(job, alice), 4 ether);
    }

    function test_EscalatedWorkerOracleCannotAnswer() public {
        _rotate(alice);
        uint256 r = _dispute(alice);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(alice);
        box.answer(r, true, 0, "self award");
        assertEq(box.claimable(job, alice), 0);
        assertFalse(box.getRequest(r).resolved);
    }

    function test_CompetingWorkerOracleCannotAnswer() public {
        _submit(bob);
        _rotate(bob);
        uint256 r = _dispute(alice);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(bob);
        box.answer(r, false, 0, "competitor");
    }

    function test_ClosedWorkerOracleRemainsDisqualifiedAfterSlotRecycled() public {
        uint256 b = _submit(bob);
        _reject(b);
        vm.warp(block.timestamp + 2 days);
        box.closeSlot(job, bob);
        _submit(carol);
        _rotate(bob);
        uint256 r = _dispute(alice);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(bob);
        box.answer(r, true, 0, "still a participant");
        assertTrue(box.getWorker(job, bob).closed);
    }

    function test_ReviewerCanParticipateInOtherJob() public {
        vm.prank(creator);
        uint256 other = box.createJob{value: 1 ether}(BRIEF, block.timestamp + 1 days, "acceptance criteria");
        vm.prank(reviewer);
        box.submit(other, BRIEF, "ipfs://different-job");
        uint256 r = _dispute(alice);
        vm.prank(reviewer);
        box.answer(r, true, 0, "unconflicted here");
        assertEq(box.claimable(job, alice), 10 ether);
    }

    function test_AnswerOnlyOnceAfterFailedReview() public {
        uint256 r = _dispute(alice);
        vm.prank(reviewer);
        box.answer(r, false, 1, "no");
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(reviewer);
        box.answer(r, true, 0, "changed mind");
        assertEq(box.getWorker(job, alice).failedReviews, 1);
        assertEq(box.getWorker(job, alice).revisionDuration, 1 days);
        assertEq(box.claimable(job, alice), 0);
    }

    function test_UnknownRequestAndUnauthorizedOracleFail() public {
        vm.expectRevert(BountyBox.NotFound.selector);
        vm.prank(reviewer);
        box.answer(1, true, 0, "unknown");
        uint256 r = _dispute(alice);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(outsider);
        box.answer(r, true, 0, "unauthorized");
        assertFalse(box.getRequest(r).resolved);
    }
}
