// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {BountyBox} from "../src/BountyBox.sol";

contract EscrowHandler is Test {
    BountyBox public box;
    address public creator = address(0xC001);
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256 public paid;

    constructor() {
        box = new BountyBox(address(this), address(this));
        vm.deal(creator, 30 ether);
        for (uint256 i; i < 3; ++i) {
            vm.prank(creator);
            box.createJob{value: 10 ether}(keccak256("brief"), block.timestamp + 30 days, "brief");
        }
    }

    function advance(uint256 seed) external {
        vm.warp(block.timestamp + seed % (4 days));
    }

    function submit(uint256 jobSeed, uint256 actorSeed) external {
        vm.prank(actors[actorSeed % 4]);
        try box.submit(1 + jobSeed % 3, keccak256(abi.encode(actorSeed)), "ipfs://invariant") {} catch {}
    }

    function review(uint256 jobSeed, uint256 actorSeed, bool ok) external {
        uint256 jobId = 1 + jobSeed % 3;
        uint256 latest = box.getWorker(jobId, actors[actorSeed % 4]).latestSubmissionId;
        vm.prank(creator);
        if (ok) {
            try box.approve(jobId, latest) {} catch {}
        } else {
            try box.reject(jobId, latest, "revise") {} catch {}
        }
    }

    function escalate(uint256 jobSeed, uint256 actorSeed) external {
        vm.prank(actors[actorSeed % 4]);
        try box.escalate(1 + jobSeed % 3) {} catch {}
    }

    function answer(uint256 jobSeed, bool ok, uint256 duration) external {
        uint256 id = box.getJob(1 + jobSeed % 3).pendingRequestId;
        try box.answer(id, ok, duration, "oracle review") {} catch {}
    }

    function close(uint256 jobSeed, uint256 actorSeed) external {
        try box.closeSlot(1 + jobSeed % 3, actors[actorSeed % 4]) {} catch {}
    }

    function refund(uint256 jobSeed) external {
        vm.prank(creator);
        try box.refund(1 + jobSeed % 3) {} catch {}
    }

    function split(uint256 jobSeed) external {
        try box.settleSplit(1 + jobSeed % 3) {} catch {}
    }

    function claim(uint256 jobSeed, uint256 actorSeed) external {
        address beneficiary = actorSeed % 5 == 4 ? creator : actors[actorSeed % 4];
        uint256 jobId = 1 + jobSeed % 3;
        uint256 amount = box.claimable(jobId, beneficiary);
        vm.prank(beneficiary);
        try box.claim(jobId, payable(beneficiary)) {
            paid += amount;
        } catch {}
    }
}

contract BountyBoxInvariantTest is StdInvariant, Test {
    EscrowHandler handler;
    BountyBox box;

    function setUp() public {
        vm.warp(100 days);
        handler = new EscrowHandler();
        box = handler.box();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.submit.selector;
        selectors[2] = handler.review.selector;
        selectors[3] = handler.escalate.selector;
        selectors[4] = handler.answer.selector;
        selectors[5] = handler.close.selector;
        selectors[6] = handler.refund.selector;
        selectors[7] = handler.split.selector;
        selectors[8] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_FundsAndLiabilitiesAreConserved() public view {
        uint256 escrow;
        uint256 credits;
        for (uint256 id = 1; id <= 3; ++id) {
            BountyBox.Job memory j = box.getJob(id);
            if (j.state == BountyBox.JobState.Open) escrow += j.amount;
            credits += box.claimable(id, handler.creator());
            assertLe(j.workerCount, 3);
            assertLe(j.submissionCount, 20); // Four modeled workers, each with at most five attempts.
            address[3] memory participants = box.getParticipants(id);
            for (uint256 i; i < 3; ++i) {
                if (i < j.workerCount) {
                    assertTrue(participants[i] != address(0));
                    assertFalse(box.getWorker(id, participants[i]).closed);
                    for (uint256 k; k < i; ++k) {
                        assertTrue(participants[i] != participants[k]);
                    }
                } else {
                    assertEq(participants[i], address(0));
                }
            }
            uint256 historicalSubmissions;
            for (uint256 i; i < 4; ++i) {
                address actor = handler.actors(i);
                credits += box.claimable(id, actor);
                BountyBox.Worker memory w = box.getWorker(id, actor);
                assertLe(w.submissionCount, 5);
                assertLe(w.failedReviews, 3);
                historicalSubmissions += w.submissionCount;
                if (w.closed) {
                    assertEq(
                        uint256(box.getSubmission(w.latestSubmissionId).state),
                        uint256(BountyBox.SubmissionState.Cancelled)
                    );
                }
            }
            assertEq(j.submissionCount, historicalSubmissions);
            if (j.pendingRequestId != 0) {
                BountyBox.Request memory r = box.getRequest(j.pendingRequestId);
                assertEq(r.jobId, id);
                assertFalse(r.resolved);
                assertEq(uint256(j.state), uint256(BountyBox.JobState.Open));
                assertEq(uint256(box.getSubmission(r.submissionId).state), uint256(BountyBox.SubmissionState.Escalated));
            }
        }
        assertEq(escrow, box.totalEscrow());
        assertEq(credits, box.totalClaimable());
        assertEq(address(box).balance, escrow + credits);
        assertEq(address(box).balance + handler.paid(), 30 ether);
    }
}
