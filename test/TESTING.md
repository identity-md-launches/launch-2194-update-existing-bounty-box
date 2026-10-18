# Test coverage and baseline migration

The accepted source bundle was recovered from the job linked in README. Its Foundry configuration is unchanged. All 43 original test cases remain: 42 unit/fuzz cases in `BountyBox.t.sol` and the accounting invariant in `BountyBox.invariant.t.sol`.

Several original assertions directly contradicted this update's requested fixes. They were migrated with the implementation, not removed or skipped:

| Original behavior tested | Updated expectation |
| --- | --- |
| Single-argument constructor, no owner | Two arguments, explicit admin, still no `owner()` interface or constructor code requirement |
| Adapter `request`/`oracleAnswer` | No external request invocation; reviewer calls `answer`; mock's request trap remains uncalled |
| Approval expired at review boundary | Rejection expires; creator can still approve Pending work; escalation remains available |
| All actions blocked by request | Other Pending work can be approved, resolving/cancelling the request; other action locks remain |
| Lifetime three-worker limit | Closed slots recycle, while each closed worker stays closed |
| Indefinite silence protection | Pending worker retains rights until the exact 30-day abandonment boundary |
| Deadline delayed split | Seven days from the request even with a later job deadline |
| Replayed oracle answer ignored | Replayed resolved requests revert; timely first answers still work; overdue unresolved answers remain ignored |
| Extended Escalated event | Exact three-index event in job/submission/request order |
| Invariant lifetime count <= 15 | Four modeled workers allow <= 20 submissions; concurrent slots remain <= 3 and per-worker attempts <= 5 |

`BountyBox.updates.t.sol` separately tests all seven fixes and all admin/oracle paths. It asserts success, failure, exact boundary behavior, event topics, liabilities, immutable request snapshots, retained worker history, cancellation, and competition between end states. The original three fuzz properties (split conservation, revision clamp, beneficiary isolation) are retained; new fuzz tests exercise late approvals and unauthorized admin callers.

`DeployBountyBox.t.sol` calls the deploy function directly with constants and explicit arguments. It tests the requested reviewer and owner, no accidental script ownership, rejection of zero admin, rejection of mainnet/Base, and the pre-broadcast chain guard. No test reads or writes environment variables or depends on the default script sender.

Run the complete offline checks from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x21f50a8a752967460a9ad1d5fb42022c542ff80be06c38147f71318186c69056 forge test
forge fmt --check
```

The stateful invariant uses 128 runs, 64 actions per run, and `fail_on_revert = true`. Its handler intentionally catches rejected user operations; the invariant independently checks stored escrow, every modeled beneficiary's credits, cumulative withdrawals, slot/attempt limits, and request consistency after each action. Tests use only a local EVM and vendored `forge-std`.

Validation result: **96 tests passed, zero failed, zero skipped** (43 migrated baseline cases plus 53 new cases), using the seed above. `forge build --sizes` and `forge fmt --check` passed. BountyBox runtime is **16,507 bytes** against the 24,576-byte limit. The slot-recycling regression exercises 260 submissions and completes approval within a 500,000-gas call after that history. The strengthened accounting invariant also checks packed participant uniqueness, cancelled closed submissions, and lifetime submission-count conservation.

The Python deployment wrapper was checked locally for configuration extraction, dry-run default, explicit broadcast forwarding, and rejection of network/entry-point override flags, without invoking a network or wallet.

## Independent test assignment additions

The original 96 tests above are unchanged. This assignment adds two files and uses the existing vendored Foundry dependencies; it does not modify application source, deployment scripts, configuration, or production documentation.

`BountyBox.adversarial.t.sol` adds 16 tests, including four fuzz properties with 1,000 runs each:

| Property or regression | Failure exercised |
| --- | --- |
| Full-width split accounting | One through ten wei, every division remainder, `uint256.max`, arbitrary positive `uint256` deposits, zero worker credit, and actual withdrawals of both shares |
| Mixed-state refund | Pending, Rejected, and FailedReview cancellations contain the exact job/submission IDs; Superseded history is preserved; no duplicate or approval-specific cancellation events |
| Atomic refund | Two eligible closures and packed-array swaps roll back when the last encountered worker still has rights |
| Recycled slots | Closing any of the three positions preserves access to every remaining worker and prevents a closed worker from rejoining |
| Paused abandonment | A failed competing dispute preserves the exact remaining abandonment interval; refund/closure/escalation boundaries are checked |
| Revision duration | Every duration within the 24h–7d clamp persists through resubmission and subsequent creator rejection, including strict expiry |
| Administration | Invalid zero replacements retain existing proposals; accepting handover cancels a mature proposal and requires a fresh delay; renunciation emits both cancellations and rejects every admin entry point |
| Request snapshots | Concurrent jobs keep different original reviewers through rotation, handover, and renunciation; wrong signers cannot consume either request |
| Oracle input bounds | A 1,025-byte reason reverts without consuming the request; a subsequent 1,024-byte reason succeeds |
| Pull payments | One reverting split recipient cannot block the other beneficiary; redirection pays only the beneficiary's credit; cross-job callback reentrancy cannot consume a second entitlement |

`BountyBox.lifecycle.invariant.t.sol` adds three invariant properties and a deterministic handler coverage test. Inline configuration pins **256 runs × 96 actions**, with unexpected handler reverts treated as failures. The handler targets 15 selectors: job creation, submission, review, escalation, answer, closure, refund, split, claim, forced ETH, time advancement, administration, unauthorized calls, terminal-job replays, and resolved-request replays. It models two creators, five workers, three possible admins, four possible reviewers (including conflicted creator/worker addresses), and up to twelve jobs per sequence. New jobs can be created during the sequence; scenarios do not depend solely on a finite setup escrow.

The properties have independent expectations:

- **Conservation and beneficiary isolation:** original input deposits and successful outcomes determine a separate entitlement ledger. Every onchain credit must match it. Actual recipient ETH deltas determine withdrawals. Each finished job releases exactly its own deposit; open jobs release nothing. Forced ETH is tracked separately and cannot become a claim.
- **Oracle/admin transitions:** a separate admin state model requires delayed confirmation, cleared proposals, two-step acceptance, and irreversible renunciation. Request digests fix the original job, submission, opening time, seven-day timeout, and reviewer. Resolution is tracked permanently. Unauthorized, expired-proposal, and replay attempts use exact expected errors.
- **Slot and history integrity:** independent submission counts/latest IDs/closed flags match each worker. Packed participants are unique, closed workers are absent, attempts remain bounded, and finished jobs have no live submissions. Terminal actions are actively retried to test that a job cannot reopen.

After every random sequence, `afterInvariant()` advances time, refunds or splits every remaining open job, and claims every entitlement to an accepting EOA. All deposited ETH must leave escrow; only independently tracked forced surplus may remain. Unexpected failure of any valid operation fails the campaign rather than being swallowed. The deterministic handler test reaches rotation, a failed answer by the original reviewer, revision, approval, a rejected claim, redirection, timeout split, handover, renunciation, refund, and full withdrawal.

The forced-ETH sender uses `selfdestruct` only in a test helper's constructor. Its purpose is to exercise surplus accounting; application runtime remains unchanged. Tests use a local EVM with no forks, RPC, FFI, environment mutation, wallet access, or new dependencies. These tests do not attest live Robinhood deployment or reviewer availability.

Validation: `forge build` and the full `forge test` with the pinned seed above pass. Foundry 1.8.3 reports **114 tests passed, zero failed, zero skipped**, grouping the three new invariant properties into one campaign result. The new campaign executes 24,576 random handler calls with no unexpected reverts, in addition to the original invariant's 8,192 calls. No implementation defect was reproduced during this test assignment.
