// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Bounty Box — immutable, ETH-only freelance escrow
/// @notice The admin can only rotate the oracle after a 24h delay or hand over/renounce that role.
/// No pause, upgrade, fee, parameter changes or privileged withdrawal.
contract BountyBox {
    uint256 public constant REVIEW_WINDOW = 3 days;
    uint256 public constant REVISION_WINDOW = 48 hours;
    uint256 public constant MIN_REVISION = 24 hours;
    uint256 public constant MAX_REVISION = 7 days;
    uint256 public constant ORACLE_TIMEOUT = 7 days;
    uint256 public constant ORACLE_CHANGE_DELAY = 24 hours;
    uint256 public constant ABANDON_AFTER = 30 days;
    uint256 public constant MAX_DEADLINE = 90 days;
    uint256 public constant MAX_TEXT_BYTES = 8192;
    uint256 public constant MAX_LINK_BYTES = 2048;
    uint256 public constant MAX_REASON_BYTES = 1024;

    enum JobState {
        Open,
        Finalized,
        Refunded
    }
    enum SubmissionState {
        None,
        Pending,
        Rejected,
        Escalated,
        FailedReview,
        Approved,
        Cancelled,
        Superseded
    }
    enum CloseReason {
        RevisionExpired,
        FailedReviews,
        Abandoned
    }

    struct Job {
        address creator;
        bytes32 jobHash;
        uint256 amount;
        uint256 deadline;
        uint256 pendingRequestId;
        uint256 winnerSubmissionId;
        uint8 workerCount;
        uint256 submissionCount;
        JobState state;
    }

    struct Worker {
        uint256 latestSubmissionId;
        uint256 revisionUntil;
        uint256 revisionDuration;
        uint8 submissionCount;
        uint8 rejections;
        uint8 failedReviews;
        bool closed;
    }

    struct Submission {
        uint256 jobId;
        address worker;
        bytes32 contentHash;
        string link;
        uint256 reviewUntil;
        SubmissionState state;
        string reason;
    }

    struct Request {
        uint256 jobId;
        uint256 submissionId;
        uint256 requestedAt;
        uint256 settleAfter;
        bool resolved;
        address oracle;
    }

    address public oracle;
    address public admin;
    address public pendingAdmin;
    address public pendingOracle;
    uint256 public oracleChangeAfter;
    uint256 public jobCount;
    uint256 public submissionCount;
    uint256 public requestCount;
    uint256 public totalEscrow;
    uint256 public totalClaimable;
    mapping(uint256 => Job) private _jobs;
    mapping(uint256 => mapping(address => Worker)) private _workers;
    mapping(uint256 => address[3]) private _participants;
    mapping(uint256 => Submission) private _submissions;
    mapping(uint256 => Request) private _requests;
    mapping(uint256 => mapping(address => string[])) private _reasons;
    mapping(bytes32 => string) private _publishedTexts;
    mapping(uint256 => mapping(address => uint256)) public claimable;
    uint256 private _entered = 1;

    error InvalidInput();
    error NotFound();
    error Unauthorized();
    error InvalidState();
    error WindowClosed();
    error TooEarly();
    error LimitReached();
    error OraclePending();
    error ActiveWorkers();
    error NothingToClaim();
    error TransferFailed();
    error Reentrancy();

    event JobTextPublished(bytes32 indexed jobHash, string text);
    event Created(
        uint256 indexed jobId, address indexed creator, bytes32 jobHash, string text, uint256 amount, uint256 deadline
    );
    event Submitted(
        uint256 indexed jobId,
        uint256 indexed submissionId,
        address indexed worker,
        bytes32 contentHash,
        string link,
        uint256 reviewUntil
    );
    event Resubmitted(
        uint256 indexed jobId, uint256 indexed submissionId, address indexed worker, uint256 previousSubmissionId
    );
    event Approved(uint256 indexed jobId, uint256 indexed submissionId, address indexed worker);
    event Rejected(
        uint256 indexed jobId,
        uint256 indexed submissionId,
        address indexed worker,
        string reason,
        uint256 revisionUntil,
        uint8 rejectionCount
    );
    event Escalated(uint256 indexed jobId, uint256 indexed submissionId, uint256 indexed requestId);
    event OracleAnswered(
        uint256 indexed jobId,
        uint256 indexed requestId,
        uint256 indexed submissionId,
        address worker,
        bool ok,
        string reason,
        uint256 revisionUntil
    );
    event OracleAnswerIgnored(uint256 indexed jobId, uint256 indexed requestId);
    event ClocksResumed(uint256 indexed jobId, uint256 pausedSeconds);
    event SlotClosed(uint256 indexed jobId, address indexed worker, CloseReason reason);
    event Cancelled(uint256 indexed jobId, uint256 indexed submissionId);
    event CancelledByApproval(
        uint256 indexed jobId, uint256 indexed submissionId, uint256 indexed approvedSubmissionId
    );
    event AdminSet(address indexed admin);
    event AdminTransferProposed(address indexed admin, address indexed newAdmin);
    event AdminTransferCancelled(address indexed newAdmin);
    event OracleProposed(address indexed newOracle, uint256 confirmAfter);
    event OracleConfirmed(address indexed previousOracle, address indexed newOracle);
    event OracleCancelled(address indexed newOracle);
    event Paid(uint256 indexed jobId, address indexed beneficiary, address indexed recipient, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed creator, uint256 amount);
    event Split(
        uint256 indexed jobId,
        uint256 indexed requestId,
        address indexed worker,
        uint256 creatorAmount,
        uint256 workerAmount
    );

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier onlyAdmin() {
        if (admin == address(0) || msg.sender != admin) revert Unauthorized();
        _;
    }

    constructor(address oracle_, address admin_) {
        if (oracle_ == address(0)) revert InvalidInput();
        oracle = oracle_;
        admin = admin_ == address(0) ? msg.sender : admin_;
        emit AdminSet(admin);
    }

    function proposeOracle(address newOracle) external onlyAdmin {
        if (newOracle == address(0)) revert InvalidInput();
        _cancelOracle();
        pendingOracle = newOracle;
        oracleChangeAfter = block.timestamp + ORACLE_CHANGE_DELAY;
        emit OracleProposed(newOracle, oracleChangeAfter);
    }

    function confirmOracle() external onlyAdmin {
        address next = pendingOracle;
        if (next == address(0)) revert InvalidState();
        if (block.timestamp < oracleChangeAfter) revert TooEarly();
        address previous = oracle;
        oracle = next;
        pendingOracle = address(0);
        oracleChangeAfter = 0;
        emit OracleConfirmed(previous, next);
    }

    function cancelOracle() external onlyAdmin {
        if (pendingOracle == address(0)) revert InvalidState();
        _cancelOracle();
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidInput();
        _cancelAdminTransfer();
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(admin, newAdmin);
    }

    function acceptAdmin() external {
        if (admin == address(0) || pendingAdmin == address(0) || msg.sender != pendingAdmin) revert Unauthorized();
        // A successor starts without an inherited oracle proposal.
        _cancelOracle();
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminSet(admin);
    }

    function cancelAdminTransfer() external onlyAdmin {
        if (pendingAdmin == address(0)) revert InvalidState();
        _cancelAdminTransfer();
    }

    function renounceAdmin() external onlyAdmin {
        _cancelOracle();
        _cancelAdminTransfer();
        admin = address(0);
        emit AdminSet(address(0));
    }

    function _cancelOracle() private {
        if (pendingOracle != address(0)) {
            emit OracleCancelled(pendingOracle);
            pendingOracle = address(0);
            oracleChangeAfter = 0;
        }
    }

    function _cancelAdminTransfer() private {
        if (pendingAdmin != address(0)) {
            emit AdminTransferCancelled(pendingAdmin);
            pendingAdmin = address(0);
        }
    }

    /// @notice Makes a preimage available for the exact two-argument createJob API.
    function publishJobText(string calldata text) external nonReentrant returns (bytes32 hash) {
        _checkText(text);
        hash = keccak256(bytes(text));
        _publishedTexts[hash] = text;
        emit JobTextPublished(hash, text);
    }

    function createJob(bytes32 jobHash, uint256 deadline) external payable nonReentrant returns (uint256) {
        string memory text = _publishedTexts[jobHash];
        if (bytes(text).length == 0) revert InvalidInput();
        return _createJob(jobHash, deadline, text);
    }

    /// @notice Preferred atomic API: text is emitted, its checked hash is stored.
    function createJob(bytes32 jobHash, uint256 deadline, string calldata text)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        _checkText(text);
        if (keccak256(bytes(text)) != jobHash) revert InvalidInput();
        return _createJob(jobHash, deadline, text);
    }

    function _createJob(bytes32 hash, uint256 deadline, string memory text) private returns (uint256 id) {
        if (msg.value == 0 || deadline <= block.timestamp || deadline > block.timestamp + MAX_DEADLINE) {
            revert InvalidInput();
        }
        id = ++jobCount;
        Job storage j = _jobs[id];
        j.creator = msg.sender;
        j.jobHash = hash;
        j.amount = msg.value;
        j.deadline = deadline;
        totalEscrow += msg.value;
        emit Created(id, msg.sender, hash, text, msg.value, deadline);
    }

    function submit(uint256 jobId, bytes32 contentHash, string calldata link)
        external
        nonReentrant
        returns (uint256 id)
    {
        Job storage j = _available(jobId);
        if (msg.sender == j.creator) revert Unauthorized();
        if (contentHash == bytes32(0) || bytes(link).length == 0 || bytes(link).length > MAX_LINK_BYTES) {
            revert InvalidInput();
        }
        Worker storage w = _workers[jobId][msg.sender];
        uint256 previous = w.latestSubmissionId;
        if (w.submissionCount == 0) {
            if (block.timestamp >= j.deadline) revert WindowClosed();
            if (j.workerCount == 3) revert LimitReached();
            _participants[jobId][j.workerCount++] = msg.sender;
            w.revisionDuration = REVISION_WINDOW;
        } else {
            if (w.closed) revert InvalidState();
            if (w.submissionCount == 5) revert LimitReached();
            Submission storage old = _submissions[previous];
            if (old.state != SubmissionState.Rejected && old.state != SubmissionState.FailedReview) {
                revert InvalidState();
            }
            if (block.timestamp >= w.revisionUntil) revert WindowClosed();
            old.state = SubmissionState.Superseded;
        }
        id = ++submissionCount;
        ++j.submissionCount;
        ++w.submissionCount;
        w.latestSubmissionId = id;
        w.revisionUntil = 0;
        _submissions[id] = Submission(
            jobId, msg.sender, contentHash, link, block.timestamp + REVIEW_WINDOW, SubmissionState.Pending, ""
        );
        emit Submitted(jobId, id, msg.sender, contentHash, link, block.timestamp + REVIEW_WINDOW);
        if (previous != 0) emit Resubmitted(jobId, id, msg.sender, previous);
    }

    function approve(uint256 jobId, uint256 submissionId) external nonReentrant {
        Job storage j = _open(jobId);
        if (msg.sender != j.creator) revert Unauthorized();
        Submission storage s = _pending(jobId, submissionId);
        s.state = SubmissionState.Approved;
        j.winnerSubmissionId = submissionId;
        emit Approved(jobId, submissionId, s.worker);
        _finalize(jobId, j);
        _credit(jobId, s.worker, j.amount);
    }

    function reject(uint256 jobId, uint256 submissionId, string calldata reason) external nonReentrant {
        Job storage j = _available(jobId);
        if (msg.sender != j.creator) revert Unauthorized();
        if (bytes(reason).length == 0 || bytes(reason).length > MAX_REASON_BYTES) revert InvalidInput();
        Submission storage s = _pending(jobId, submissionId);
        if (block.timestamp >= s.reviewUntil) revert WindowClosed();
        Worker storage w = _workers[jobId][s.worker];
        s.state = SubmissionState.Rejected;
        s.reason = reason;
        _reasons[jobId][s.worker].push(reason);
        w.revisionUntil = block.timestamp + w.revisionDuration;
        ++w.rejections;
        emit Rejected(jobId, submissionId, s.worker, reason, w.revisionUntil, w.rejections);
        if (w.rejections >= 3) _escalate(jobId, submissionId, j, s);
    }

    function escalate(uint256 jobId) external nonReentrant {
        Job storage j = _available(jobId);
        Worker storage w = _workers[jobId][msg.sender];
        if (w.submissionCount == 0 || w.closed) revert Unauthorized();
        Submission storage s = _submissions[w.latestSubmissionId];
        if (s.state == SubmissionState.Pending) {
            if (block.timestamp < s.reviewUntil) revert TooEarly();
            if (block.timestamp >= s.reviewUntil + ABANDON_AFTER) revert WindowClosed();
        } else if (s.state == SubmissionState.Rejected) {
            if (block.timestamp >= w.revisionUntil) revert WindowClosed();
        } else {
            // A failed oracle review must be revised, not appealed repeatedly unchanged.
            revert InvalidState();
        }
        _escalate(jobId, w.latestSubmissionId, j, s);
    }

    function _escalate(uint256 jobId, uint256 submissionId, Job storage j, Submission storage s) private {
        uint256 requestId = ++requestCount;
        uint256 settleAfter = block.timestamp + ORACLE_TIMEOUT;
        _requests[requestId] = Request(jobId, submissionId, block.timestamp, settleAfter, false, oracle);
        j.pendingRequestId = requestId;
        s.state = SubmissionState.Escalated;
        emit Escalated(jobId, submissionId, requestId);
    }

    /// @param reviewSeconds Zero retains the 48h default; otherwise clamped to [24h, 7 days].
    function answer(uint256 requestId, bool ok, uint256 reviewSeconds, string calldata reason) external nonReentrant {
        Request storage r = _requests[requestId];
        if (r.submissionId == 0) revert NotFound();
        Job storage j = _jobs[r.jobId];
        if (msg.sender != r.oracle || msg.sender == j.creator || _workers[r.jobId][msg.sender].submissionCount != 0) {
            revert Unauthorized();
        }
        if (r.resolved || j.pendingRequestId != requestId || j.state != JobState.Open) revert InvalidState();
        if (block.timestamp >= r.settleAfter) {
            emit OracleAnswerIgnored(r.jobId, requestId);
            return;
        }
        if (bytes(reason).length > MAX_REASON_BYTES) revert InvalidInput();
        r.resolved = true;
        j.pendingRequestId = 0;
        Submission storage s = _submissions[r.submissionId];
        Worker storage w = _workers[r.jobId][s.worker];
        s.reason = reason;
        if (ok) {
            s.state = SubmissionState.Approved;
            j.winnerSubmissionId = r.submissionId;
            emit OracleAnswered(r.jobId, requestId, r.submissionId, s.worker, true, reason, 0);
            _finalize(r.jobId, j);
            _credit(r.jobId, s.worker, j.amount);
        } else {
            _resumeClocks(r.jobId, s.worker, block.timestamp - r.requestedAt);
            s.state = SubmissionState.FailedReview;
            if (bytes(reason).length == 0) s.reason = "Oracle failed review";
            _reasons[r.jobId][s.worker].push(s.reason);
            ++w.failedReviews;
            uint256 duration = reviewSeconds == 0 ? REVISION_WINDOW : reviewSeconds;
            if (duration < MIN_REVISION) duration = MIN_REVISION;
            if (duration > MAX_REVISION) duration = MAX_REVISION;
            w.revisionDuration = duration;
            w.revisionUntil = block.timestamp + duration;
            emit OracleAnswered(r.jobId, requestId, r.submissionId, s.worker, false, s.reason, w.revisionUntil);
            if (w.failedReviews == 3) _close(r.jobId, s.worker, CloseReason.FailedReviews);
        }
    }

    function settleSplit(uint256 jobId) external nonReentrant {
        Job storage j = _open(jobId);
        if (j.pendingRequestId == 0) revert InvalidState();
        uint256 requestId = j.pendingRequestId;
        Request storage r = _requests[requestId];
        if (block.timestamp < r.settleAfter) revert TooEarly();
        r.resolved = true;
        j.pendingRequestId = 0;
        address worker = _submissions[r.submissionId].worker;
        // Floor the 40% worker share; creator receives the remainder, preserving every wei.
        uint256 workerAmount = (j.amount / 5) * 2 + ((j.amount % 5) * 2) / 5;
        _finalize(jobId, j);
        _credit(jobId, worker, workerAmount);
        _credit(jobId, j.creator, j.amount - workerAmount);
        emit Split(jobId, requestId, worker, j.amount - workerAmount, workerAmount);
    }

    function closeSlot(uint256 jobId, address worker) external nonReentrant {
        _available(jobId);
        Worker storage w = _workers[jobId][worker];
        if (w.submissionCount == 0 || w.closed) revert InvalidState();
        Submission storage s = _submissions[w.latestSubmissionId];
        if (s.state == SubmissionState.Pending) {
            if (block.timestamp < s.reviewUntil + ABANDON_AFTER) revert TooEarly();
            _close(jobId, worker, CloseReason.Abandoned);
        } else {
            if (w.revisionUntil == 0) revert InvalidState();
            if (block.timestamp < w.revisionUntil) revert TooEarly();
            _close(jobId, worker, CloseReason.RevisionExpired);
        }
    }

    function refund(uint256 jobId) external nonReentrant {
        Job storage j = _available(jobId);
        if (msg.sender != j.creator) revert Unauthorized();
        // Closing removes a worker by swapping in the last participant, so always close index zero.
        while (j.workerCount != 0) {
            address worker = _participants[jobId][0];
            Worker storage w = _workers[jobId][worker];
            Submission storage s = _submissions[w.latestSubmissionId];
            if (s.state == SubmissionState.Pending && block.timestamp >= s.reviewUntil + ABANDON_AFTER) {
                _close(jobId, worker, CloseReason.Abandoned);
            } else if (w.revisionUntil != 0 && block.timestamp >= w.revisionUntil) {
                _close(jobId, worker, CloseReason.RevisionExpired);
            } else {
                revert ActiveWorkers();
            }
        }
        j.state = JobState.Refunded;
        totalEscrow -= j.amount;
        _credit(jobId, j.creator, j.amount);
        emit Refunded(jobId, j.creator, j.amount);
    }

    /// @notice Only the beneficiary can claim; an alternate recipient supports reverting wallets.
    function claim(uint256 jobId, address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidInput();
        uint256 amount = claimable[jobId][msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[jobId][msg.sender] = 0;
        totalClaimable -= amount;
        emit Paid(jobId, msg.sender, recipient, amount);
        (bool sent,) = recipient.call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    function getJob(uint256 id) external view returns (Job memory) {
        return _existing(id);
    }

    function getWorker(uint256 jobId, address worker) external view returns (Worker memory) {
        return _workers[jobId][worker];
    }

    function getParticipants(uint256 jobId) external view returns (address[3] memory) {
        return _participants[jobId];
    }

    function getSubmission(uint256 id) external view returns (Submission memory) {
        return _submissions[id];
    }

    function getRequest(uint256 id) external view returns (Request memory) {
        return _requests[id];
    }

    function getReasons(uint256 jobId, address worker) external view returns (string[] memory) {
        return _reasons[jobId][worker];
    }

    function getOracleContext(uint256 jobId)
        external
        view
        returns (uint256 requestId, bytes32 jobHash, Submission memory latest, string[] memory reasons)
    {
        Job storage j = _existing(jobId);
        requestId = j.pendingRequestId;
        latest = _submissions[_requests[requestId].submissionId];
        return (requestId, j.jobHash, latest, _reasons[jobId][latest.worker]);
    }

    function _existing(uint256 id) private view returns (Job storage j) {
        j = _jobs[id];
        if (j.creator == address(0)) revert NotFound();
    }

    function _open(uint256 id) private view returns (Job storage j) {
        j = _existing(id);
        if (j.state != JobState.Open) revert InvalidState();
    }

    function _available(uint256 id) private view returns (Job storage j) {
        j = _open(id);
        if (j.pendingRequestId != 0) revert OraclePending();
    }

    function _pending(uint256 jobId, uint256 id) private view returns (Submission storage s) {
        s = _submissions[id];
        if (s.jobId != jobId || s.state != SubmissionState.Pending) revert InvalidState();
    }

    function _close(uint256 jobId, address worker, CloseReason reason) private {
        Worker storage w = _workers[jobId][worker];
        w.closed = true;
        Job storage j = _jobs[jobId];
        for (uint256 i; i < j.workerCount; ++i) {
            if (_participants[jobId][i] == worker) {
                --j.workerCount;
                _participants[jobId][i] = _participants[jobId][j.workerCount];
                delete _participants[jobId][j.workerCount];
                break;
            }
        }
        _cancelSubmission(jobId, w.latestSubmissionId, 0);
        emit SlotClosed(jobId, worker, reason);
    }

    function _credit(uint256 jobId, address beneficiary, uint256 amount) private {
        claimable[jobId][beneficiary] += amount;
        totalClaimable += amount;
    }

    function _finalize(uint256 jobId, Job storage j) private {
        j.state = JobState.Finalized;
        totalEscrow -= j.amount;
        if (j.pendingRequestId != 0) {
            _requests[j.pendingRequestId].resolved = true;
            j.pendingRequestId = 0;
        }
        for (uint256 i; i < j.workerCount; ++i) {
            uint256 id = _workers[jobId][_participants[jobId][i]].latestSubmissionId;
            _cancelSubmission(jobId, id, j.winnerSubmissionId);
        }
    }

    function _cancelSubmission(uint256 jobId, uint256 id, uint256 approvedId) private {
        Submission storage s = _submissions[id];
        if (
            s.state == SubmissionState.Pending || s.state == SubmissionState.Rejected
                || s.state == SubmissionState.Escalated || s.state == SubmissionState.FailedReview
        ) {
            s.state = SubmissionState.Cancelled;
            emit Cancelled(jobId, id);
            if (approvedId != 0) emit CancelledByApproval(jobId, id, approvedId);
        }
    }

    function _resumeClocks(uint256 jobId, address reviewedWorker, uint256 duration) private {
        Job storage j = _jobs[jobId];
        for (uint256 i; i < j.workerCount; ++i) {
            address worker = _participants[jobId][i];
            Worker storage w = _workers[jobId][worker];
            if (worker == reviewedWorker || w.closed) continue;
            Submission storage s = _submissions[w.latestSubmissionId];
            if (s.state == SubmissionState.Pending) {
                if (s.reviewUntil + ABANDON_AFTER > block.timestamp - duration) s.reviewUntil += duration;
            }
            // Already-expired windows must not be resurrected by somebody else's dispute.
            else if (w.revisionUntil > block.timestamp - duration) {
                w.revisionUntil += duration;
            }
        }
        emit ClocksResumed(jobId, duration);
    }

    function _checkText(string calldata text) private pure {
        if (bytes(text).length == 0 || bytes(text).length > MAX_TEXT_BYTES) revert InvalidInput();
    }
}
