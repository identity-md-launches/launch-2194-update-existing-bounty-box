// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {BountyBox} from "src/BountyBox.sol";

/// @dev Test-only sender: force real ETH surplus without altering BountyBox storage.
contract BountySurplusSender {
    constructor(address payable destination) payable {
        selfdestruct(destination);
    }
}

contract LifecycleRejectReceiver {
    receive() external payable {
        revert("refuse payment");
    }
}

/// @notice Independent deposit/entitlement ledger plus guided valid actions.
/// Expected failures are explicit; unexpected reverts fail the invariant campaign.
contract BountyLifecycleHandler is Test {
    BountyBox public box;
    LifecycleRejectReceiver public rejectReceiver;
    address[2] public creators;
    address[5] public workers;
    address[3] public administrators;
    address[4] public reviewers;
    address public intruder;

    uint256 public jobs;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public surplus;
    mapping(uint256 => uint256) public deposits;
    mapping(uint256 => address) public jobCreator;
    mapping(uint256 => uint256) public deadlines;
    mapping(uint256 => BountyBox.JobState) public terminal;
    mapping(uint256 => uint256) public winner;
    mapping(uint256 => mapping(address => uint256)) public credit;
    mapping(uint256 => mapping(address => uint256)) public paid;
    mapping(uint256 => mapping(address => uint256)) public attempts;
    mapping(uint256 => mapping(address => uint256)) public latest;
    mapping(uint256 => mapping(address => bool)) public closed;
    uint256 public submissions;
    uint256 public requests;
    mapping(uint256 => bytes32) public requestDigest;
    mapping(uint256 => bool) public resolved;

    address public expectedAdmin;
    address public expectedPendingAdmin;
    address public expectedOracle;
    address public expectedPendingOracle;
    uint256 public expectedConfirmAfter;

    // Observable successful actions for the deterministic harness coverage test.
    uint256 public approvals;
    uint256 public failures;
    uint256 public splits;
    uint256 public refunds;
    uint256 public claims;
    uint256 public rotations;
    uint256 public handovers;

    constructor() {
        creators = [makeAddr("lifecycle creator A"), makeAddr("lifecycle creator B")];
        for (uint256 i; i < workers.length; ++i) {
            workers[i] = makeAddr(string.concat("lifecycle worker ", vm.toString(i)));
        }
        for (uint256 i; i < administrators.length; ++i) {
            administrators[i] = makeAddr(string.concat("lifecycle admin ", vm.toString(i)));
        }
        reviewers = [makeAddr("lifecycle reviewer A"), makeAddr("lifecycle reviewer B"), creators[0], workers[0]];
        intruder = makeAddr("lifecycle intruder");
        expectedAdmin = administrators[0];
        expectedOracle = reviewers[0];
        box = new BountyBox(expectedOracle, expectedAdmin);
        rejectReceiver = new LifecycleRejectReceiver();
        // Seed both competitive work and requests that can be reached immediately.
        for (uint256 i; i < 3; ++i) {
            _create(i % 2, 10 ether + i, 90 days);
            _submit(i + 1, workers[0]);
            _submit(i + 1, workers[1]);
        }
    }

    function create(uint256 creatorSeed, uint256 amountSeed, uint256 durationSeed) external {
        if (jobs == 12) return;
        _create(creatorSeed % 2, bound(amountSeed, 1, 100 ether), bound(durationSeed, 1, 90 days));
    }

    function _create(uint256 creatorIndex, uint256 amount, uint256 duration) internal {
        address creator = creators[creatorIndex];
        uint256 deadline = vm.getBlockTimestamp() + duration;
        vm.deal(creator, creator.balance + amount);
        vm.prank(creator);
        uint256 id = box.createJob{value: amount}(keccak256("stateful brief"), deadline, "stateful brief");
        assertEq(id, ++jobs);
        deposits[id] = amount;
        jobCreator[id] = creator;
        deadlines[id] = deadline;
        deposited += amount;
    }

    function submit(uint256 jobSeed, uint256 actorSeed) external {
        uint256 job = _job(jobSeed);
        BountyBox.Job memory j = box.getJob(job);
        if (j.state != BountyBox.JobState.Open || j.pendingRequestId != 0) return;
        for (uint256 n; n < workers.length; ++n) {
            address worker = workers[(actorSeed % workers.length + n) % workers.length];
            BountyBox.Worker memory w = box.getWorker(job, worker);
            if (w.closed || w.submissionCount == 5) continue;
            if (w.submissionCount == 0) {
                if (j.workerCount == 3 || vm.getBlockTimestamp() >= j.deadline) continue;
            } else {
                BountyBox.SubmissionState state = box.getSubmission(w.latestSubmissionId).state;
                if (state != BountyBox.SubmissionState.Rejected && state != BountyBox.SubmissionState.FailedReview) {
                    continue;
                }
                if (vm.getBlockTimestamp() >= w.revisionUntil) continue;
            }
            _submit(job, worker);
            return;
        }
    }

    function _submit(uint256 job, address worker) internal {
        uint256 previous = latest[job][worker];
        vm.prank(worker);
        uint256 id = box.submit(job, keccak256(abi.encode(job, worker, submissions)), "ipfs://sequence");
        assertEq(id, ++submissions);
        latest[job][worker] = id;
        ++attempts[job][worker];
        if (previous != 0) {
            assertEq(uint256(box.getSubmission(previous).state), uint256(BountyBox.SubmissionState.Superseded));
        }
    }

    function review(uint256 jobSeed, uint256 actorSeed, bool approve) external {
        uint256 job = _job(jobSeed);
        BountyBox.Job memory j = box.getJob(job);
        if (j.state != BountyBox.JobState.Open || (!approve && j.pendingRequestId != 0)) return;
        for (uint256 n; n < workers.length; ++n) {
            address worker = workers[(actorSeed % workers.length + n) % workers.length];
            uint256 id = latest[job][worker];
            BountyBox.Submission memory s = box.getSubmission(id);
            if (s.state != BountyBox.SubmissionState.Pending) continue;
            if (approve) {
                vm.prank(jobCreator[job]);
                box.approve(job, id);
                _finish(job, BountyBox.JobState.Finalized, id, j.pendingRequestId);
                credit[job][worker] += deposits[job];
                ++approvals;
            } else {
                if (vm.getBlockTimestamp() >= s.reviewUntil) continue;
                bool automatic = box.getWorker(job, worker).rejections >= 2;
                vm.prank(jobCreator[job]);
                box.reject(job, id, "creator revision");
                if (automatic) _recordRequest(job, id);
            }
            return;
        }
    }

    function escalate(uint256 jobSeed, uint256 actorSeed) external {
        uint256 job = _job(jobSeed);
        BountyBox.Job memory j = box.getJob(job);
        if (j.state != BountyBox.JobState.Open || j.pendingRequestId != 0) return;
        for (uint256 n; n < workers.length; ++n) {
            address worker = workers[(actorSeed % workers.length + n) % workers.length];
            BountyBox.Worker memory w = box.getWorker(job, worker);
            BountyBox.Submission memory s = box.getSubmission(w.latestSubmissionId);
            if (w.closed) continue;
            if (s.state == BountyBox.SubmissionState.Pending) {
                if (vm.getBlockTimestamp() < s.reviewUntil || vm.getBlockTimestamp() >= s.reviewUntil + 30 days) {
                    continue;
                }
            } else if (s.state == BountyBox.SubmissionState.Rejected) {
                if (vm.getBlockTimestamp() >= w.revisionUntil) continue;
            } else {
                continue;
            }
            vm.prank(worker);
            box.escalate(job);
            _recordRequest(job, w.latestSubmissionId);
            return;
        }
    }

    function _recordRequest(uint256 job, uint256 submission) internal {
        uint256 id = ++requests;
        assertEq(box.getJob(job).pendingRequestId, id);
        assertEq(box.requestCount(), id);
        requestDigest[id] = keccak256(
            abi.encode(job, submission, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 7 days, expectedOracle)
        );
    }

    function answer(uint256 jobSeed, bool ok, uint256 duration) external {
        uint256 job = _job(jobSeed);
        uint256 id = box.getJob(job).pendingRequestId;
        if (id == 0) return;
        BountyBox.Request memory r = box.getRequest(id);
        if (r.oracle == jobCreator[job] || box.getWorker(job, r.oracle).submissionCount != 0) {
            vm.expectRevert(BountyBox.Unauthorized.selector);
            vm.prank(r.oracle);
            box.answer(id, ok, duration, "conflicted reviewer");
            return;
        }
        // Timely answers must succeed; timeout availability is driven by split().
        if (vm.getBlockTimestamp() >= r.settleAfter) return;
        address worker = box.getSubmission(r.submissionId).worker;
        bool closes = box.getWorker(job, worker).failedReviews == 2;
        vm.prank(r.oracle);
        box.answer(id, ok, duration, "oracle review");
        resolved[id] = true;
        if (ok) {
            _finish(job, BountyBox.JobState.Finalized, r.submissionId, id);
            credit[job][worker] += deposits[job];
            ++approvals;
        } else {
            if (closes) closed[job][worker] = true;
            ++failures;
        }
    }

    function close(uint256 jobSeed, uint256 actorSeed) external {
        uint256 job = _job(jobSeed);
        BountyBox.Job memory j = box.getJob(job);
        if (j.state != BountyBox.JobState.Open || j.pendingRequestId != 0) return;
        for (uint256 n; n < workers.length; ++n) {
            address worker = workers[(actorSeed % workers.length + n) % workers.length];
            if (!_closable(job, worker)) continue;
            vm.prank(intruder);
            box.closeSlot(job, worker);
            closed[job][worker] = true;
            return;
        }
    }

    function _closable(uint256 job, address worker) internal view returns (bool) {
        BountyBox.Worker memory w = box.getWorker(job, worker);
        if (w.submissionCount == 0 || w.closed) return false;
        BountyBox.Submission memory s = box.getSubmission(w.latestSubmissionId);
        if (s.state == BountyBox.SubmissionState.Pending) return vm.getBlockTimestamp() >= s.reviewUntil + 30 days;
        return w.revisionUntil != 0 && vm.getBlockTimestamp() >= w.revisionUntil;
    }

    function refund(uint256 jobSeed) external {
        uint256 job = _job(jobSeed);
        BountyBox.Job memory j = box.getJob(job);
        if (j.state != BountyBox.JobState.Open || j.pendingRequestId != 0) return;
        for (uint256 i; i < workers.length; ++i) {
            if (attempts[job][workers[i]] != 0 && !closed[job][workers[i]] && !_closable(job, workers[i])) {
                vm.expectRevert(BountyBox.ActiveWorkers.selector);
                vm.prank(jobCreator[job]);
                box.refund(job);
                return;
            }
        }
        _refund(job);
    }

    function _refund(uint256 job) internal {
        vm.prank(jobCreator[job]);
        box.refund(job);
        _finish(job, BountyBox.JobState.Refunded, 0, 0);
        credit[job][jobCreator[job]] += deposits[job];
        for (uint256 i; i < workers.length; ++i) {
            if (attempts[job][workers[i]] != 0) closed[job][workers[i]] = true;
        }
        ++refunds;
    }

    function split(uint256 jobSeed) external {
        uint256 job = _job(jobSeed);
        uint256 id = box.getJob(job).pendingRequestId;
        if (id == 0) return;
        if (vm.getBlockTimestamp() < box.getRequest(id).settleAfter) {
            vm.expectRevert(BountyBox.TooEarly.selector);
            vm.prank(intruder);
            box.settleSplit(job);
            return;
        }
        _split(job, id);
    }

    function _split(uint256 job, uint256 id) internal {
        address worker = box.getSubmission(box.getRequest(id).submissionId).worker;
        vm.prank(intruder);
        box.settleSplit(job);
        _finish(job, BountyBox.JobState.Finalized, 0, id);
        uint256 workerShare = deposits[job] * 40 / 100; // Inputs are bounded to 100 ETH.
        credit[job][worker] += workerShare;
        credit[job][jobCreator[job]] += deposits[job] - workerShare;
        ++splits;
    }

    function _finish(uint256 job, BountyBox.JobState state, uint256 winnerId, uint256 request) internal {
        assertEq(uint256(terminal[job]), uint256(BountyBox.JobState.Open), "job paid twice");
        terminal[job] = state;
        winner[job] = winnerId;
        if (request != 0) resolved[request] = true;
    }

    function claim(uint256 jobSeed, uint256 actorSeed, uint256 recipientSeed, bool rejectPayment) external {
        uint256 job = _job(jobSeed);
        for (uint256 n; n < 7; ++n) {
            address beneficiary = actor((actorSeed % 7 + n) % 7);
            if (credit[job][beneficiary] == 0) continue;
            if (rejectPayment) {
                vm.expectRevert(BountyBox.TransferFailed.selector);
                vm.prank(beneficiary);
                box.claim(job, payable(address(rejectReceiver)));
            } else {
                _claim(job, beneficiary, actor(recipientSeed % 7));
            }
            return;
        }
    }

    function _claim(uint256 job, address beneficiary, address recipient) internal {
        uint256 expected = credit[job][beneficiary];
        uint256 balanceBefore = recipient.balance;
        vm.prank(beneficiary);
        box.claim(job, payable(recipient));
        uint256 received = recipient.balance - balanceBefore;
        assertEq(received, expected, "actual ETH must match independent entitlement");
        credit[job][beneficiary] = 0;
        paid[job][beneficiary] += received;
        withdrawn += received;
        ++claims;
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1 ether);
        vm.deal(address(this), amount);
        new BountySurplusSender{value: amount}(payable(address(box)));
        surplus += amount;
    }

    function advance(uint256 jobSeed, uint256 actorSeed, uint256 timeSeed) external {
        uint256 job = _job(jobSeed);
        BountyBox.Worker memory w = box.getWorker(job, workers[actorSeed % 5]);
        BountyBox.Submission memory s = box.getSubmission(w.latestSubmissionId);
        uint256 request = box.getJob(job).pendingRequestId;
        uint256 target;
        uint256 mode = timeSeed % 6;
        if (mode == 0) target = vm.getBlockTimestamp() + bound(timeSeed, 0, 8 days);
        else if (mode == 1) target = s.reviewUntil;
        else if (mode == 2) target = s.reviewUntil + 30 days;
        else if (mode == 3) target = w.revisionUntil;
        else if (mode == 4) target = box.getRequest(request).settleAfter;
        else target = expectedConfirmAfter;
        if (mode != 0 && target != 0) {
            uint256 edge = (timeSeed / 6) % 3;
            if (edge == 0) --target;
            else if (edge == 2) ++target;
        }
        if (target > vm.getBlockTimestamp()) vm.warp(target);
    }

    function administer(uint256 actionSeed, uint256 candidateSeed) external {
        // Renunciation stays reachable without dominating all governance sequences.
        uint256 action = actionSeed % 16;
        action = action == 15 ? 6 : action % 6;
        if (expectedAdmin == address(0)) {
            vm.expectRevert(BountyBox.Unauthorized.selector);
            vm.prank(administrators[candidateSeed % 3]);
            box.proposeOracle(reviewers[candidateSeed % 4]);
            return;
        }
        if (action == 0) {
            vm.prank(expectedAdmin);
            box.proposeOracle(reviewers[candidateSeed % 4]);
            expectedPendingOracle = reviewers[candidateSeed % 4];
            expectedConfirmAfter = vm.getBlockTimestamp() + 1 days;
        } else if (action == 1) {
            if (expectedPendingOracle == address(0)) vm.expectRevert(BountyBox.InvalidState.selector);
            else if (vm.getBlockTimestamp() < expectedConfirmAfter) vm.expectRevert(BountyBox.TooEarly.selector);
            vm.prank(expectedAdmin);
            box.confirmOracle();
            if (expectedPendingOracle != address(0) && vm.getBlockTimestamp() >= expectedConfirmAfter) {
                expectedOracle = expectedPendingOracle;
                _clearOracleProposal();
                ++rotations;
            }
        } else if (action == 2) {
            if (expectedPendingOracle == address(0)) vm.expectRevert(BountyBox.InvalidState.selector);
            vm.prank(expectedAdmin);
            box.cancelOracle();
            _clearOracleProposal();
        } else if (action == 3) {
            address next = administrators[candidateSeed % 3];
            vm.prank(expectedAdmin);
            box.transferAdmin(next);
            expectedPendingAdmin = next;
        } else if (action == 4) {
            if (expectedPendingAdmin == address(0)) {
                vm.expectRevert(BountyBox.Unauthorized.selector);
                vm.prank(intruder);
                box.acceptAdmin();
            } else {
                vm.prank(expectedPendingAdmin);
                box.acceptAdmin();
                expectedAdmin = expectedPendingAdmin;
                expectedPendingAdmin = address(0);
                _clearOracleProposal();
                ++handovers;
            }
        } else if (action == 5) {
            if (expectedPendingAdmin == address(0)) vm.expectRevert(BountyBox.InvalidState.selector);
            vm.prank(expectedAdmin);
            box.cancelAdminTransfer();
            expectedPendingAdmin = address(0);
        } else {
            vm.prank(expectedAdmin);
            box.renounceAdmin();
            expectedAdmin = address(0);
            expectedPendingAdmin = address(0);
            _clearOracleProposal();
        }
    }

    function _clearOracleProposal() internal {
        expectedPendingOracle = address(0);
        expectedConfirmAfter = 0;
    }

    function unauthorized(uint256 actionSeed, uint256 jobSeed) external {
        uint256 action = actionSeed % 8;
        uint256 job = _job(jobSeed);
        vm.startPrank(intruder);
        if (action == 7) {
            vm.expectRevert(BountyBox.NothingToClaim.selector);
            box.claim(job, payable(intruder));
        } else {
            vm.expectRevert(BountyBox.Unauthorized.selector);
            if (action == 0) box.proposeOracle(intruder);
            else if (action == 1) box.confirmOracle();
            else if (action == 2) box.cancelOracle();
            else if (action == 3) box.transferAdmin(intruder);
            else if (action == 4) box.acceptAdmin();
            else if (action == 5) box.cancelAdminTransfer();
            else box.renounceAdmin();
        }
        vm.stopPrank();
    }

    /// @dev Actively attempt reopening terminal jobs; merely avoiding them would be vacuous.
    function terminalReplay(uint256 jobSeed, uint256 actionSeed) external {
        uint256 job = _job(jobSeed);
        if (terminal[job] == BountyBox.JobState.Open) return;
        uint256 action = actionSeed % 7;
        uint256 id = latest[job][workers[0]];
        vm.expectRevert(BountyBox.InvalidState.selector);
        if (action == 0) {
            vm.prank(jobCreator[job]);
            box.approve(job, id);
        } else if (action == 1) {
            vm.prank(jobCreator[job]);
            box.reject(job, id, "replay");
        } else if (action == 2) {
            vm.prank(workers[0]);
            box.submit(job, keccak256("replay"), "ipfs://replay");
        } else if (action == 3) {
            vm.prank(workers[0]);
            box.escalate(job);
        } else if (action == 4) {
            vm.prank(intruder);
            box.closeSlot(job, workers[0]);
        } else if (action == 5) {
            vm.prank(jobCreator[job]);
            box.refund(job);
        } else {
            vm.prank(intruder);
            box.settleSplit(job);
        }
    }

    function replayAnswer(uint256 requestSeed, bool ok) external {
        if (requests == 0) return;
        uint256 id = 1 + requestSeed % requests;
        if (!resolved[id]) return;
        BountyBox.Request memory r = box.getRequest(id);
        bool conflict = r.oracle == jobCreator[r.jobId] || box.getWorker(r.jobId, r.oracle).submissionCount != 0;
        vm.expectRevert(conflict ? BountyBox.Unauthorized.selector : BountyBox.InvalidState.selector);
        vm.prank(r.oracle);
        box.answer(id, ok, 0, "replay resolved request");
    }

    function actor(uint256 index) public view returns (address) {
        return index < 2 ? creators[index] : workers[index - 2];
    }

    function _job(uint256 seed) internal view returns (uint256) {
        return 1 + seed % jobs;
    }

    /// @notice End-of-sequence liveness: every funded job can eventually release all liabilities.
    /// Not a fuzz target; invoked once by afterInvariant after all random actions.
    function drainAll() external {
        vm.warp(vm.getBlockTimestamp() + 100 days);
        for (uint256 job = 1; job <= jobs; ++job) {
            if (terminal[job] == BountyBox.JobState.Open) {
                uint256 request = box.getJob(job).pendingRequestId;
                if (request == 0) _refund(job);
                else _split(job, request);
            }
            for (uint256 i; i < 7; ++i) {
                address beneficiary = actor(i);
                if (credit[job][beneficiary] != 0) _claim(job, beneficiary, beneficiary);
            }
        }
        assertEq(box.totalEscrow(), 0);
        assertEq(box.totalClaimable(), 0);
        assertEq(withdrawn, deposited);
        assertEq(address(box).balance, surplus);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract BountyBoxLifecycleInvariantTest is StdInvariant, Test {
    BountyLifecycleHandler handler;
    BountyBox box;

    function setUp() public {
        vm.warp(100 days);
        handler = new BountyLifecycleHandler();
        box = handler.box();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.submit.selector;
        selectors[2] = handler.review.selector;
        selectors[3] = handler.escalate.selector;
        selectors[4] = handler.answer.selector;
        selectors[5] = handler.close.selector;
        selectors[6] = handler.refund.selector;
        selectors[7] = handler.split.selector;
        selectors[8] = handler.claim.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.advance.selector;
        selectors[11] = handler.administer.selector;
        selectors[12] = handler.unauthorized.selector;
        selectors[13] = handler.terminalReplay.selector;
        selectors[14] = handler.replayAnswer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_IndependentEntitlementsConserveEveryDeposit() public view {
        uint256 escrow;
        uint256 credits;
        uint256 paidOut;
        assertEq(box.jobCount(), handler.jobs());
        for (uint256 job = 1; job <= handler.jobs(); ++job) {
            BountyBox.Job memory j = box.getJob(job);
            uint256 amount = handler.deposits(job);
            bool open = handler.terminal(job) == BountyBox.JobState.Open;
            assertEq(j.amount, amount);
            assertEq(j.creator, handler.jobCreator(job));
            assertEq(j.deadline, handler.deadlines(job));
            assertEq(uint256(j.state), uint256(handler.terminal(job)), "terminal job reopened or changed state");
            assertEq(j.winnerSubmissionId, handler.winner(job));
            if (open) escrow += amount;
            else assertEq(j.pendingRequestId, 0);
            uint256 released;
            for (uint256 i; i < 7; ++i) {
                address beneficiary = handler.actor(i);
                uint256 entitlement = handler.credit(job, beneficiary);
                uint256 payment = handler.paid(job, beneficiary);
                assertEq(box.claimable(job, beneficiary), entitlement, "wrong job or beneficiary credited");
                released += entitlement + payment;
                credits += entitlement;
                paidOut += payment;
            }
            assertEq(released, open ? 0 : amount, "job released more or less than its deposit");
        }
        assertEq(box.totalEscrow(), escrow);
        assertEq(box.totalClaimable(), credits);
        assertEq(paidOut, handler.withdrawn());
        assertEq(address(box).balance, escrow + credits + handler.surplus());
        assertEq(address(box).balance + paidOut, handler.deposited() + handler.surplus());
    }

    function invariant_OracleSnapshotsAndAdminTransitionsMatchIndependentModel() public view {
        assertEq(box.admin(), handler.expectedAdmin());
        assertEq(box.pendingAdmin(), handler.expectedPendingAdmin());
        assertEq(box.oracle(), handler.expectedOracle());
        assertEq(box.pendingOracle(), handler.expectedPendingOracle());
        assertEq(box.oracleChangeAfter(), handler.expectedConfirmAfter());
        assertEq(box.requestCount(), handler.requests());
        for (uint256 id = 1; id <= handler.requests(); ++id) {
            BountyBox.Request memory r = box.getRequest(id);
            assertEq(
                keccak256(abi.encode(r.jobId, r.submissionId, r.requestedAt, r.settleAfter, r.oracle)),
                handler.requestDigest(id),
                "request reassigned or timeout changed"
            );
            assertEq(r.resolved, handler.resolved(id), "request resolved twice or reopened");
            if (!r.resolved) {
                assertEq(box.getJob(r.jobId).pendingRequestId, id);
                assertEq(uint256(box.getSubmission(r.submissionId).state), uint256(BountyBox.SubmissionState.Escalated));
            }
        }
    }

    function invariant_WorkerHistoryAndLiveSlotsRemainConsistent() public view {
        assertEq(box.submissionCount(), handler.submissions());
        for (uint256 job = 1; job <= handler.jobs(); ++job) {
            BountyBox.Job memory j = box.getJob(job);
            address[3] memory participants = box.getParticipants(job);
            uint256 active;
            uint256 count;
            for (uint256 i; i < 5; ++i) {
                address worker = handler.workers(i);
                BountyBox.Worker memory w = box.getWorker(job, worker);
                assertEq(w.submissionCount, handler.attempts(job, worker));
                assertEq(w.latestSubmissionId, handler.latest(job, worker));
                assertEq(w.closed, handler.closed(job, worker));
                assertLe(w.submissionCount, 5);
                assertLe(w.failedReviews, 3);
                count += w.submissionCount;
                if (w.submissionCount == 0) continue;
                uint256 occurrences;
                for (uint256 k; k < 3; ++k) {
                    if (participants[k] == worker) ++occurrences;
                }
                assertEq(occurrences, w.closed ? 0 : 1);
                if (w.closed) {
                    assertEq(
                        uint256(box.getSubmission(w.latestSubmissionId).state),
                        uint256(BountyBox.SubmissionState.Cancelled)
                    );
                } else {
                    ++active;
                }
            }
            assertEq(j.workerCount, active);
            assertLe(active, 3);
            assertEq(j.submissionCount, count);
            for (uint256 k = active; k < 3; ++k) {
                assertEq(participants[k], address(0));
            }
        }
        for (uint256 id = 1; id <= handler.submissions(); ++id) {
            BountyBox.Submission memory s = box.getSubmission(id);
            if (handler.terminal(s.jobId) == BountyBox.JobState.Open) continue;
            assertTrue(
                s.state == BountyBox.SubmissionState.Approved || s.state == BountyBox.SubmissionState.Cancelled
                    || s.state == BountyBox.SubmissionState.Superseded,
                "finished job still contains live work"
            );
            if (s.state == BountyBox.SubmissionState.Approved) assertEq(id, handler.winner(s.jobId));
        }
    }

    function afterInvariant() public {
        handler.drainAll();
        invariant_IndependentEntitlementsConserveEveryDeposit();
        invariant_OracleSnapshotsAndAdminTransitionsMatchIndependentModel();
        invariant_WorkerHistoryAndLiveSlotsRemainConsistent();
    }

    function test_HandlerReachesDisputesRotationsHandoverAndEveryPayout() public {
        // Job 1: original reviewer still answers after a confirmed rotation.
        handler.review(0, 0, false);
        handler.escalate(0, 0);
        handler.administer(0, 1);
        handler.advance(0, 0, 11); // Exactly oracleChangeAfter.
        handler.administer(1, 0);
        handler.answer(0, false, 1 days);
        handler.submit(0, 0);
        handler.review(0, 0, true);
        handler.claim(0, 2, 3, true);
        handler.claim(0, 2, 3, false);
        for (uint256 i; i < 7; ++i) {
            handler.terminalReplay(0, i);
        }
        handler.replayAnswer(0, true);
        // Job 2: dead reviewer times out, yielding two independent claims.
        handler.review(1, 0, false);
        handler.escalate(1, 0);
        handler.advance(1, 0, 10); // Exactly settleAfter.
        handler.split(1);
        // Job 3: handover, abandoned work, and refund after renunciation.
        handler.administer(3, 1);
        handler.administer(4, 0);
        handler.administer(15, 0);
        handler.donate(5);
        handler.drainAll();
        assertEq(handler.rotations(), 1);
        assertEq(handler.handovers(), 1);
        assertEq(handler.failures(), 1);
        assertEq(handler.approvals(), 1);
        assertEq(handler.splits(), 1);
        assertEq(handler.refunds(), 1);
        assertEq(handler.claims(), 4);
        invariant_IndependentEntitlementsConserveEveryDeposit();
        invariant_OracleSnapshotsAndAdminTransitionsMatchIndependentModel();
        invariant_WorkerHistoryAndLiveSlotsRemainConsistent();
    }
}
