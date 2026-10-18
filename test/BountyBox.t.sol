// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {BountyBox} from "../src/BountyBox.sol";

contract MockOracle {
    BountyBox public box;
    uint256 public lastRequest;
    bool public broken;
    bool public attack;
    bool public reentered;

    function configure(BountyBox box_) external {
        box = box_;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setAttack() external {
        attack = true;
    }

    function request(uint256 jobId, uint256 submissionId) external {
        require(msg.sender == address(box));
        require(!broken, "offline");
        (uint256 id, bytes32 hash, BountyBox.Submission memory latest, string[] memory reasons) =
            box.getOracleContext(jobId);
        require(hash != bytes32(0) && latest.jobId == jobId && box.getRequest(id).submissionId == submissionId);
        lastRequest = id;
        if (attack) {
            (reentered,) = address(box).call(abi.encodeCall(box.answer, (id, true, 0, "sync")));
        }
        reasons;
    }

    function answer(uint256 id, bool ok, uint256 seconds_, string memory reason) external {
        box.answer(id, ok, seconds_, reason);
    }
}

contract PayoutReceiver {
    BountyBox public box;
    uint256 public jobId;
    bool public deny;
    bool public reentered;
    bool public stateWasSettled;

    constructor(BountyBox b) {
        box = b;
    }

    function setDeny(bool value) external {
        deny = value;
    }

    function submit(uint256 job) external {
        jobId = job;
        box.submit(job, keccak256("work"), "ipfs://work");
    }

    function claim(address payable recipient) external {
        box.claim(jobId, recipient);
    }

    receive() external payable {
        require(!deny, "reject ETH");
        stateWasSettled = box.claimable(jobId, address(this)) == 0;
        (reentered,) = address(box).call(abi.encodeCall(box.claim, (jobId, payable(address(this)))));
    }
}

contract BountyBoxTest is Test {
    BountyBox box;
    MockOracle oracle;
    address creator = address(0xC0);
    address alice = address(0xA1);
    address bob = address(0xB0);
    address carol = address(0xCA);
    address dave = address(0xDA);
    bytes32 constant HASH = keccak256("Build a beautiful site");
    bytes32 constant WORK = keccak256("delivered bytes");
    uint256 job;

    function setUp() public {
        vm.warp(10 days);
        oracle = new MockOracle();
        box = new BountyBox(address(oracle), address(this));
        oracle.configure(box);
        vm.deal(creator, 100 ether);
        job = _create(10 ether, block.timestamp + 10 days);
    }

    function _create(uint256 amount, uint256 deadline) internal returns (uint256) {
        vm.prank(creator);
        return box.createJob{value: amount}(HASH, deadline, "Build a beautiful site");
    }

    function _submit(address worker) internal returns (uint256) {
        vm.prank(worker);
        return box.submit(job, WORK, "ipfs://work");
    }

    function _reject(uint256 id) internal {
        vm.prank(creator);
        box.reject(job, id, "Missing acceptance criterion");
    }

    function _escalate(address worker) internal returns (uint256) {
        vm.prank(worker);
        box.escalate(job);
        return box.getJob(job).pendingRequestId;
    }

    function _dispute(address worker) internal returns (uint256) {
        uint256 id = _submit(worker);
        _reject(id);
        return _escalate(worker);
    }

    function _solvent() internal view {
        assertEq(address(box).balance, box.totalEscrow() + box.totalClaimable());
    }

    function _state(uint256 id, BountyBox.SubmissionState expected) internal view {
        assertEq(uint256(box.getSubmission(id).state), uint256(expected));
    }

    function test_ConstructorNoCodeRequiredAndExplicitAdmin() public {
        BountyBox empty = new BountyBox(address(0x1234), address(this));
        assertEq(empty.oracle(), address(0x1234));
        assertEq(empty.admin(), address(this));
        (bool ownerExists,) = address(empty).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ownerExists);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        new BountyBox(address(0), address(this));
        assertLe(address(box).code.length, 24576);
    }

    function test_CreateHashTextEventAndEscrow() public {
        vm.recordLogs();
        uint256 id = _create(1 ether, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        (bytes32 hash, string memory text, uint256 amount, uint256 deadline) =
            abi.decode(logs[0].data, (bytes32, string, uint256, uint256));
        assertEq(hash, HASH);
        assertEq(text, "Build a beautiful site");
        assertEq(amount, 1 ether);
        assertEq(deadline, block.timestamp + 1);
        assertEq(box.getJob(id).creator, creator);
        _solvent();
    }

    function test_TwoArgumentCreateRequiresKnownPreimage() public {
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(creator);
        box.createJob{value: 1}(HASH, block.timestamp + 1);
        assertEq(box.publishJobText("Build a beautiful site"), HASH);
        vm.prank(creator);
        uint256 id = box.createJob{value: 1}(HASH, block.timestamp + 1);
        assertEq(box.getJob(id).jobHash, HASH);
    }

    function test_InvalidCreateAndText() public {
        vm.expectRevert(BountyBox.InvalidInput.selector);
        _create(0, block.timestamp + 1);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        _create(1, block.timestamp);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        box.createJob(HASH, block.timestamp + 1, "different");
        vm.expectRevert(BountyBox.InvalidInput.selector);
        box.publishJobText("");
        vm.expectRevert(BountyBox.InvalidInput.selector);
        box.publishJobText(new string(8193));
        vm.expectRevert(BountyBox.NotFound.selector);
        box.getJob(999);
    }

    function test_RefundEmptyJobAnyTimePullOnly() public {
        uint256 before_ = creator.balance;
        vm.prank(creator);
        box.refund(job);
        assertEq(creator.balance, before_);
        assertEq(box.claimable(job, creator), 10 ether);
        assertEq(uint256(box.getJob(job).state), uint256(BountyBox.JobState.Refunded));
        vm.prank(creator);
        box.claim(job, payable(creator));
        assertEq(creator.balance, before_ + 10 ether);
        _solvent();
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.refund(job);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _submit(alice);
    }

    function test_RefundCannotStealActiveOrSilentSubmission() public {
        uint256 id = _submit(alice);
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        vm.warp(box.getSubmission(id).reviewUntil + 30 days - 1);
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        _escalate(alice);
        vm.expectRevert(BountyBox.OraclePending.selector);
        vm.prank(creator);
        box.refund(job);
    }

    function test_CreatorAndOutsiderAccess() public {
        vm.expectRevert(BountyBox.Unauthorized.selector);
        _submit(creator);
        uint256 id = _submit(alice);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(bob);
        box.approve(job, id);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(bob);
        box.reject(job, id, "no");
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(bob);
        box.refund(job);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(bob);
        box.escalate(job);
        uint256 r = _dispute(bob);
        vm.expectRevert(BountyBox.Unauthorized.selector);
        box.answer(r, true, 0, "");
    }

    function test_ThreeDistinctSlotsAndDuplicatePendingBlocked() public {
        _submit(alice);
        _submit(bob);
        _submit(carol);
        vm.expectRevert(BountyBox.LimitReached.selector);
        _submit(dave);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _submit(alice);
        assertEq(box.getJob(job).workerCount, 3);
    }

    function test_FirstSubmitStrictDeadlineAndInvalidHashLink() public {
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(alice);
        box.submit(job, bytes32(0), "link");
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(alice);
        box.submit(job, WORK, "");
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(alice);
        box.submit(job, WORK, new string(2049));
        vm.warp(box.getJob(job).deadline - 1);
        _submit(alice);
        vm.warp(box.getJob(job).deadline);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        _submit(bob);
    }

    function test_ApproveFinalizesCancelsOthersAndPullClaim() public {
        uint256 a = _submit(alice);
        uint256 b = _submit(bob);
        uint256 c = _submit(carol);
        _reject(c);
        vm.prank(creator);
        box.approve(job, a);
        _state(a, BountyBox.SubmissionState.Approved);
        _state(b, BountyBox.SubmissionState.Cancelled);
        _state(c, BountyBox.SubmissionState.Cancelled);
        assertEq(box.getJob(job).winnerSubmissionId, a);
        assertEq(box.claimable(job, alice), 10 ether);
        assertEq(alice.balance, 0);
        vm.prank(alice);
        box.claim(job, payable(alice));
        assertEq(alice.balance, 10 ether);
        _solvent();
        vm.expectRevert(BountyBox.NothingToClaim.selector);
        vm.prank(alice);
        box.claim(job, payable(alice));
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.approve(job, b);
        vm.expectRevert(BountyBox.NothingToClaim.selector);
        vm.prank(bob);
        box.claim(job, payable(bob));
    }

    function test_RejectReasonAndRevisionAfterDeadline() public {
        vm.warp(box.getJob(job).deadline - 1);
        uint256 a = _submit(alice);
        _reject(a);
        assertEq(box.getSubmission(a).reason, "Missing acceptance criterion");
        assertEq(box.getWorker(job, alice).revisionUntil, block.timestamp + 48 hours);
        vm.warp(block.timestamp + 1 hours);
        uint256 b = _submit(alice);
        _state(a, BountyBox.SubmissionState.Superseded);
        _state(b, BountyBox.SubmissionState.Pending);
        assertEq(box.getWorker(job, alice).submissionCount, 2);
        assertEq(box.getJob(job).workerCount, 1);
        assertEq(box.getSubmission(b).reviewUntil, block.timestamp + 3 days);
    }

    function test_RejectionCannotDuplicateOrBeEmpty() public {
        uint256 a = _submit(alice);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(creator);
        box.reject(job, a, "");
        vm.expectRevert(BountyBox.InvalidInput.selector);
        vm.prank(creator);
        box.reject(job, a, new string(1025));
        _reject(a);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _reject(a);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.approve(job, a);
    }

    function test_ReviewBoundaryGivesEscalationAndApprovalButNotRejection() public {
        uint256 a = _submit(alice);
        vm.warp(box.getSubmission(a).reviewUntil - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        _escalate(alice);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        _reject(a);
        uint256 b = _submit(bob);
        _escalate(alice);
        _state(a, BountyBox.SubmissionState.Escalated);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.approve(job, a);
        vm.prank(creator);
        box.approve(job, b);
        _state(a, BountyBox.SubmissionState.Cancelled);
    }

    function test_ThirdCreatorRejectionAutomaticallyEscalates() public {
        uint256 id;
        for (uint256 i; i < 3; ++i) {
            id = _submit(alice);
            _reject(id);
        }
        assertEq(box.getWorker(job, alice).rejections, 3);
        assertEq(box.getJob(job).pendingRequestId, 1);
        assertEq(oracle.lastRequest(), 0); // Escalation never calls the oracle.
        _state(id, BountyBox.SubmissionState.Escalated);
        (uint256 requestId, bytes32 hash, BountyBox.Submission memory latest, string[] memory reasons) =
            box.getOracleContext(job);
        assertEq(requestId, 1);
        assertEq(hash, HASH);
        assertEq(latest.contentHash, WORK);
        assertEq(reasons.length, 3);
    }

    function test_OneRequestLocksOtherActionsAndCannotBeOverwritten() public {
        uint256 b = _submit(bob);
        _dispute(alice);
        vm.expectRevert(BountyBox.OraclePending.selector);
        _reject(b);
        vm.expectRevert(BountyBox.OraclePending.selector);
        _submit(carol);
        vm.expectRevert(BountyBox.OraclePending.selector);
        _escalate(bob);
        vm.expectRevert(BountyBox.OraclePending.selector);
        box.closeSlot(job, alice);
        assertEq(box.requestCount(), 1);
        vm.prank(creator);
        box.approve(job, b);
        assertTrue(box.getRequest(1).resolved);
        assertEq(box.claimable(job, bob), 10 ether);
    }

    function test_OracleYesFinalizesWithFullPayoutAndRejectsReplay() public {
        uint256 b = _submit(bob);
        uint256 r = _dispute(alice);
        oracle.answer(r, true, 0, "Criteria met");
        assertEq(box.claimable(job, alice), 10 ether);
        _state(b, BountyBox.SubmissionState.Cancelled);
        vm.expectRevert(BountyBox.InvalidState.selector);
        oracle.answer(r, false, 0, "replayed");
        vm.expectRevert(BountyBox.InvalidState.selector);
        oracle.answer(r, true, 0, "");
        assertEq(box.claimable(job, alice), 10 ether);
        assertEq(box.getWorker(job, alice).failedReviews, 0);
        _solvent();
    }

    function test_OracleNoStoresFailedReviewRetainsSlotAndAllowsRevision() public {
        uint256 r = _dispute(alice);
        oracle.answer(r, false, 0, "Tests fail");
        BountyBox.Worker memory w = box.getWorker(job, alice);
        _state(w.latestSubmissionId, BountyBox.SubmissionState.FailedReview);
        assertEq(box.getSubmission(w.latestSubmissionId).reason, "Tests fail");
        assertEq(w.revisionUntil, block.timestamp + 48 hours);
        assertFalse(w.closed);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _escalate(alice);
        _submit(alice);
        assertEq(box.getWorker(job, alice).submissionCount, 2);
        _solvent();
    }

    function test_OracleNoClampsMinimumAndMaximumAndDefaultReason() public {
        uint256 r = _dispute(alice);
        oracle.answer(r, false, 1, "");
        assertEq(box.getWorker(job, alice).revisionDuration, 1 days);
        assertEq(box.getSubmission(1).reason, "Oracle failed review");
        uint256 a = _submit(alice);
        _reject(a);
        r = _escalate(alice);
        oracle.answer(r, false, type(uint256).max, "no");
        assertEq(box.getWorker(job, alice).revisionDuration, 7 days);
    }

    function test_ThreeFailedReviewsCloseSlotPermanently() public {
        for (uint256 i; i < 3; ++i) {
            uint256 a = _submit(alice);
            _reject(a);
            uint256 r = box.getJob(job).pendingRequestId;
            if (r == 0) r = _escalate(alice);
            oracle.answer(r, false, 0, "Not accepted");
        }
        assertTrue(box.getWorker(job, alice).closed);
        assertEq(box.getWorker(job, alice).failedReviews, 3);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _submit(alice);
        vm.prank(creator);
        box.refund(job);
        assertEq(box.claimable(job, creator), 10 ether);
        _solvent();
    }

    function test_FiveTotalSubmissionsNotFiveRevisions() public {
        // A fresh job can reach five attempts using two creator rejects and two oracle failures.
        job = _create(1 ether, block.timestamp + 30 days);
        for (uint256 i; i < 5; ++i) {
            uint256 a = _submit(alice);
            if (i < 2) {
                _reject(a);
            } else if (i < 4) {
                vm.warp(box.getSubmission(a).reviewUntil);
                uint256 r = _escalate(alice);
                oracle.answer(r, false, 0, "no");
            } else {
                _reject(a); // third creator reject -> request; fifth still has review rights
            }
        }
        assertEq(box.getWorker(job, alice).submissionCount, 5);
        oracle.answer(box.getJob(job).pendingRequestId, false, 0, "no");
        vm.expectRevert(BountyBox.InvalidState.selector);
        _submit(alice);
    }

    function test_FifthAttemptCanStillWin() public {
        for (uint256 i; i < 4; ++i) {
            uint256 a = _submit(alice);
            if (i < 2) {
                _reject(a);
            } else {
                vm.warp(box.getSubmission(a).reviewUntil);
                uint256 r = _escalate(alice);
                oracle.answer(r, false, 0, "no");
            }
        }
        uint256 fifth = _submit(alice);
        vm.expectRevert(BountyBox.LimitReached.selector);
        _submit(alice);
        vm.prank(creator);
        box.approve(job, fifth);
        assertEq(box.claimable(job, alice), 10 ether);
    }

    function test_RevisionBoundaryExpiresAndAnyoneCloses() public {
        uint256 a = _submit(alice);
        _reject(a);
        vm.warp(box.getWorker(job, alice).revisionUntil - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.closeSlot(job, alice);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        _submit(alice);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        _escalate(alice);
        box.closeSlot(job, alice);
        assertTrue(box.getWorker(job, alice).closed);
        vm.expectRevert(BountyBox.InvalidState.selector);
        box.closeSlot(job, alice);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _submit(alice);
    }

    function test_ClosedSlotsRecycleForFourthDistinctWorker() public {
        uint256 a = _submit(alice);
        uint256 b = _submit(bob);
        uint256 c = _submit(carol);
        _reject(a);
        _reject(b);
        _reject(c);
        vm.warp(block.timestamp + 48 hours);
        box.closeSlot(job, alice);
        box.closeSlot(job, bob);
        box.closeSlot(job, carol);
        assertEq(box.getJob(job).workerCount, 0);
        uint256 replacement = _submit(dave);
        assertEq(box.getJob(job).workerCount, 1);
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        vm.prank(creator);
        box.approve(job, replacement);
    }

    function test_RefundAutoClosesExpiredButCannotBypassOtherPendingWorker() public {
        uint256 a = _submit(alice);
        uint256 b = _submit(bob);
        _reject(a);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        assertFalse(box.getWorker(job, alice).closed); // atomic rollback
        _reject(b);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(creator);
        box.refund(job);
        assertTrue(box.getWorker(job, alice).closed);
        _solvent();
    }

    function test_PausedClocksResumeWithoutRevivingExpiredWindows() public {
        uint256 a = _submit(alice);
        _reject(a);
        vm.warp(block.timestamp + 48 hours);
        uint256 b = _submit(bob);
        _reject(b);
        uint256 original = box.getWorker(job, bob).revisionUntil;
        uint256 r = _dispute(carol);
        vm.warp(block.timestamp + 3 days);
        oracle.answer(r, false, 0, "no");
        assertEq(box.getWorker(job, bob).revisionUntil, original + 3 days);
        assertEq(box.getWorker(job, alice).revisionUntil, original - 48 hours);
        box.closeSlot(job, alice);
        _submit(bob);
    }

    function test_PendingReviewClockPauses() public {
        uint256 b = _submit(bob);
        uint256 original = box.getSubmission(b).reviewUntil;
        uint256 r = _dispute(alice);
        vm.warp(block.timestamp + 4 days);
        oracle.answer(r, false, 0, "no");
        assertEq(box.getSubmission(b).reviewUntil, original + 4 days);
        vm.prank(creator);
        box.approve(job, b);
    }

    function test_SplitIgnoresLaterDeadlineAndLateAnswerIgnoredBeforeSettlement() public {
        uint256 r = _dispute(alice);
        BountyBox.Request memory req = box.getRequest(r);
        assertEq(req.settleAfter, req.requestedAt + 7 days);
        assertLt(req.settleAfter, box.getJob(job).deadline);
        vm.warp(req.settleAfter - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.settleSplit(job);
        vm.warp(req.settleAfter);
        oracle.answer(r, true, 0, "too late");
        assertEq(box.getJob(job).pendingRequestId, r);
        vm.prank(dave);
        box.settleSplit(job);
        assertEq(box.claimable(job, creator), 6 ether);
        assertEq(box.claimable(job, alice), 4 ether);
        vm.expectRevert(BountyBox.InvalidState.selector);
        oracle.answer(r, true, 0, "late again");
        assertEq(box.claimable(job, alice), 4 ether);
        _solvent();
        vm.expectRevert(BountyBox.InvalidState.selector);
        box.settleSplit(job);
    }

    function test_SplitWaitsSevenDaysWhenDeadlineEarlier() public {
        job = _create(1 ether, block.timestamp + 1);
        uint256 a = _submit(alice);
        vm.warp(box.getSubmission(a).reviewUntil);
        uint256 r = _escalate(alice);
        uint256 until = box.getRequest(r).settleAfter;
        assertEq(until, block.timestamp + 7 days);
        vm.warp(until - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.settleSplit(job);
        vm.warp(until);
        box.settleSplit(job);
        _solvent();
    }

    function test_UnavailableReviewerAndNoCodeStillHaveFallback() public {
        oracle.setBroken(true);
        uint256 r = _dispute(alice);
        vm.warp(box.getRequest(r).settleAfter);
        box.settleSplit(job);
        _solvent();
        box = new BountyBox(address(0x456), address(this));
        job = _create(1 ether, block.timestamp + 1);
        r = _dispute(alice);
        vm.warp(box.getRequest(r).settleAfter);
        box.settleSplit(job);
        _solvent();
    }

    function test_EscalationMakesNoOracleCall() public {
        oracle.setAttack();
        _dispute(alice);
        assertFalse(oracle.reentered());
        assertEq(oracle.lastRequest(), 0);
        assertEq(box.claimable(job, alice), 0);
        oracle.answer(1, true, 0, "async");
        assertEq(box.claimable(job, alice), 10 ether);
    }

    function test_UnknownRequestAndOldRequestCannotAnswerNewOne() public {
        vm.expectRevert(BountyBox.NotFound.selector);
        oracle.answer(999, true, 0, "");
        uint256 old = _dispute(alice);
        oracle.answer(old, false, 0, "no");
        uint256 a = _submit(alice);
        _reject(a);
        uint256 current = _escalate(alice);
        vm.expectRevert(BountyBox.InvalidState.selector);
        oracle.answer(old, true, 0, "replay");
        assertEq(box.getJob(job).pendingRequestId, current);
        assertEq(box.claimable(job, alice), 0);
    }

    function test_CrossJobSubmissionIdsAndRequestsAreIsolated() public {
        uint256 a = _submit(alice);
        uint256 other = _create(2 ether, block.timestamp + 10 days);
        vm.expectRevert(BountyBox.InvalidState.selector);
        vm.prank(creator);
        box.approve(other, a);
        _reject(a);
        uint256 r = _escalate(alice);
        job = other;
        uint256 otherR = _dispute(bob);
        oracle.answer(r, true, 0, "");
        assertEq(box.getJob(other).pendingRequestId, otherR);
        oracle.answer(otherR, false, 0, "no");
        _solvent();
    }

    function test_RevertingReceiverCannotBlockFinalizationAndCanRedirect() public {
        PayoutReceiver receiver = new PayoutReceiver(box);
        receiver.submit(job);
        receiver.setDeny(true);
        uint256 submission = box.getWorker(job, address(receiver)).latestSubmissionId;
        vm.prank(creator);
        box.approve(job, submission);
        vm.expectRevert(BountyBox.TransferFailed.selector);
        receiver.claim(payable(address(receiver)));
        assertEq(box.claimable(job, address(receiver)), 10 ether);
        receiver.claim(payable(bob));
        assertEq(bob.balance, 10 ether);
        _solvent();
    }

    function test_ClaimGuardAndChecksEffectsInteractions() public {
        PayoutReceiver receiver = new PayoutReceiver(box);
        receiver.submit(job);
        uint256 submission = box.getWorker(job, address(receiver)).latestSubmissionId;
        vm.prank(creator);
        box.approve(job, submission);
        receiver.claim(payable(address(receiver)));
        assertFalse(receiver.reentered());
        assertTrue(receiver.stateWasSettled());
        assertEq(address(receiver).balance, 10 ether);
        _solvent();
    }

    function test_InvalidClaimAndDirectEtherRejected() public {
        vm.expectRevert(BountyBox.InvalidInput.selector);
        box.claim(job, payable(address(0)));
        vm.expectRevert(BountyBox.NothingToClaim.selector);
        box.claim(job, payable(alice));
        vm.deal(address(this), 1 ether);
        (bool success,) = address(box).call{value: 1}("");
        assertFalse(success);
    }

    function test_AllKeyAuditEvents() public {
        vm.recordLogs();
        uint256 a = _submit(alice);
        _reject(a);
        _submit(alice);
        uint256 latest = box.getWorker(job, alice).latestSubmissionId;
        vm.warp(box.getSubmission(latest).reviewUntil);
        uint256 r = _escalate(alice);
        oracle.answer(r, false, 0, "no");
        vm.warp(box.getWorker(job, alice).revisionUntil);
        box.closeSlot(job, alice);
        vm.prank(creator);
        box.refund(job);
        vm.prank(creator);
        box.claim(job, payable(creator));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[8] memory signatures = [
            keccak256("Submitted(uint256,uint256,address,bytes32,string,uint256)"),
            keccak256("Rejected(uint256,uint256,address,string,uint256,uint8)"),
            keccak256("Resubmitted(uint256,uint256,address,uint256)"),
            keccak256("Escalated(uint256,uint256,uint256)"),
            keccak256("OracleAnswered(uint256,uint256,uint256,address,bool,string,uint256)"),
            keccak256("SlotClosed(uint256,address,uint8)"),
            keccak256("Refunded(uint256,address,uint256)"),
            keccak256("Paid(uint256,address,address,uint256)")
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bool found;
            for (uint256 k; k < logs.length; ++k) {
                if (logs[k].topics[0] == signatures[i]) found = true;
            }
            assertTrue(found, "missing audit event");
        }
    }

    function test_RuntimeContainsNoEscapeOpcodes() public view {
        bytes memory code = address(box).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_OracleCannotResetDeadlineWithOversizedReason() public {
        uint256 r = _dispute(alice);
        uint256 until = box.getRequest(r).settleAfter;
        vm.expectRevert(BountyBox.InvalidInput.selector);
        oracle.answer(r, false, 0, new string(1025));
        assertEq(box.getRequest(r).settleAfter, until);
        assertFalse(box.getRequest(r).resolved);
        vm.warp(until);
        box.settleSplit(job);
        _solvent();
    }

    function test_ApprovalAndSplitAuditEvents() public {
        uint256 a = _submit(alice);
        vm.recordLogs();
        vm.prank(creator);
        box.approve(job, a);
        Vm.Log[] memory approved = vm.getRecordedLogs();
        assertEq(approved[0].topics[0], keccak256("Approved(uint256,uint256,address)"));
        job = _create(1 ether, block.timestamp + 1);
        uint256 r = _dispute(alice);
        vm.warp(box.getRequest(r).settleAfter);
        vm.recordLogs();
        box.settleSplit(job);
        Vm.Log[] memory split = vm.getRecordedLogs();
        assertEq(split[split.length - 1].topics[0], keccak256("Split(uint256,uint256,address,uint256,uint256)"));
        (uint256 creatorAmount, uint256 workerAmount) = abi.decode(split[split.length - 1].data, (uint256, uint256));
        assertEq(creatorAmount, 0.6 ether);
        assertEq(workerAmount, 0.4 ether);
    }

    function testFuzz_SplitConservesEveryWei(uint128 raw) public {
        uint256 amount = uint256(raw) + 1;
        vm.deal(creator, amount);
        job = _create(amount, block.timestamp + 1);
        uint256 r = _dispute(alice);
        vm.warp(box.getRequest(r).settleAfter);
        box.settleSplit(job);
        uint256 workerShare = amount * 40 / 100;
        assertEq(box.claimable(job, alice), workerShare);
        assertEq(box.claimable(job, creator), amount - workerShare);
        _solvent();
        if (workerShare > 0) {
            vm.prank(alice);
            box.claim(job, payable(alice));
        }
        vm.prank(creator);
        box.claim(job, payable(creator));
        _solvent();
    }

    function testFuzz_OracleRevisionClamp(uint256 seconds_) public {
        uint256 r = _dispute(alice);
        oracle.answer(r, false, seconds_, "no");
        uint256 expected = seconds_ == 0 ? 2 days : seconds_;
        if (expected < 1 days) expected = 1 days;
        if (expected > 7 days) expected = 7 days;
        assertEq(box.getWorker(job, alice).revisionUntil, block.timestamp + expected);
        _solvent();
    }

    function testFuzz_ClaimCannotChangeBeneficiary(address attacker) public {
        vm.assume(attacker != alice && attacker != address(vm));
        uint256 a = _submit(alice);
        vm.prank(creator);
        box.approve(job, a);
        vm.expectRevert(BountyBox.NothingToClaim.selector);
        vm.prank(attacker);
        box.claim(job, payable(bob));
        assertEq(box.claimable(job, alice), 10 ether);
        _solvent();
    }
}
