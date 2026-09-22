import Foundation

/// What history says a test bundle costs to run.
public struct TestTargetProfile: Sendable, Hashable {
    public let id: TargetID
    /// Observed p95 wall-clock duration of the bundle's tests, excluding any
    /// per-shard fixed cost. p95 rather than mean: the scheduler is bounding a
    /// *makespan*, and a makespan is a max, so planning against an average
    /// guarantees the plan is wrong about half the time.
    public let historicalDuration: Milliseconds
    public let testCount: Int

    public init(id: TargetID, historicalDuration: Milliseconds, testCount: Int) {
        self.id = id
        // A negative duration is meaningless and would corrupt bin packing by
        // making a shard look emptier the more work it holds.
        self.historicalDuration = max(0, historicalDuration)
        self.testCount = max(0, testCount)
    }
}

/// One unit of parallel work: a set of test bundles run on a single leased
/// simulator, paying the fixed cost exactly once.
public struct Shard: Sendable, Hashable {
    public let index: Int
    public let targets: [TargetID]
    /// Sum of the member bundles' durations, excluding fixed cost.
    public let work: Milliseconds

    public init(index: Int, targets: [TargetID], work: Milliseconds) {
        self.index = index
        self.targets = targets
        self.work = work
    }
}

public struct ShardPlan: Sendable, Hashable {
    public let shards: [Shard]
    public let fixedCostPerShard: Milliseconds
    /// How many shards can genuinely run at the same time — the size of the
    /// simulator pool, or the runner concurrency the plan allows itself.
    ///
    /// This is the field that makes the model honest. With unlimited runners,
    /// makespan can only ever improve as shards are added, and "too many
    /// shards" is not a real failure mode. Concurrency is not unlimited: past
    /// `concurrencyLimit` the shards queue into a second wave, and every shard
    /// in that wave pays the boot tax *again*.
    public let concurrencyLimit: Int

    public init(shards: [Shard], fixedCostPerShard: Milliseconds, concurrencyLimit: Int) {
        self.shards = shards
        self.fixedCostPerShard = max(0, fixedCostPerShard)
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    /// Duration of each shard, boot included.
    public var shardDurations: [Milliseconds] {
        shards.map { SaturatingMath.add(fixedCostPerShard, $0.work) }
    }

    /// Wall-clock time to finish, list-scheduled onto `concurrencyLimit`
    /// runners: longest shard first, each onto whichever runner frees up
    /// soonest.
    public var makespan: Milliseconds {
        guard !shards.isEmpty else { return 0 }
        let lanes = max(1, min(concurrencyLimit, shards.count))
        var finish = [Milliseconds](repeating: 0, count: lanes)
        for duration in shardDurations.sorted(by: >) {
            var earliest = 0
            for index in 1..<lanes where finish[index] < finish[earliest] {
                earliest = index
            }
            finish[earliest] = SaturatingMath.add(finish[earliest], duration)
        }
        return finish.max() ?? 0
    }

    /// Billable runner-time across every shard. Grows with shard count while
    /// makespan (up to a point) shrinks — the tension the planner resolves.
    public var totalRunnerTime: Milliseconds {
        SaturatingMath.sum(shardDurations)
    }

    /// Number of boots this plan pays for. One per shard, always: a shard in
    /// the second wave does not inherit the first wave's warm device, because
    /// that device has a test bundle's worth of state on it.
    public var bootCount: Int { shards.count }

    public var shardCount: Int { shards.count }

    public var assignedTargets: [TargetID] { shards.flatMap(\.targets) }

    /// Spread between the busiest and idlest shard. A large imbalance means one
    /// shard *is* the pipeline and the rest are paid idle time.
    public var imbalance: Milliseconds {
        guard let maximum = shards.map(\.work).max(),
              let minimum = shards.map(\.work).min() else { return 0 }
        return SaturatingMath.subtract(maximum, minimum)
    }
}

/// A single point on the "what does adding a runner buy me" curve.
public struct ShardCountSample: Sendable, Hashable {
    public let shardCount: Int
    public let makespan: Milliseconds
    public let totalRunnerTime: Milliseconds
}

/// Packs test bundles into shards.
///
/// ## Why this is not "split the tests N ways"
///
/// Every shard pays a fixed cost before its first assertion: simulator boot,
/// code signing, toolchain warm-up. On a web stack that cost is a dependency
/// install and can be driven toward zero, which is why "add more shards" works
/// there. On iOS it is minutes, it is paid per shard, and the runner pool is
/// finite — so beyond the pool size the shards queue into waves and each wave
/// pays the boot tax again. The makespan curve therefore has a floor, and past
/// it every extra shard makes the run **both slower and more expensive**.
///
/// `optimalShardCount(for:maxShards:)` finds that floor instead of treating the
/// shard count as an article of faith set once in a YAML file.
///
/// Packing uses **LPT** (longest processing time first): sort descending, drop
/// each bundle onto the currently-lightest shard. Rejected alternatives:
/// - *Round-robin by file or target name* — the common default, and the reason
///   one shard routinely runs three times as long as its siblings. It balances
///   counts, and the makespan is not a max over counts.
/// - *Exact optimal packing* — multiprocessor scheduling, NP-hard. LPT is
///   greedy with a known bound and runs in `O(n log n)`; a planner that thinks
///   for longer than the imbalance it saves is a net loss.
public struct ShardPlanner: Sendable {

    public let fixedCostPerShard: Milliseconds
    public let concurrencyLimit: Int

    public init(fixedCostPerShard: Milliseconds, concurrencyLimit: Int) {
        self.fixedCostPerShard = max(0, fixedCostPerShard)
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    /// Packs `profiles` into at most `shardCount` shards.
    ///
    /// - Parameter pinnedTogether: bundles that must share a shard because they
    ///   are not isolation-safe (see ``AgentTestContract``). Packed as one
    ///   indivisible item.
    ///
    /// Empty shards are never emitted. A shard with no work still boots a
    /// simulator and still bills, so `shardCount: 16` over four bundles
    /// produces four shards, not sixteen.
    public func plan(
        _ profiles: [TestTargetProfile],
        shardCount: Int,
        pinnedTogether: Set<TargetID> = []
    ) -> ShardPlan {
        guard !profiles.isEmpty else {
            return ShardPlan(
                shards: [],
                fixedCostPerShard: fixedCostPerShard,
                concurrencyLimit: concurrencyLimit
            )
        }

        // Deduplicate on id, keeping the longest duration — a graph export that
        // lists a bundle twice must not make it look half as expensive.
        var byID: [TargetID: TestTargetProfile] = [:]
        for profile in profiles {
            if let existing = byID[profile.id], existing.historicalDuration >= profile.historicalDuration {
                continue
            }
            byID[profile.id] = profile
        }

        let pinnedPresent = pinnedTogether.intersection(byID.keys)
        let pinsApply = pinnedPresent.count > 1

        struct Item {
            var targets: [TargetID]
            var duration: Milliseconds
        }

        var items: [Item] = []
        if pinsApply {
            let sortedPinned = pinnedPresent.sorted()
            let duration = SaturatingMath.sum(sortedPinned.map { byID[$0]?.historicalDuration ?? 0 })
            items.append(Item(targets: sortedPinned, duration: duration))
        }
        let loose = byID.values
            .filter { pinsApply ? !pinnedPresent.contains($0.id) : true }
            .sorted { $0.id < $1.id }
        items.append(contentsOf: loose.map { Item(targets: [$0.id], duration: $0.historicalDuration) })

        // Longest first; ties broken by the first target id so packing is
        // reproducible across runs and across machines.
        items.sort { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
            return (lhs.targets.first ?? TargetID("")) < (rhs.targets.first ?? TargetID(""))
        }

        let effective = min(max(1, shardCount), items.count)

        var work = [Milliseconds](repeating: 0, count: effective)
        var buckets = [[TargetID]](repeating: [], count: effective)

        for item in items {
            var lightest = 0
            for index in 1..<effective where work[index] < work[lightest] {
                lightest = index
            }
            work[lightest] = SaturatingMath.add(work[lightest], item.duration)
            buckets[lightest].append(contentsOf: item.targets)
        }

        var shards: [Shard] = []
        shards.reserveCapacity(effective)
        for index in 0..<effective where !buckets[index].isEmpty {
            shards.append(
                Shard(index: shards.count, targets: buckets[index].sorted(), work: work[index])
            )
        }

        return ShardPlan(
            shards: shards,
            fixedCostPerShard: fixedCostPerShard,
            concurrencyLimit: concurrencyLimit
        )
    }

    /// The makespan/cost curve from 1 shard up to `maxShards`.
    ///
    /// Each sample is a *distinct achievable* shard count. Requesting more
    /// shards than there are packing items produces the same plan — and
    /// pinning collapses several bundles into one item, so the achievable
    /// maximum is often below `profiles.count`. Those repeats are dropped:
    /// they are not separate points on the curve, and emitting them would give
    /// two samples the same identity (which, among other things, makes them
    /// unusable as a `ForEach` id).
    public func makespanCurve(
        for profiles: [TestTargetProfile],
        maxShards: Int,
        pinnedTogether: Set<TargetID> = []
    ) -> [ShardCountSample] {
        guard !profiles.isEmpty else { return [] }
        let ceiling = max(1, min(maxShards, profiles.count))
        var samples: [ShardCountSample] = []
        var seen: Set<Int> = []
        for count in 1...ceiling {
            let candidate = plan(profiles, shardCount: count, pinnedTogether: pinnedTogether)
            guard seen.insert(candidate.shardCount).inserted else { continue }
            samples.append(
                ShardCountSample(
                    shardCount: candidate.shardCount,
                    makespan: candidate.makespan,
                    totalRunnerTime: candidate.totalRunnerTime
                )
            )
        }
        return samples
    }

    /// The shard count with the lowest makespan, preferring fewer shards on a
    /// tie — two plans that finish at the same moment are not equal, and the
    /// one holding fewer runners is cheaper and leaves capacity for the next
    /// job in the queue.
    public func optimalShardCount(
        for profiles: [TestTargetProfile],
        maxShards: Int,
        pinnedTogether: Set<TargetID> = []
    ) -> Int {
        let curve = makespanCurve(for: profiles, maxShards: maxShards, pinnedTogether: pinnedTogether)
        guard var best = curve.first else { return 1 }
        for sample in curve.dropFirst() where sample.makespan < best.makespan {
            best = sample
        }
        return max(1, best.shardCount)
    }

    /// Makespan of the strawman every team reaches for first: one shard per
    /// bundle, each paying its own boot, queued against a finite pool.
    ///
    /// `pinnedTogether` is **not** optional in spirit even though it has a
    /// default: a baseline computed without the pinning constraint that the
    /// real plan has to honour is not a baseline, it is a different problem.
    /// Reported side by side, it makes the chosen plan look worse than a
    /// strawman it is in fact beating.
    public func maximallyParallelMakespan(
        for profiles: [TestTargetProfile],
        pinnedTogether: Set<TargetID> = []
    ) -> Milliseconds {
        guard !profiles.isEmpty else { return 0 }
        return plan(profiles, shardCount: profiles.count, pinnedTogether: pinnedTogether).makespan
    }

    /// Makespan with no sharding at all.
    public func serialMakespan(
        for profiles: [TestTargetProfile],
        pinnedTogether: Set<TargetID> = []
    ) -> Milliseconds {
        guard !profiles.isEmpty else { return 0 }
        return plan(profiles, shardCount: 1, pinnedTogether: pinnedTogether).makespan
    }
}

/// A deliberately naive packer, kept in the shipped library rather than in the
/// tests.
///
/// It exists so the repository can falsify its own claim. The README says LPT
/// beats balancing by count; ``NaiveRoundRobinPlanner`` *is* balancing by
/// count, so the suite runs both over identical profiles and asserts LPT's
/// makespan is genuinely lower. A test that compared LPT only against itself
/// would pass against a gutted implementation, which is the same as no test.
public struct NaiveRoundRobinPlanner: Sendable {

    public let fixedCostPerShard: Milliseconds
    public let concurrencyLimit: Int

    public init(fixedCostPerShard: Milliseconds, concurrencyLimit: Int) {
        self.fixedCostPerShard = max(0, fixedCostPerShard)
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    /// Deals bundles out in name order, one per shard, round and round.
    public func plan(_ profiles: [TestTargetProfile], shardCount: Int) -> ShardPlan {
        guard !profiles.isEmpty else {
            return ShardPlan(
                shards: [],
                fixedCostPerShard: fixedCostPerShard,
                concurrencyLimit: concurrencyLimit
            )
        }
        let sorted = profiles.sorted { $0.id < $1.id }
        let effective = min(max(1, shardCount), sorted.count)
        var work = [Milliseconds](repeating: 0, count: effective)
        var buckets = [[TargetID]](repeating: [], count: effective)
        for (offset, profile) in sorted.enumerated() {
            let index = SaturatingMath.remainder(offset, effective)
            work[index] = SaturatingMath.add(work[index], profile.historicalDuration)
            buckets[index].append(profile.id)
        }
        var shards: [Shard] = []
        for index in 0..<effective where !buckets[index].isEmpty {
            shards.append(Shard(index: shards.count, targets: buckets[index], work: work[index]))
        }
        return ShardPlan(
            shards: shards,
            fixedCostPerShard: fixedCostPerShard,
            concurrencyLimit: concurrencyLimit
        )
    }
}
