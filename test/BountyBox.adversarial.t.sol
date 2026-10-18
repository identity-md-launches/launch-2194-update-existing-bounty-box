// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {BountyBox} from "src/BountyBox.sol";

contract RejectBountyPayment {
    receive() external payable {
        revert("payment rejected");
    }
}

/// @dev A receiver that attempts a different job's claim during an ETH callback.
contract CrossJobClaimReceiver {
    BountyBox immutable box;
    uint256 public otherJob;
    bool public callbackRan;
    bool public nestedSucceeded;
    bytes public nestedError;

    constructor(BountyBox box_) {
        box = box_;
    }

    function claim(uint256 job, uint256 other) external {
        otherJob = other;
        box.claim(job, payable(address(this)));
    }

    receive() external payable {
        callbackRan = true;
        (nestedSucceeded, nestedError) =
            address(box).call(abi.encodeCall(box.claim, (otherJob, payable(address(this)))));
    }
}

contract BountyBoxAdversarialTest is Test {
    BountyBox box;
    address admin = makeAddr("adversarial admin");
    address reviewer = makeAddr("adversarial reviewer");
    address creator = makeAddr("adversarial creator");
    address alice = makeAddr("adversarial alice");
    address bob = makeAddr("adversarial bob");
    address carol = makeAddr("adversarial carol");
    address outsider = makeAddr("adversarial outsider");
    bytes32 constant BRIEF = keccak256("deliver the specified work");

    function setUp() public {
        vm.warp(100 days);
        box = new BountyBox(reviewer, admin);
    }

    function _create(uint256 amount) internal returns (uint256) {
        vm.deal(creator, amount);
        vm.prank(creator);
        return box.createJob{value: amount}(BRIEF, vm.getBlockTimestamp() + 90 days, "deliver the specified work");
    }

    function _submit(uint256 job, address worker) internal returns (uint256) {
        vm.prank(worker);
        return box.submit(job, keccak256(abi.encode(job, worker)), "ipfs://work");
    }

    function _reject(uint256 job, uint256 id) internal {
        vm.prank(creator);
        box.reject(job, id, "revise");
    }

    function _request(uint256 job, address worker) internal returns (uint256) {
        uint256 id = _submit(job, worker);
        _reject(job, id);
        vm.prank(worker);
        box.escalate(job);
        return box.getJob(job).pendingRequestId;
    }

    function _assertState(uint256 id, BountyBox.SubmissionState expected) internal view {
        assertEq(uint256(box.getSubmission(id).state), uint256(expected));
    }

    function _assertCancellationLogs(Vm.Log[] memory logs, uint256 job, uint256[] memory ids, uint256 winner)
        internal
        view
    {
        uint256 cancelled;
        uint256 byApproval;
        bool[] memory seen = new bool[](ids.length);
        bool[] memory seenApproval = new bool[](ids.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(box)) continue;
            bool ordinary = logs[i].topics[0] == keccak256("Cancelled(uint256,uint256)");
            bool approval = logs[i].topics[0] == keccak256("CancelledByApproval(uint256,uint256,uint256)");
            if (!ordinary && !approval) continue;
            assertEq(logs[i].topics[1], bytes32(job));
            assertEq(logs[i].data.length, 0);
            bool known;
            for (uint256 k; k < ids.length; ++k) {
                if (logs[i].topics[2] != bytes32(ids[k])) continue;
                known = true;
                if (ordinary) {
                    assertFalse(seen[k], "duplicate cancellation");
                    seen[k] = true;
                    ++cancelled;
                } else {
                    assertFalse(seenApproval[k], "duplicate approval cancellation");
                    seenApproval[k] = true;
                    assertEq(logs[i].topics[3], bytes32(winner));
                    ++byApproval;
                }
            }
            assertTrue(known, "cancelled a historical or unrelated submission");
        }
        assertEq(cancelled, ids.length);
        assertEq(byApproval, winner == 0 ? 0 : ids.length);
    }

    function test_RefundMixedStatesCancelsExactlyTheLatestLiveVersions() public {
        uint256 job = _create(13);
        uint256 history = _submit(job, alice);
        _reject(job, history);
        uint256 a = _submit(job, alice);
        uint256 b = _submit(job, bob);
        _reject(job, b);
        uint256 request = _request(job, carol);
        uint256 c = box.getRequest(request).submissionId;
        vm.prank(reviewer);
        box.answer(request, false, 7 days, "failed");
        vm.warp(box.getSubmission(a).reviewUntil + 30 days);
        vm.recordLogs();
        vm.prank(creator);
        box.refund(job);
        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
        _assertCancellationLogs(vm.getRecordedLogs(), job, ids, 0);
        _assertState(history, BountyBox.SubmissionState.Superseded);
        for (uint256 i; i < ids.length; ++i) {
            _assertState(ids[i], BountyBox.SubmissionState.Cancelled);
        }
        assertEq(box.getJob(job).workerCount, 0);
        assertEq(box.claimable(job, creator), 13);
        assertEq(box.totalEscrow(), 0);
        assertEq(box.totalClaimable(), 13);
        vm.prank(creator);
        box.claim(job, payable(creator));
        assertEq(creator.balance, 13);
        assertEq(address(box).balance, 0);
    }

    function test_RefundRollsBackBothClosuresAndParticipantSwaps() public {
        uint256 job = _create(17);
        uint256 a = _submit(job, alice);
        uint256 b = _submit(job, bob);
        uint256 c = _submit(job, carol);
        _reject(job, a);
        _reject(job, c);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        // Packed iteration closes Alice, then Carol, and only then encounters live Bob.
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        address[3] memory members = box.getParticipants(job);
        assertEq(members[0], alice);
        assertEq(members[1], bob);
        assertEq(members[2], carol);
        assertFalse(box.getWorker(job, alice).closed);
        assertFalse(box.getWorker(job, carol).closed);
        _assertState(a, BountyBox.SubmissionState.Rejected);
        _assertState(b, BountyBox.SubmissionState.Pending);
        _assertState(c, BountyBox.SubmissionState.Rejected);
        assertEq(box.getJob(job).workerCount, 3);
        assertEq(box.totalEscrow(), 17);
        assertEq(box.totalClaimable(), 0);
        // A successful operation after the revert also checks that the guard was rolled back.
        vm.prank(creator);
        box.approve(job, b);
        assertEq(box.claimable(job, bob), 17);
    }

    function test_ApprovalCancelsFailedReviewButLeavesSupersededHistory() public {
        uint256 job = _create(9);
        uint256 old = _submit(job, alice);
        _reject(job, old);
        uint256 winner = _submit(job, alice);
        uint256 request = _request(job, bob);
        uint256 failed = box.getRequest(request).submissionId;
        vm.prank(reviewer);
        box.answer(request, false, 0, "review failure");
        vm.recordLogs();
        vm.prank(creator);
        box.approve(job, winner);
        uint256[] memory ids = new uint256[](1);
        ids[0] = failed;
        _assertCancellationLogs(vm.getRecordedLogs(), job, ids, winner);
        _assertState(old, BountyBox.SubmissionState.Superseded);
        _assertState(failed, BountyBox.SubmissionState.Cancelled);
        assertEq(box.getSubmission(failed).reason, "review failure");
        assertEq(box.getWorker(job, bob).failedReviews, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ClosingAnyPackedSlotLeavesEveryOtherWorkerReachable(uint8 rawIndex) public {
        uint256 job = _create(11);
        address[3] memory workers = [alice, bob, carol];
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = _submit(job, workers[i]);
        }
        uint256 index = bound(rawIndex, 0, 2);
        _reject(job, ids[index]);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(outsider);
        box.closeSlot(job, workers[index]);
        assertEq(box.getJob(job).workerCount, 2);
        uint256 replacement = _submit(job, outsider);
        vm.expectRevert(BountyBox.InvalidState.selector);
        _submit(job, workers[index]);
        vm.recordLogs();
        vm.prank(creator);
        box.approve(job, replacement);
        uint256[] memory losers = new uint256[](2);
        uint256 cursor;
        for (uint256 i; i < 3; ++i) {
            if (i != index) losers[cursor++] = ids[i];
            _assertState(ids[i], BountyBox.SubmissionState.Cancelled);
        }
        _assertCancellationLogs(vm.getRecordedLogs(), job, losers, replacement);
        assertEq(box.claimable(job, outsider), 11);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FailedDisputePreservesRemainingAbandonmentTime(uint256 elapsed, uint256 pause) public {
        uint256 job = _create(7);
        uint256 id = _submit(job, alice);
        uint256 originalReview = box.getSubmission(id).reviewUntil;
        elapsed = bound(elapsed, 0, 33 days - 1);
        pause = bound(pause, 0, 7 days - 1);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 remaining = originalReview + 30 days - vm.getBlockTimestamp();
        uint256 request = _request(job, bob);
        vm.warp(vm.getBlockTimestamp() + pause);
        vm.prank(reviewer);
        box.answer(request, false, 0, "revise");
        uint256 closesAt = box.getSubmission(id).reviewUntil + 30 days;
        assertEq(closesAt - vm.getBlockTimestamp(), remaining);
        vm.warp(closesAt - 1);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.closeSlot(job, alice);
        vm.expectRevert(BountyBox.ActiveWorkers.selector);
        vm.prank(creator);
        box.refund(job);
        vm.warp(closesAt);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        vm.prank(alice);
        box.escalate(job);
        box.closeSlot(job, alice);
        _assertState(id, BountyBox.SubmissionState.Cancelled);
    }

    function test_ZeroReplacementDoesNotEraseMatureOracleOrAdminProposals() public {
        vm.startPrank(admin);
        box.proposeOracle(bob);
        box.transferAdmin(carol);
        vm.stopPrank();
        uint256 until = box.oracleChangeAfter();
        vm.warp(until);
        vm.startPrank(admin);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        box.proposeOracle(address(0));
        vm.expectRevert(BountyBox.InvalidInput.selector);
        box.transferAdmin(address(0));
        vm.stopPrank();
        assertEq(box.pendingOracle(), bob);
        assertEq(box.oracleChangeAfter(), until);
        assertEq(box.pendingAdmin(), carol);
        vm.prank(admin);
        box.confirmOracle();
        vm.prank(carol);
        box.acceptAdmin();
        assertEq(box.oracle(), bob);
        assertEq(box.admin(), carol);
    }

    function test_HandoverCancelsMatureProposalWithEventAndRequiresFreshDelay() public {
        vm.startPrank(admin);
        box.proposeOracle(bob);
        box.transferAdmin(carol);
        vm.stopPrank();
        vm.warp(box.oracleChangeAfter());
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.OracleCancelled(bob);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.AdminSet(carol);
        vm.prank(carol);
        box.acceptAdmin();
        assertEq(box.oracle(), reviewer);
        vm.startPrank(carol);
        vm.expectRevert(BountyBox.InvalidState.selector);
        box.confirmOracle();
        box.proposeOracle(bob);
        vm.expectRevert(BountyBox.TooEarly.selector);
        box.confirmOracle();
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(carol);
        box.confirmOracle();
        assertEq(box.oracle(), bob);
    }

    function test_RenounceEmitsBothCancellationsAndKeepsSplitAndRefundAvailable() public {
        uint256 disputed = _create(15);
        uint256 empty = _create(19);
        uint256 request = _request(disputed, alice);
        vm.startPrank(admin);
        box.proposeOracle(bob);
        box.transferAdmin(carol);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.OracleCancelled(bob);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.AdminTransferCancelled(carol);
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBox.AdminSet(address(0));
        box.renounceAdmin();
        vm.stopPrank();
        vm.warp(box.getRequest(request).settleAfter);
        address[3] memory callers = [admin, carol, address(0)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(BountyBox.Unauthorized.selector);
            box.proposeOracle(bob);
            vm.expectRevert(BountyBox.Unauthorized.selector);
            box.confirmOracle();
            vm.expectRevert(BountyBox.Unauthorized.selector);
            box.cancelOracle();
            vm.expectRevert(BountyBox.Unauthorized.selector);
            box.transferAdmin(bob);
            vm.expectRevert(BountyBox.Unauthorized.selector);
            box.acceptAdmin();
            vm.expectRevert(BountyBox.Unauthorized.selector);
            box.cancelAdminTransfer();
            vm.expectRevert(BountyBox.Unauthorized.selector);
            box.renounceAdmin();
            vm.stopPrank();
        }
        box.settleSplit(disputed);
        vm.prank(creator);
        box.refund(empty);
        vm.prank(alice);
        box.claim(disputed, payable(alice));
        vm.prank(creator);
        box.claim(disputed, payable(creator));
        vm.prank(creator);
        box.claim(empty, payable(creator));
        assertEq(alice.balance, 6);
        assertEq(creator.balance, 28);
        assertEq(address(box).balance, 0);
        assertEq(box.oracle(), reviewer);
    }

    function test_TwoJobsKeepDistinctOracleSnapshotsThroughHandoverAndRenounce() public {
        uint256 first = _create(23);
        uint256 second = _create(29);
        uint256 oldRequest = _request(first, alice);
        vm.prank(admin);
        box.proposeOracle(outsider);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(admin);
        box.confirmOracle();
        uint256 newRequest = _request(second, bob);
        vm.prank(admin);
        box.transferAdmin(carol);
        vm.prank(carol);
        box.acceptAdmin();
        vm.prank(carol);
        box.renounceAdmin();
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(outsider);
        box.answer(oldRequest, true, 0, "wrong oracle");
        vm.expectRevert(BountyBox.Unauthorized.selector);
        vm.prank(reviewer);
        box.answer(newRequest, true, 0, "wrong oracle");
        vm.prank(reviewer);
        box.answer(oldRequest, true, 0, "first");
        assertFalse(box.getRequest(newRequest).resolved);
        assertEq(box.getJob(second).pendingRequestId, newRequest);
        vm.prank(outsider);
        box.answer(newRequest, true, 0, "second");
        assertEq(box.claimable(first, alice), 23);
        assertEq(box.claimable(second, bob), 29);
        assertEq(box.claimable(first, bob), 0);
        assertEq(box.claimable(second, alice), 0);
    }

    function test_MaximumReasonCanBeRetriedAfterOversizedAnswer() public {
        uint256 job = _create(31);
        uint256 request = _request(job, alice);
        bytes32 beforeRequest = keccak256(abi.encode(box.getRequest(request)));
        vm.prank(reviewer);
        vm.expectRevert(BountyBox.InvalidInput.selector);
        box.answer(request, true, 0, new string(1025));
        assertEq(keccak256(abi.encode(box.getRequest(request))), beforeRequest);
        assertEq(box.totalClaimable(), 0);
        string memory reason = new string(1024);
        vm.prank(reviewer);
        box.answer(request, true, type(uint256).max, reason);
        assertEq(box.getSubmission(box.getRequest(request).submissionId).reason, reason);
        assertEq(box.claimable(job, alice), 31);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RevisionDurationSurvivesResubmitAndCreatorRejection(uint256 duration) public {
        duration = bound(duration, 1 days, 7 days);
        uint256 job = _create(1);
        uint256 request = _request(job, alice);
        vm.prank(reviewer);
        box.answer(request, false, duration, "revise");
        vm.warp(vm.getBlockTimestamp() + duration - 1);
        uint256 id = _submit(job, alice);
        assertEq(box.getWorker(job, alice).revisionUntil, 0);
        _reject(job, id);
        assertEq(box.getWorker(job, alice).revisionUntil, vm.getBlockTimestamp() + duration);
        vm.warp(vm.getBlockTimestamp() + duration);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        _submit(job, alice);
        vm.expectRevert(BountyBox.WindowClosed.selector);
        vm.prank(alice);
        box.escalate(job);
        box.closeSlot(job, alice);
        vm.prank(creator);
        box.refund(job);
        assertEq(box.claimable(job, creator), 1);
    }

    function test_OneRevertingSplitRecipientCannotBlockOtherBeneficiary() public {
        uint256 job = _create(17);
        uint256 request = _request(job, alice);
        vm.warp(box.getRequest(request).settleAfter);
        box.settleSplit(job);
        RejectBountyPayment rejector = new RejectBountyPayment();
        vm.expectRevert(BountyBox.TransferFailed.selector);
        vm.prank(alice);
        box.claim(job, payable(address(rejector)));
        assertEq(box.claimable(job, alice), 6);
        assertEq(box.totalClaimable(), 17);
        vm.prank(creator);
        box.claim(job, payable(creator));
        assertEq(creator.balance, 11);
        vm.expectRevert(BountyBox.NothingToClaim.selector);
        vm.prank(address(rejector));
        box.claim(job, payable(outsider));
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.Paid(job, alice, outsider, 6);
        vm.prank(alice);
        box.claim(job, payable(outsider));
        assertEq(outsider.balance, 6);
        assertEq(box.claimable(job, outsider), 0);
        assertEq(box.totalClaimable(), 0);
        assertEq(address(box).balance, 0);
    }

    function test_CrossJobClaimReentrancyCannotConsumeSecondEntitlement() public {
        uint256 first = _create(37);
        uint256 second = _create(41);
        CrossJobClaimReceiver receiver = new CrossJobClaimReceiver(box);
        uint256 a = _submit(first, address(receiver));
        uint256 b = _submit(second, address(receiver));
        vm.prank(creator);
        box.approve(first, a);
        vm.prank(creator);
        box.approve(second, b);
        receiver.claim(first, second);
        assertTrue(receiver.callbackRan());
        assertFalse(receiver.nestedSucceeded());
        assertEq(receiver.nestedError(), abi.encodeWithSelector(BountyBox.Reentrancy.selector));
        assertEq(address(receiver).balance, 37);
        assertEq(box.claimable(second, address(receiver)), 41);
        assertEq(box.totalClaimable(), 41);
        receiver.claim(second, first);
        assertEq(address(receiver).balance, 78);
        assertEq(address(box).balance, 0);
    }
}

contract BountyBoxSplitArithmeticTest is Test {
    function _splitAndWithdraw(uint256 amount) internal {
        BountyBox box = new BountyBox(address(this), address(this));
        address creator = makeAddr("arithmetic creator");
        address worker = makeAddr("arithmetic worker");
        vm.deal(creator, amount);
        vm.deal(worker, 0);
        vm.prank(creator);
        uint256 job = box.createJob{value: amount}(keccak256("brief"), vm.getBlockTimestamp() + 1, "brief");
        vm.prank(worker);
        uint256 id = box.submit(job, keccak256("work"), "work");
        vm.warp(box.getSubmission(id).reviewUntil);
        vm.prank(worker);
        box.escalate(job);
        vm.warp(box.getRequest(box.getJob(job).pendingRequestId).settleAfter);
        box.settleSplit(job);
        uint256 workerShare = box.claimable(job, worker);
        uint256 creatorShare = box.claimable(job, creator);
        // Independent percentage decomposition covers the entire uint256 range.
        assertEq(workerShare, (amount / 100) * 40 + ((amount % 100) * 40) / 100);
        assertEq(workerShare + creatorShare, amount);
        assertEq(box.totalClaimable(), amount);
        assertEq(box.totalEscrow(), 0);
        if (workerShare == 0) {
            vm.expectRevert(BountyBox.NothingToClaim.selector);
            vm.prank(worker);
            box.claim(job, payable(worker));
        } else {
            vm.prank(worker);
            box.claim(job, payable(worker));
        }
        vm.prank(creator);
        box.claim(job, payable(creator));
        assertEq(worker.balance + creator.balance, amount);
        assertEq(address(box).balance, 0);
        assertEq(box.totalClaimable(), 0);
    }

    function test_SplitDustAndEveryRemainder() public {
        for (uint256 i = 1; i <= 10; ++i) {
            _splitAndWithdraw(i);
        }
    }

    function test_SplitMaximumUint256WithoutIntermediateOverflow() public {
        _splitAndWithdraw(type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FullWidthSplitPaysEveryWei(uint256 amount) public {
        _splitAndWithdraw(bound(amount, 1, type(uint256).max));
    }
}
