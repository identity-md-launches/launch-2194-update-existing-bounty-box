# Oracle and administration

## Constructor and integration

`BountyBox(address oracle_, address admin_)` takes the reviewer EOA and admin explicitly. The launch reviewer is **`0xEB3e371d6830d20353b15304217be669E02a3136`**. Addresses are stored as 20-byte Solidity addresses; EIP-55 checksum spelling is used in source configuration and documentation, because storage has no letter case. A zero oracle reverts. A zero admin selects the deployer and emits `AdminSet(admin)`. The factory launch passes `$owner`, and the script's `run()` passes the same address from `script/RobinhoodConfig.sol`: the launch owner stated in the IMD launch policy for this job, `0x0165e692EbD858a81820C151c95760b5DD141323`. The brief and job page name no admin wallet; that policy is the address's source. The script's `deploy(address(0))` installs the calling wallet instead, refusing Foundry's default sender and contract callers.

There is **no oracle adapter, request call, or callback interface**. The contract never calls the reviewer. `IOracle`, `IOracleCallback`, `oracleAnswer`, the request gas stipend, and `OracleRequestUnavailable` have been removed. Operators must use the new interface:

```solidity
event Escalated(uint256 indexed jobId, uint256 indexed submissionId, uint256 indexed requestId);
function answer(uint256 requestId, bool ok, uint256 reviewSeconds, string calldata reason) external;
```

The three event fields are in the order shown. Each request stores `jobId`, `submissionId`, `requestedAt`, `settleAfter`, `resolved`, and **its own `oracle` address**. `getRequest(requestId)` returns that snapshot. Confirmation of an oracle change affects requests opened afterward; even old requests on otherwise continuing jobs retain their original signer.

For each event, read `getJob(jobId)`, `getSubmission(submissionId)`, `getRequest(requestId)`, and `getReasons(jobId, worker)` to reconstruct the evidence. `getOracleContext(jobId)` also returns the current request ID, job hash, disputed submission, and accumulated reasons. Full briefs are available in `Created`; links and content hashes are in submissions and `Submitted`. Validate fetched bytes against their hashes. Events and hashes do not prove quality, availability, or authorship.

## Answer authorization and outcomes

Only `request.oracle` may answer. That address must not be the job creator or **any worker who has ever submitted on that job**, including a closed worker whose slot was recycled. A matching reviewer address is still rejected if conflicted. Participation in a different job does not disqualify it here. These are address checks, not a proof that different wallets have different controllers.

A request accepts one timely answer. Duplicate answers, answers to cancelled/settled requests, and answers to otherwise resolved requests revert `InvalidState`. Unknown IDs revert `NotFound`; the wrong or conflicted signer reverts `Unauthorized`. An authorized answer at or after `settleAfter` but before settlement emits `OracleAnswerIgnored` and changes no adjudication state; it cannot change the timeout or prevent a split.

- `ok == true`: store the reason, approve that submission, finalize, and credit the entire bounty to its worker. Cancel all live competing submissions with `Cancelled` and `CancelledByApproval`.
- `ok == false`: mark FailedReview, store and emit the reason, increment the worker's failure counter, and open a revision window. Empty reason becomes `"Oracle failed review"`. A third failed review closes the slot, cancels the submission, and releases its capacity; the failure event, reason, and counter remain available.
- `reviewSeconds == 0`: retain the existing 48-hour revision default. Other values are clamped to **24 hours through 7 days**, inclusive. This duration controls revisions and later rejection windows for that worker, not the fixed 3-day creator review or the 7-day timeout. Oversized reasons (over 1,024 bytes) revert without consuming the request.

While a request is open the creator can approve a different Pending submission. This finalizes the job, resolves and clears the request, and cancels the disputed submission. A reviewer should check `resolved` and the job's state immediately before submitting; a transaction can still lose an inclusion race and revert.

## Timeout and availability

`settleAfter = requestedAt + 7 days`, independent of the original job deadline. At or after that timestamp, anyone may call `settleSplit(jobId)`: the worker receives `floor(amount * 2 / 5)` and the creator receives the rest. Both are claimable credits. No answer, rotation, or repeat request can extend an open request's timeout.

If the stored oracle is unavailable, conflicted, or loses its key, **the admin cannot reassign the request**. The 7-day split remains its fallback, unless the creator approves another Pending submission first. There is no automatic settlement or keeper reward. A successful oracle no resumes the other workers' live clocks and gives the reviewed worker the new bounded revision window. Expired revision/abandonment windows stay expired.

## Admin controls

The admin's only protocol power is changing the oracle for **future requests**. It has no fund access, pause, parameter setters, upgrades, evidence-editing rights, or authority to answer on behalf of a request's oracle.

| Function | Caller and effect |
| --- | --- |
| `proposeOracle(newOracle)` | Current admin; nonzero address; emits `OracleProposed(newOracle, confirmAfter)` and sets `confirmAfter = now + 24 hours` |
| `confirmOracle()` | Current admin, at or after `oracleChangeAfter`; emits `OracleConfirmed(previousOracle, newOracle)` and clears the proposal |
| `cancelOracle()` | Current admin, before confirmation (including after the delay); emits `OracleCancelled(newOracle)` and clears the proposal |
| `transferAdmin(newAdmin)` | Current admin; nonzero nominee; emits `AdminTransferProposed(admin, newAdmin)`; current admin retains powers |
| `acceptAdmin()` | Only the pending nominee; emits `AdminSet(newAdmin)` and clears the nomination |
| `cancelAdminTransfer()` | Current admin, before acceptance; emits `AdminTransferCancelled(newAdmin)` |
| `renounceAdmin()` | Current admin; clears pending oracle/admin proposals and emits cancellation events, then `AdminSet(address(0))`; permanently freezes the current oracle |

A replacement oracle proposal cancels the previous one and starts a fresh 24-hour delay; it cannot reuse time already waited. Replacing an admin nominee revokes the previous nomination. Successful admin acceptance cancels any outstanding oracle proposal so the successor must propose afresh. An admin nominee has no powers before acceptance. All admin operations fail after renunciation; a previously nominated successor cannot revive the role. Existing oracle answers, normal job actions, claims, and timeout settlements continue.

## Operator responsibilities

The reviewer runs any offchain event listener, handles reorgs and missed logs, retrieves evidence, makes the decision, and funds its own answer gas. The admin monitors availability and announces rotations so users can assess the reviewer for future requests. Users who submit work before a future escalation rely on the oracle current **when escalation opens**, not the one current at job creation.

Secure the reviewer and admin separately where practical. A compromised admin can nominate a dishonest future reviewer, subject to the public 24-hour delay; it cannot rescue old requests or withdraw escrow directly. A compromised reviewer can misjudge eligible requests. Renunciation removes recovery through rotation and must be a deliberate operational decision.

The configured public Robinhood RPC is `https://rpc.mainnet.chain.robinhood.com`. A read-only check during this assignment returned chain ID 4663 and empty code (`0x`) for the supplied reviewer, consistent with its specified EOA role. This is not an attestation of key ownership or reviewer availability. No deployment or signed transaction was performed.
