# VerificationThroughput

**Agents write most of the pull requests now. The simulator still boots one at a time.**

Linear published the clearest write-up yet of what agent-authored code did to their
pipeline: test suites almost quadrupled since January, roughly two thousand new tests a week,
and CI stopped being a set of slow jobs and became *the* constraint on shipping. Their
fix rested on one lever — drive the fixed cost per shard down (110–140s → ~40s), *then*
go from four shards to eight. ([Linear: AI coding has made CI a bottleneck][linear] ·
[HN discussion][hn])

That lever does not exist on iOS.

The fixed cost per shard here is not a dependency install. It is simulator boot plus
code signing plus toolchain warm-up — minutes, not seconds — and it is paid **per
shard**, on runners that bill several times what a Linux runner does. Worse, the runner
pool is finite, so past its width the extra shards queue into a second wave and every
shard in that wave pays the boot tax *again*.

Which means the naive move — raise the shard count until it's fast — has a point past
which it makes the pipeline **slower and more expensive at the same time**. Most teams
never see that point, because the shard count lives in a YAML file, the spend lives in
a billing dashboard, and the merge-queue wait lives in somebody's head.

This package finds it.

```swift
let planner = VerificationPlanner(policy: policy)
let plan = planner.plan(
    changedPaths: changedPaths,
    graph: buildGraph,
    profiles: historicalDurations,
    tests: declaredTestMetadata,
    tier: .impacted
)
plan.shardCount        // chosen from the curve, not from a config file
plan.makespan          // list-scheduled against a finite runner pool
plan.projectedCost     // billed per shard, rounded up per minute
plan.pinnedTargets     // bundles the contract says cannot be split
```

---

## Why this matters

Three numbers move together and are almost never looked at together:

| | 1 shard | 4 shards | 8 shards |
|---|---|---|---|
| Makespan | 11m 00s | **5m 00s** | 8m 00s |
| Runner-time billed | 11m 00s | 20m 00s | 32m 00s |

*Eight equal 60s bundles, a 180s per-shard fixed cost, four concurrent runners. These
are the exact figures asserted in `testMakespanCurveHasAFloorAndRisesAfterIt` — run
`swift test` and they will be recomputed in front of you.*

Going from four shards to eight costs **60% more wall-clock and 60% more money**. Not
because sharding is wrong, but because eight shards do not fit in a four-wide pool, and
the second wave re-pays a boot tax that the first wave already paid.

An engineering lead's actual job here is not to pick a number. It is to make the number
derivable, make the trade-off visible, and put a governor in front of the queue so a
burst of speculative agent runs cannot starve the one job with a deadline.

---

## What's in it

### 1. `ChangeImpactAnalyzer` — select

Maps changed files to the test bundles that can observe them, by reverse-reachability
over the build graph.

The load-bearing decision is what to do with a path **nobody owns** — a new script, an
edited `Package.swift`, a path the graph exporter didn't know about. Skipping it is
fail-*open*: the pipeline gets faster and quietly stops catching a class of regression,
and nobody notices until production does. So an unowned path widens the plan to the
whole suite and sets `wasConservativelyWidened`, which the caller surfaces as *"we could
not narrow this run, and here is why."*

Prefix matching is directory-aligned, so `Sources/Checkout` does not swallow
`Sources/CheckoutUI/View.swift`. Traversal is an iterative worklist, so a malformed
export containing a dependency cycle terminates instead of exhausting the stack.

**Rejected:** treat unowned paths as no-ops and log a warning. Better headline numbers;
it is why people stop trusting selective testing.

### 2. `AgentTestContract` — check

Sharding does not merely *benefit* from isolated tests, it is **invalid** without them.
Two bundles sharing a file, a keychain entry, or a simulator default produce different
results depending on which shard they land in — and shard assignment changes whenever a
duration estimate does. So the failure never looks like a bug. It looks like flakiness,
and flakiness destroys the economics: teams respond by retrying, and a retry costs a
whole extra shard *including its boot*.

When people wrote the tests, code review was the enforcement mechanism. At agent-authored
volume it is not — nobody reads two thousand new tests a week closely enough to catch a
`static var` in a helper two files away. So the contract moves out of review and into CI:
a declaration on each test, and a gate that fails the build.

Bundles that fail are **pinned onto a single shard, not dropped**. Refusing to run them
would be the worse failure; the plan simply shows what their un-shardability costs
(`testShardUnsafeBundlesArePinnedOntoOneShard` measures it at 720s against 480s).

> **The most arguable decision in this package**, stated plainly: by default an
> agent-authored test is `.blocking` on hazards where a human-authored one is only
> `.advisory`. The reasoning is about where the review gate sits — a human integration
> test that deliberately hits staging had a reviewer who weighed that; the agent's did
> not. The costs are real: authorship metadata is self-reported and can be wrong, and a
> rule that treats two identical tests differently invites relabelling rather than
> fixing. `strictMode` ignores authorship and blocks on everything, for teams who would
> rather pay the friction.
>
> **Rejected:** infer hazards from source with a linter. It catches the obvious `static
> var` and misses everything reached through a helper. A gate with a known false-negative
> rate is worse than no gate, because people trust it.

### 3. `ShardPlanner` — pack

LPT bin-packing (longest processing time first) against a **finite** runner pool.

- `makespan` list-schedules shard durations onto `concurrencyLimit` lanes. This is the
  field that makes the model honest: with unlimited runners the makespan curve can only
  improve, and "too many shards" would not be a real failure mode.
- `optimalShardCount(for:maxShards:)` walks the curve and returns its floor, preferring
  fewer shards on a tie — two plans finishing at the same moment are not equal, and the
  one holding fewer runners leaves capacity for the next job.
- Empty shards are never emitted. A shard with no work still boots a device and still
  bills, so asking for 16 shards over 4 bundles yields 4.
- Packing is deterministic — ties broken by target id — so a plan diff is reviewable and
  a plan cache is worth having.

**Rejected:** round-robin by file or target name (the common default, and the reason one
shard routinely runs three times as long as its siblings — it balances *counts*, and the
makespan is not a max over counts). **Rejected:** exact optimal packing — this is
multiprocessor scheduling, NP-hard; a planner that thinks for longer than the imbalance
it saves is a net loss.

`NaiveRoundRobinPlanner` ships **in the library, not the tests**, so the suite can
falsify the claim above rather than assert it.

### 4. `SimulatorPool` — lease

A bounded actor-guarded pool of pre-warmed simulators, so boot cost is paid once per
*device* rather than once per shard.

That only works if the pool can safely take a device back from a job that stopped
responding — so leases carry a **fencing token**. A stalled job can be paused by the OS
or lose its network while the pool reclaims its device and hands it to someone else; when
the zombie wakes up it still believes it owns the device. Comparing tokens is what tells
"the current holder is releasing" apart from "a dead job is releasing a device that is no
longer its own", which would otherwise yank a live job's simulator out mid-run. Same idea
as fencing in front of a distributed lock: holding the lock is not enough, you have to
prove *which* acquisition you hold.

Reclaimed devices come back **cold, not warm**. An expired lease means the holder stopped
reporting mid-run, so the device's state is unknown — defaults, keychain, installed
builds, a modal left on screen. Recycling it warm is how one crashed job becomes a week
of "flaky on CI only."

`prewarm` is the one genuinely reentrant method: it suspends on every boot while other
callers run `acquire`/`release` against the same actor. Two rules, both load-bearing —
the candidate moves into `booting` *before* the `await` so no concurrent `acquire` can
hand out a half-booted device, and the loop condition is re-evaluated *after* every
`await` rather than a `needed` count being computed once (the classic reentrancy bug).

### 5. `AdmissionController` — govern

Decides whether a job runs now, runs smaller, or waits. The constraint is not CPU, it is
paid runner-minutes per hour; without an admission step a burst of agent PRs turns that
fixed budget into a queue nobody can reason about, with the merge queue stuck behind
speculative runs that will be force-pushed over in ninety seconds.

- **Degrade before deferring.** A job that cannot afford `full` is offered `impacted`,
  then `smoke`, before being told to wait. Partial signal now beats complete signal in
  forty minutes.
- **Aging guarantees progress.** Every deferral raises a job's *effective* class, so a
  speculative job that keeps losing eventually outranks the traffic beating it and reaches
  the merge-queue reserve. Strict priority without aging is a livelock with good
  intentions.
- **Bounded by construction.** The reservation ledger is bucketed by time, so it holds at
  most `windowLength / bucketSize` entries no matter the request rate. Deferral history is
  capped and FIFO-evicted — documented as costing aging fidelity past
  `maximumTrackedJobs`, which is a state where starvation is not the first problem.

`StarvationAuditor` drives the real actor under a saturating load and reports whether the
victim ever gets in — so the guarantee is executable, not prose. See below for why that
matters.

### 6. `SaturatingMath` — don't crash the orchestrator

Every arithmetic operation in the package is total. `+`, `*`, `/`, `%` and
`Int(someDouble)` all trap in Swift, and a scheduler aborting because a historical-duration
table held a garbage value is strictly worse than one that clamps. `Int.saturating(from:)`
handles NaN, ±infinity and out-of-range; its bounds derive from `Int.max`/`Int.min` rather
than 64-bit literals. Money is integer `MicroUSD`, billed per shard and rounded **up** per
minute, because a 61-second job costs two minutes and a model that calls it 1.02 minutes
under-predicts every invoice it produces.

---

## Tests that can fail

95 XCTest cases across 8 suites. A test that would still pass against a gutted
implementation is worse than no test, because it reads like coverage — so each of these
was checked by actually breaking the thing it guards and confirming it goes red:

| Test | The mutation it kills |
|---|---|
| `testStarvationAuditorDistinguishesAgingFromNoAging` | Same auditor, same load, same victim; only `agingThreshold` differs. Asserts starvation-free **with** aging (after exactly 4 deferrals) and **starvation detected without it**. An auditor that passed both would be measuring nothing. |
| `testLPTBeatsRoundRobinOnMakespanAndBalance` | Swap `ShardPlanner` for `NaiveRoundRobinPlanner` over identical input: 880s vs 980s at equal runner-time. |
| `testMakespanCurveHasAFloorAndRisesAfterIt` | Give `makespan` unlimited lanes. 8 shards must be slower *and* dearer than 4 in a 4-wide pool. |
| `testStaleTokenCannotStealTheSuccessorsDevice` | Delete the fencing-token comparison — the zombie's release then succeeds and steals a running job's device. Also killed by recycling a reclaimed device warm. |
| `testPrewarmRereadsTheWarmTargetAfterEveryAwait` | Cache the "how many do I still need" count before the loop. The first boot reaches back in and releases two devices mid-suspension; a cached count boots 3 instead of 1 and overshoots. Interleaving is forced, not raced. |
| `testDeviceIsAccountedForAndUnleasableWhileMidBoot` | Move `booting.insert` to *after* the `await`. Observed from inside the boot closure — the only moment the pool is mid-boot. |
| `testStringPrefixIsNotOwnership` | Replace `isDirectoryPrefix` with `hasPrefix`. The fixture's only root is the *shorter* string, so the longest-prefix sort cannot mask the bug. |
| `testAZeroCostLowerTierIsNeverADegradationTarget` | Drop `price > 0` from the tier walk — a job then gets "admitted" into a tier that runs nothing and reports green. |
| `testDuplicateProfilesKeepTheLongerDurationInEitherOrder` | Last-writer-wins dedupe. Only the reversed ordering discriminates. |
| `testCurveSamplesHaveDistinctShardCounts` | Emit one curve sample per *requested* count. Over 8 bundles with two pinned, requests for 1…10 shards collapse to 7 achievable counts, and duplicate ids render undefined in a `ForEach`. |
| `testBaselinesHonourPinning` | Compute `ShardPlanner`'s baselines without the pinning constraint the real plan honours. |
| `testPlannerBaselinesHonourThePinningConstraint` | The same mutation one layer up, in the wiring the console actually renders: drop `pinnedTogether:` from `VerificationPlanner`'s three baseline calls and `savedVersusMaximumWidth` goes **negative** — the screen reports a strawman as faster than the plan beating it. |
| `testDeliberatelyUnsafeAgentTestIsBlocked` | Make every hazard advisory. |
| `testUnownedPathWidensRatherThanNarrows` | Fail open on unowned paths. Pins what the unsafe version produces — an *empty* selection — so it fails on `isEmpty`, not merely on a flag. |
| `testPerShardRoundingIsNotTheSameAsRoundingTheTotal` | Round the total instead of each shard: under-bills by a whole minute. |
| `testOnlyCoLocationHazardsProducePinnedTargets` | Make `duplicateIdentifier` pin-fixable — the planner then "solves" a real bug by grouping and the build goes green. |

`testConcurrentPrewarmAndLeasingPreservesInvariants` and
`testPrewarmRacingReleasesDoesNotDoubleFileADevice` are fuzz-style backstops, not
mutation tests, and are named here as such: twelve concurrent writers across `prewarm`'s
suspension points, asserting only that every device stays accounted for exactly once.

---

## Installation

```swift
.package(url: "https://github.com/rajatslakhina/verification-throughput-kit.git", from: "1.1.0")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "VerificationThroughput", package: "verification-throughput-kit")
])
```

`VerificationThroughput` is the platform-agnostic core — no UIKit, no SwiftUI, builds and
tests on Linux. `VerificationThroughputUI` adds the SwiftUI console and is behind
`#if canImport(SwiftUI)`.

Swift 6 language mode, strict concurrency, iOS 17 / macOS 14.

---

## Verification

What actually happened, stated exactly:

- **`swift build -Xswiftc -warnings-as-errors`** — clean, from a deleted `.build`, zero
  warnings. Enforced in CI on the Linux job rather than asserted here, because a build
  over an up-to-date tree compiles nothing and still prints `Build complete!`.
- **`swift test`** — 95 tests across 8 suites, 0 failures.
- **Two CI jobs**, both on every push: Linux (`swift:6.0` container, warnings-as-errors,
  build + build-tests + test) and `macos-15` (`swift build` + `swift test`). The macOS job
  exists specifically because the Linux job never compiles
  `Sources/VerificationThroughputUI` — it is behind `#if canImport(SwiftUI)`, so Linux
  skips it entirely. Live results: **[Actions tab](../../actions)**.
- **The companion demo app's CI is green too**, and it is the stronger check: on
  `macos-15` it resolves this package from GitHub at its released version and then runs
  `xcodebuild build -destination 'generic/platform=iOS Simulator'`. So
  `VerificationThroughputUI` is known to compile **for iOS**, not merely for the host.
- **The SwiftUI console was still never launched on a Simulator.** A compile check boots
  no device, and no human ran it either. Nobody has seen this UI render. "Compiles for a
  Simulator" and "ran on a Simulator" are different claims; only the first is true, and
  the demo repo says so in the same words.

Demo app: **[verification-throughput-kit-demo-app][demo]** — a runnable SwiftUI console
that consumes this package as a version-pinned remote dependency.

## Licence

MIT. See [LICENSE](LICENSE).

[linear]: https://linear.app/now/ci-bottleneck-reworked
[hn]: https://news.ycombinator.com/item?id=49792067
[demo]: https://github.com/rajatslakhina/verification-throughput-kit-demo-app
