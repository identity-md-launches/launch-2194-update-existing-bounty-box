# Security model and review notes

## Roles and authority

**An admin exists.** Its only protocol power is changing the reviewer oracle for future requests. Every oracle change requires proposal by the current admin, a **24-hour delay**, and confirmation by that admin. The admin can cancel a proposal. Replacement proposals restart the delay. It cannot pause the contract, withdraw or redirect escrow, claim others' credits, change limits or economic parameters, upgrade code, edit evidence, or override decisions on open requests.

The admin can nominate a successor, who must explicitly accept; the current admin can cancel before acceptance. Acceptance cancels outstanding oracle proposals. Renunciation clears all pending proposals, sets admin to zero, and **permanently disables oracle rotation and administrative recovery**. The current oracle and existing requests continue working. These administrative functions make no external calls.

Each oracle request snapshots its reviewer address. Only that reviewer can answer, once, and it is rejected if it is the creator or any past/current worker on that job. A rotation never transfers an open request. If its reviewer is dead or conflicted, the job retains the original 7-day timeout split. Admin status itself grants no answer authority.

The constructor accepts zero admin as the explicit deployer fallback required by this update. The factory launch must pass an explicit admin so the factory does not acquire the role; the manifest does this with `$owner`. The admin installed by the script, `0x0165e692EbD858a81820C151c95760b5DD141323`, is the launch owner stated in the IMD launch policy for this job and is the address `$owner` resolves to. It was not supplied by the update brief or the job page, which name no admin wallet; the policy is its only source, and the script and manifest are kept on the same value so neither deployment path installs a different admin. The script's zero-admin path installs the calling wallet, refuses Foundry's default sender and contract callers, and every path rejects every chain except Robinhood Chain. No proxy, initializer, delegatecall, upgrade, token, or adapter is used.

Because the admin is the only privileged role, whoever holds the launch owner key can, after the public 24-hour delay, install any future reviewer. A dishonest future reviewer could approve escalations in full for a colluding worker on requests opened after the change. The admin still cannot withdraw escrow, pause, change limits, edit evidence, upgrade, or touch requests already open.

## Custody and settlement

The creator deposits native ETH. Every payout is pull-based: approval, oracle yes, refund, and split update credits without calling a recipient. `claim` clears the credit and reduces total liabilities before its checked ETH transfer, under a reentrancy guard. Failed transfers revert those effects atomically. Beneficiaries can retry with another nonzero recipient. An adversarial receiver cannot block another beneficiary or finalization.

Ordinary accounting obeys `balance == totalEscrow + totalClaimable`. Forced ETH can create surplus, so the invariant is `balance >= liabilities` in the presence of forced transfers. There is no sweep function; surplus cannot be recovered by the admin. No oracle fee is charged. Split arithmetic avoids overflow and credits the creator with rounding dust, conserving every deposited wei.

A job finalizes at most once. Creator approval during a request marks that request resolved, clears its pointer, cancels its submission, and credits only the approved worker. Subsequent answers or split attempts cannot pay again. Cross-job submission IDs are checked. Authentication precedes any request mutation. Invalid or oversized answers leave the request and its timeout intact.

## Liveness and bounded work

- A Pending submission may escalate starting at its 3-day review boundary and ending strictly before 30 further days have passed. At that boundary anyone can close it as abandoned; the creator can refund once every slot is closed/eligible. Before then a refund cannot bypass that worker's rights.
- Creator approval remains possible for any still-Pending submission even after review expiry; rejection stays time-limited. Approving another Pending submission remains possible while a request is open.
- New job deadlines are capped at 90 days. Every request's timeout is exactly 7 days from its opening, independent of the deadline.
- Closed slots release capacity. The closed worker's history and counters remain, so it cannot rejoin and reset its five attempts or three failed reviews. Fresh wallets can join before the deadline.
- Closure cancels the latest live submission and emits both cancellation and closure. Refund auto-closes eligible workers atomically and emits those same events. Superseded versions remain historical.
- The participant array is packed and bounded at three. Finalization, refund, and clock-resumption work is bounded independently of lifetime participants. The total submission counter is widened to avoid overflow after repeated recycling.
- Other workers' live clocks pause during disputes and resume after oracle no. Already-expired revision and abandonment windows are not revived. Neither job deadlines nor open request deadlines are extended.

All timing uses `block.timestamp`, suitable for the target EVM/L2; no rule relies on L2 block-number semantics. At exact boundaries, rejection/revision/escalation expiry takes effect, closure/settlement becomes available, and oracle confirmation becomes available. Approval and settlement/closure can race; the first valid included transaction determines the end state. Transactions and monitoring are required for liveness; no scheduler or keeper reward is provided.

## Trust and economic limitations

The reviewer is a trusted decision-maker for work quality. The contract verifies address authorization and deadlines, not the truth of a review. An admin can select a dishonest future reviewer after the public delay. Requests already opened remain with their original reviewer; work submitted before escalation is subject to the reviewer current when its request opens. Renunciation removes future rotation but does not remove trust in that reviewer.

Creator/worker identity is address-based. A creator can approve its own second wallet and cancel honest competing work. This cannot be prevented by an onchain address inequality. `CancelledByApproval(jobId, submissionId, approvedSubmissionId)` explicitly records every live competitor cancelled by creator or oracle approval, alongside `Cancelled`; it provides evidence for reputation systems, not compensation or Sybil resistance.

A silent oracle intentionally gives 40% to the escalated worker without a quality verdict, so junk work can profit from reviewer outages. Slot recycling prevents a permanent three-address capacity lock but does not stop repeated Sybil submissions. A fifth failed attempt can retain a bounded revision window even though another revision is disallowed; expiry still enables closure/refund. Public hashes prove byte identity, not authorship, availability, or satisfactory work.

Robinhood sequencer/chain availability, transaction ordering, reviewer operation, RPC history, and evidence hosting are external dependencies. The 24-hour delay is notice, not a unilateral exit window for creators with active workers. No frontend or identity/reputation service is implemented here.

## Validation and remaining release work

The accepted 42 unit/fuzz tests and accounting invariant were retained and migrated only where the constructor/API or requested behavior changed. New tests cover each audit fix, event contents, administrative success/failure paths, request-specific oracle authorization across rotation, conflicted creators/workers (including closed workers), renunciation, and chain-checked deployment. Tests also exercise receiver rejection, claim reentrancy, time boundaries, invalid inputs, replay, isolation, and exact split conservation. `test/TESTING.md` maps the migration.

Validation uses the pinned Solidity 0.8.26 configuration and the assignment's fuzz seed. The stateful accounting invariant explores 128 runs of 64 actions; fuzz tests use 256 runs. Runtime size and executable opcodes are checked against the EIP-170 limit and the supplied forbidden-opcode rule. The build and test dependencies are vendored for offline verification.

The final run passed all 99 tests, build, and formatting checks. Runtime is 16,507 bytes. Foundry lint still reports timestamp comparisons, intentional quotient/remainder split arithmetic, atomic refund reverts in a bounded loop, and beneficiary-selected guarded ETH transfers. Its admin-event warning is covered by `AdminSet` emitted after acceptance; its zero-admin warning reflects the required deployer fallback. These paths were inspected and exercised; diagnostics were not suppressed.

Passing tests and this implementation review are not an independent audit. Slither and Mythril were not run. The launch operator must obtain independent adversarial review, verify the deployed bytecode and constructor arguments on Robinhood Chain, and establish event monitoring and reviewer availability before funded public use. No deployment, account/key access, or signed transaction took place in this assignment.
