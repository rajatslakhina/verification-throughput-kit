import Foundation

public struct VerificationPolicy: Sendable {
    /// Ceiling on how many shards the planner may propose.
    public let maximumShards: Int
    /// How many shards can genuinely run at once — the simulator pool size, or
    /// the macOS runner concurrency this repository is allowed. Shards beyond
    /// this queue into a second wave and pay the boot tax again, which is what
    /// puts a floor under the makespan curve.
    public let concurrencyLimit: Int
    /// Simulator boot + code signing + toolchain warm-up, paid once per shard
    /// on a cold device. The number that makes iOS sharding a different problem
    /// from web sharding.
    public let fixedCostPerShard: Milliseconds
    /// How many bundles a `.smoke` run is allowed to include.
    public let smokeTargetLimit: Int
    public let contract: AgentTestContract
    public let runnerClass: RunnerClass
    public let costModel: RunnerCostModel

    public init(
        maximumShards: Int,
        concurrencyLimit: Int,
        fixedCostPerShard: Milliseconds,
        smokeTargetLimit: Int = 1,
        contract: AgentTestContract,
        runnerClass: RunnerClass = .macOS,
        costModel: RunnerCostModel = .illustrative
    ) {
        self.maximumShards = max(1, maximumShards)
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.fixedCostPerShard = max(0, fixedCostPerShard)
        self.smokeTargetLimit = max(1, smokeTargetLimit)
        self.contract = contract
        self.runnerClass = runnerClass
        self.costModel = costModel
    }
}

public struct VerificationPlan: Sendable {
    public let tier: VerificationTier
    public let impact: ChangeImpact
    public let contractReport: ContractReport
    public let shardPlan: ShardPlan
    /// The bundles this tier actually runs.
    public let selectedProfiles: [TestTargetProfile]
    /// Makespan at every shard count from 1 to the ceiling — the curve the
    /// shard count was chosen from.
    public let shardCountCurve: [ShardCountSample]
    public let projectedCost: MicroUSD

    /// Everything, one shard, one boot. The "before" in most CI stories.
    public let fullSuiteSerialMakespan: Milliseconds
    /// Only what this tier selected, one shard.
    public let selectedSerialMakespan: Milliseconds
    /// One shard per selected bundle — maximum width, maximum boot tax.
    public let maximallyParallelMakespan: Milliseconds

    public var makespan: Milliseconds { shardPlan.makespan }
    public var totalRunnerTime: Milliseconds { shardPlan.totalRunnerTime }
    public var shardCount: Int { shardPlan.shardCount }

    /// Wall-clock saved against running the whole suite serially.
    public var savedVersusFullSuite: Milliseconds {
        max(0, SaturatingMath.subtract(fullSuiteSerialMakespan, makespan))
    }

    /// Wall-clock the naive "shard everything" plan would have *lost* against
    /// this one. Negative would mean going maximally wide was in fact better.
    public var savedVersusMaximumWidth: Milliseconds {
        SaturatingMath.subtract(maximallyParallelMakespan, makespan)
    }

    public var pinnedTargets: Set<TargetID> { contractReport.shardUnsafeTargets }
}

/// Turns a change set into a runnable, costed, contract-checked verification
/// plan.
///
/// The pipeline, in order:
///
/// 1. **Select** — which bundles can this change actually break?
///    (``ChangeImpactAnalyzer``, fail-safe on unowned paths.)
/// 2. **Check** — are those bundles even shardable?
///    (``AgentTestContract``; unsafe ones get pinned together, not dropped.)
/// 3. **Pack** — how many shards, and which bundles in each?
///    (``ShardPlanner``, fixed-cost-aware, LPT.)
/// 4. **Price** — what does that cost? (``RunnerCostModel``.)
///
/// Admission — *may this run at all right now* — is deliberately **not** here.
/// It is ``AdmissionController``, and it is an actor, because it is the only
/// part with cross-job state. Planning is pure, synchronous and `Sendable`, so
/// it can run inside a view body, inside a test, or inside a dry-run CLI
/// without a scheduler anywhere near it.
public struct VerificationPlanner: Sendable {

    public let policy: VerificationPolicy

    public init(policy: VerificationPolicy) {
        self.policy = policy
    }

    public func plan(
        changedPaths: [String],
        graph: BuildGraph,
        profiles: [TestTargetProfile],
        tests: [TestCaseDescriptor],
        tier: VerificationTier,
        shardCountOverride: Int? = nil
    ) -> VerificationPlan {
        let analyzer = ChangeImpactAnalyzer()
        let impact = analyzer.impact(of: changedPaths, in: graph)
        let contractReport = policy.contract.audit(tests)

        let profilesByID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.historicalDuration >= rhs.historicalDuration ? lhs : rhs
        })

        let selected = select(tier: tier, impact: impact, profilesByID: profilesByID)
        let planner = ShardPlanner(
            fixedCostPerShard: policy.fixedCostPerShard,
            concurrencyLimit: policy.concurrencyLimit
        )
        let pinned = contractReport.shardUnsafeTargets

        let curve = planner.makespanCurve(
            for: selected,
            maxShards: policy.maximumShards,
            pinnedTogether: pinned
        )

        let shardCount = shardCountOverride.map { max(1, $0) }
            ?? planner.optimalShardCount(
                for: selected,
                maxShards: policy.maximumShards,
                pinnedTogether: pinned
            )

        let shardPlan = planner.plan(selected, shardCount: shardCount, pinnedTogether: pinned)
        let allProfiles = profilesByID.values.sorted { $0.id < $1.id }

        return VerificationPlan(
            tier: tier,
            impact: impact,
            contractReport: contractReport,
            shardPlan: shardPlan,
            selectedProfiles: selected,
            shardCountCurve: curve,
            projectedCost: policy.costModel.cost(of: shardPlan, on: policy.runnerClass),
            // Every baseline honours the same pinning constraint the real plan
            // does. Computing them unpinned would report a strawman as faster
            // than the plan that beat it.
            fullSuiteSerialMakespan: planner.serialMakespan(for: allProfiles, pinnedTogether: pinned),
            selectedSerialMakespan: planner.serialMakespan(for: selected, pinnedTogether: pinned),
            maximallyParallelMakespan: planner.maximallyParallelMakespan(
                for: selected,
                pinnedTogether: pinned
            )
        )
    }

    /// Runner-time each tier would consume — the input the admission
    /// controller budgets against. Computed by actually planning each tier, not
    /// by scaling a guess.
    public func tieredCost(
        changedPaths: [String],
        graph: BuildGraph,
        profiles: [TestTargetProfile],
        tests: [TestCaseDescriptor]
    ) -> TieredCost {
        func runnerTime(_ tier: VerificationTier) -> Milliseconds {
            plan(
                changedPaths: changedPaths,
                graph: graph,
                profiles: profiles,
                tests: tests,
                tier: tier
            ).totalRunnerTime
        }
        return TieredCost(
            smoke: runnerTime(.smoke),
            impacted: runnerTime(.impacted),
            full: runnerTime(.full)
        )
    }

    // MARK: - Tier selection

    private func select(
        tier: VerificationTier,
        impact: ChangeImpact,
        profilesByID: [TargetID: TestTargetProfile]
    ) -> [TestTargetProfile] {
        let everything = profilesByID.values.sorted { $0.id < $1.id }

        switch tier {
        case .full:
            return everything

        case .impacted:
            return impact.impactedTestTargets
                .compactMap { profilesByID[$0] }
                .sorted { $0.id < $1.id }

        case .smoke:
            // Cheapest impacted bundles first — a smoke tier exists to return
            // *some* signal inside a budget, so the selection criterion is
            // price, not importance. Falls back to the cheapest bundles overall
            // when nothing was impacted, so a smoke run is never empty and
            // never silently green.
            let pool = impact.impactedTestTargets.isEmpty
                ? everything
                : impact.impactedTestTargets.compactMap { profilesByID[$0] }
            return pool
                .sorted { lhs, rhs in
                    if lhs.historicalDuration != rhs.historicalDuration {
                        return lhs.historicalDuration < rhs.historicalDuration
                    }
                    return lhs.id < rhs.id
                }
                .prefix(policy.smokeTargetLimit)
                .sorted { $0.id < $1.id }
        }
    }
}
