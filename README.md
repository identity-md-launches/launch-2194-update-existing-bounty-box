# Bounty Box — Robinhood Chain contract update

ETH-only freelance escrow, targeting **Robinhood Chain (4663)**. This deliverable updates the accepted Bounty Box contract and its 43-test baseline. It adds a reviewer EOA, delayed oracle rotation, two-step administration, and the seven requested audit fixes. No frontend, token, proxy, platform fee, pause, or privileged withdrawal is included.

## Build and test offline

Foundry and Solidity **0.8.26** are required. `foundry.toml` is preserved from the accepted build: EVM Paris, optimizer 200 runs, `bytecode_hash = "none"`. The existing `forge-std` sources and licenses are vendored as ordinary files under `lib/forge-std`; no installation, network, environment settings, FFI, or filesystem permissions are required by the tests.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x21f50a8a752967460a9ad1d5fb42022c542ff80be06c38147f71318186c69056 forge test
forge fmt --check
```

- `src/BountyBox.sol`: self-contained deployable contract, also suitable for Remix.
- `script/RobinhoodConfig.sol`: the single deployment configuration for chain ID, public RPC, explorer, reviewer, and launch admin.
- `script/DeployBountyBox.s.sol`: chain-checked deployment script with directly testable deployment logic.
- `scripts/deploy-robinhood.py`: invokes that script using the RPC in the configuration.
- `test/BountyBox.t.sol`, `test/BountyBox.invariant.t.sol`: the original 42 test cases and accounting invariant, migrated where this assignment explicitly changes behavior.
- `test/BountyBox.updates.t.sol`, `test/DeployBountyBox.t.sol`: new success, failure, boundary, authorization, cancellation, and deployment tests.
- `docs/ORACLE.md`, `docs/SECURITY.md`: operational interface, responsibilities, administrative powers, and residual risks.

## Deployment

Deploy only `BountyBox(address oracle_, address admin_)`. Both arguments are static addresses and the constructor is nonpayable. It requires a nonzero oracle, makes no external calls, and does not require deployed code at either address.

| Parameter | Launch value |
| --- | --- |
| `oracle_` | `0xEB3e371d6830d20353b15304217be669E02a3136`, the specified platform reviewer EOA |
| `admin_` | `0x0165e692EbD858a81820C151c95760b5DD141323`, the launch owner supplied in the assignment |

The constructor accepts `admin_ == address(0)` to select `msg.sender`, as requested, and emits `AdminSet(admin)`. **The launch must pass the explicit owner**, because a factory is the constructor caller. The deployment script requires a nonzero explicit admin; its `run()` passes the configured launch owner. There is no post-deployment initialization.

Network settings live only in `script/RobinhoodConfig.sol`. The RPC is `https://rpc.mainnet.chain.robinhood.com`; the explorer is `https://robin.etherscan.io`. Chain ID is checked before broadcast starts and again in the deployment function. Ethereum mainnet and Base are rejected. The old Ethereum deployment is reference history only; this update neither modifies it nor migrates its funds or state.

A deployer can review a dry run using:

```sh
python3 scripts/deploy-robinhood.py
```

The wrapper forwards Foundry wallet and simulation options. In a separately authorized release, the deployment operator supplies their own Foundry signing configuration and explicitly adds `--broadcast`. This assignment does not broadcast, read keys, or write a launch manifest. The IMD launch can deploy the compiled `BountyBox` directly with the constructor values above; the script itself is not an application to deploy.

Compile in Remix with the same compiler, optimizer, EVM, and metadata settings if using the single source file. After deployment, verify constructor arguments and runtime bytecode, record the deployed address and receipt, and verify the source on the configured explorer.

## Escrow rules and boundaries

`createJob(bytes32 jobHash, uint256 deadline, string text)` checks the text hash and emits the full text. The two-argument overload works after `publishJobText(text)` publishes the matching preimage. A hash alone cannot recover text. Deposits must be positive; text, evidence links, and review reasons are public.

| Action | Rule |
| --- | --- |
| Create | Deadline strictly after creation and no more than 90 days ahead |
| First submit | Before the job deadline; nonzero content hash and nonempty link; worker cannot be the creator; at most three unclosed worker slots |
| Resubmit | Rejected or FailedReview, before revision expiry; at most five attempts per worker/job including the first; revisions may be after the job deadline |
| Approve | Creator can approve any still-Pending submission, including after its 3-day window or while another submission is escalated |
| Reject | Creator only, strictly before `reviewUntil`, with a nonempty reason; third and subsequent cumulative creator rejections automatically escalate |
| Escalate Pending | Its worker, from `reviewUntil` inclusive until `reviewUntil + 30 days` exclusive |
| Escalate Rejected | Its worker, strictly before revision expiry; a FailedReview must be revised before another review |
| Oracle yes | Request's original, unconflicted oracle only, before `settleAfter`; full bounty credited to reviewed worker |
| Oracle no | FailedReview with stored reason and a new revision window; third failed review closes the worker slot |
| Close expired slot | Anyone, at revision expiry or at `reviewUntil + 30 days` for an unescalated Pending submission |
| Refund | Creator only, no open request, every slot closed or eligible for closure; zero-submission jobs also qualify |
| Silent-oracle split | Anyone, at `request.requestedAt + 7 days`; 60% creator / 40% reviewed worker, regardless of job deadline |
| Claim | Only the credited beneficiary, to any nonzero recipient they choose |

Closing a slot cancels its current submission and emits `Cancelled` and `SlotClosed`, retaining reasons and attempt/rejection/failure counters. A closed worker cannot rejoin that job. Other new workers may use freed capacity before the original deadline. `getParticipants()` is the packed array of up to three unclosed slot holders, padded with zeros; `workerCount` counts those slots. Removed participants remain queryable through `getWorker`, submissions, and events. The job's lifetime `submissionCount` is now `uint256`, because recycling removes the old lifetime maximum of 15. No operation loops over historical participants or submissions.

A Pending submission eligible for abandonment remains approvable until actually closed; escalation is already unavailable at the abandonment boundary. The first successful transaction wins competing approval, closure, or timeout-settlement races. Only `reject()` expires at the 3-day review boundary.

During an open request, new submissions, rejection, escalation, closure, and refund remain blocked on that job. The creator can approve a different Pending submission. Finalization resolves and clears the request, cancels the disputed submission, and prevents a later answer or split payout. Other workers' live review/revision clocks resume after an oracle no by adding the request's elapsed duration. Already-expired revision and abandonment windows are not revived. The original deadline and the request's 7-day timeout never extend.

Approval and oracle yes cancel live competing submissions with both `Cancelled` and `CancelledByApproval(jobId, submissionId, approvedSubmissionId)`. Refund closes and cancels every remaining expired/abandoned submission atomically. Older versions stay Superseded. A split cancels live submissions without an approval event: it makes no quality judgment.

All end states create pull-payment credits. `claim(jobId, recipient)` is the only ETH transfer. Worker split credit is `floor(amount * 2 / 5)` and the creator receives the remainder; every wei is conserved, including tiny bounties. A receiver that rejects ETH cannot block finalization or other beneficiaries and can retry with a different recipient.

Constants: 3-day review, 48-hour default revision, 24-hour to 7-day oracle revision bounds, 30-day abandonment grace after `reviewUntil`, 7-day oracle timeout, 90-day maximum creation deadline, 24-hour oracle-change delay, three concurrent workers, five attempts per worker/job, 8,192-byte text, 2,048-byte link, and 1,024-byte reason limits. Byte limits refer to UTF-8 bytes. `reviewSeconds == 0` preserves the existing 48-hour default; nonzero values are clamped. No admin can change these values.

## After launch

- Reviewer: monitor `Escalated`, verify the job and evidence hashes, evaluate the work independently, and submit one timely `answer` from the oracle stored on that request. Fund gas separately; escrow pays no oracle fees.
- Admin: secure the role, monitor reviewer availability, and use the propose/24h/confirm procedure for future requests. Cancel mistakes before confirmation. Handover requires acceptance; renunciation permanently disables rotation.
- Creators and workers: keep evidence available and monitor review, revision, and abandonment deadlines. Submit claims for credited funds.
- Anyone: close eligible slots or settle silent requests; these require transactions and carry no keeper reward.
- Release operator: independently review the contract, verify the Robinhood deployment and explicit admin, and monitor events. There is no automatic callback, adapter, keeper, backend, or scheduler in this deliverable.

## Accepted-source provenance

The supplied workspace contained only task inputs. The accepted project was recovered from the [referenced IMD job](https://explorer.imd.fun/jobs/865f5b8b-7263-4943-be2b-50eeec478fcb), using its published bundle `d42c1ea2ddec2f66c717b7e5d07d091ce9d16bc3c28620fe4a889e64bb63fe4a` and commit `e4b9c8d4cc9098560951eadb54568ffe7e33cf79`. Its contract, tests, Foundry config, and vendored Solidity dependency formed the baseline. Frontend files were not imported for this contract-only assignment. See `test/TESTING.md` for the migration and verification coverage.
