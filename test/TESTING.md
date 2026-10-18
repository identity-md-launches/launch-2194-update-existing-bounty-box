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

`DeployBountyBox.t.sol` calls the deploy function directly with constants and explicit arguments. It checks the configured reviewer and admin against their literal brief and launch-policy values (not the constants against themselves), no accidental script ownership, the zero-admin fallback to the calling wallet, rejection of that fallback for Foundry's default sender and for contract callers, rejection of mainnet/Base, and the pre-broadcast chain guard. No test reads or writes environment variables; the default-sender test pranks that address explicitly rather than relying on it.

Run the complete offline checks from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x21f50a8a752967460a9ad1d5fb42022c542ff80be06c38147f71318186c69056 forge test
forge fmt --check
```

The stateful invariant uses 128 runs, 64 actions per run, and `fail_on_revert = true`. Its handler intentionally catches rejected user operations; the invariant independently checks stored escrow, every modeled beneficiary's credits, cumulative withdrawals, slot/attempt limits, and request consistency after each action. Tests use only a local EVM and vendored `forge-std`.

Validation result: **96 tests passed, zero failed, zero skipped** (43 migrated baseline cases plus 53 new cases), using the seed above. `forge build --sizes` and `forge fmt --check` passed. BountyBox runtime is **16,507 bytes** against the 24,576-byte limit. The slot-recycling regression exercises 260 submissions and completes approval within a 500,000-gas call after that history. The strengthened accounting invariant also checks packed participant uniqueness, cancelled closed submissions, and lifetime submission-count conservation.

The Python deployment wrapper was checked locally for configuration extraction, dry-run default, explicit broadcast forwarding, and rejection of network/entry-point override flags, without invoking a network or wallet.
