import XCTest
@testable import VerificationThroughput

final class ShardPlannerTests: XCTestCase {

    private func profile(_ name: String, _ duration: Milliseconds, tests: Int = 10) -> TestTargetProfile {
        TestTargetProfile(id: TargetID(name), historicalDuration: duration, testCount: tests)
    }

    // MARK: - Degenerate inputs

    func testEmptyProfilesProduceAnEmptyPlan() {
        let planner = ShardPlanner(fixedCostPerShard: 180_000, concurrencyLimit: 4)
        let plan = planner.plan([], shardCount: 8)
        XCTAssertTrue(plan.shards.isEmpty)
        XCTAssertEqual(plan.makespan, 0)
        XCTAssertEqual(plan.totalRunnerTime, 0)
        XCTAssertEqual(plan.imbalance, 0)
        XCTAssertTrue(planner.makespanCurve(for: [], maxShards: 8).isEmpty)
        XCTAssertEqual(planner.optimalShardCount(for: [], maxShards: 8), 1)
    }

    func testNonPositiveShardCountClampsToOne() {
        let planner = ShardPlanner(fixedCostPerShard: 1_000, concurrencyLimit: 4)
        let profiles = [profile("A", 100), profile("B", 200)]
        for requested in [Int.min, -5, 0, 1] {
            let plan = planner.plan(profiles, shardCount: requested)
            XCTAssertEqual(plan.shardCount, 1, "shardCount \(requested)")
            XCTAssertEqual(plan.shards.first?.targets.count, 2)
        }
    }

    /// An empty shard still boots a device and still bills. Asking for more
    /// shards than there are bundles must not manufacture them.
    func testNeverEmitsEmptyShards() {
        let planner = ShardPlanner(fixedCostPerShard: 180_000, concurrencyLimit: 8)
        let profiles = [profile("A", 10_000), profile("B", 10_000), profile("C", 10_000)]
        let plan = planner.plan(profiles, shardCount: 32)

        XCTAssertEqual(plan.shardCount, 3)
        XCTAssertEqual(plan.bootCount, 3)
        XCTAssertEqual(plan.totalRunnerTime, 3 * 190_000)
        XCTAssertTrue(plan.shards.allSatisfy { !$0.targets.isEmpty })
    }

    func testEveryTargetIsAssignedExactlyOnce() {
        let planner = ShardPlanner(fixedCostPerShard: 60_000, concurrencyLimit: 4)
        let profiles = (1...9).map { profile("T\($0)", $0 * 11_000) }
        let plan = planner.plan(profiles, shardCount: 4)
        let assigned = plan.assignedTargets
        XCTAssertEqual(assigned.count, 9)
        XCTAssertEqual(Set(assigned), Set(profiles.map(\.id)))
    }

    func testDuplicateProfilesKeepTheLongerDuration() {
        let planner = ShardPlanner(fixedCostPerShard: 0, concurrencyLimit: 4)
        let plan = planner.plan(
            [profile("A", 1_000), profile("A", 9_000)],
            shardCount: 4
        )
        XCTAssertEqual(plan.shardCount, 1)
        XCTAssertEqual(plan.shards.first?.work, 9_000)
    }

    func testNegativeDurationsAreClampedAtConstruction() {
        XCTAssertEqual(profile("A", -5_000).historicalDuration, 0)
        XCTAssertEqual(TestTargetProfile(id: TargetID("A"), historicalDuration: 0, testCount: -3).testCount, 0)
    }

    func testPlanningIsDeterministic() {
        let planner = ShardPlanner(fixedCostPerShard: 30_000, concurrencyLimit: 3)
        // Same multiset, different input order, and several equal durations so
        // tie-breaking is actually exercised.
        let a = [profile("D", 50), profile("A", 50), profile("C", 50), profile("B", 90)]
        let b = [profile("B", 90), profile("C", 50), profile("A", 50), profile("D", 50)]
        XCTAssertEqual(planner.plan(a, shardCount: 2), planner.plan(b, shardCount: 2))
    }

    // MARK: - The claims the README makes

    /// LPT vs. balancing by count, over identical inputs. If `ShardPlanner`
    /// were gutted into round-robin, this fails.
    func testLPTBeatsRoundRobinOnMakespanAndBalance() {
        let fixed: Milliseconds = 180_000
        let profiles = [
            profile("A", 100_000),
            profile("B", 100_000),
            profile("C", 100_000),
            profile("D", 700_000)
        ]

        let lpt = ShardPlanner(fixedCostPerShard: fixed, concurrencyLimit: 2)
            .plan(profiles, shardCount: 2)
        let naive = NaiveRoundRobinPlanner(fixedCostPerShard: fixed, concurrencyLimit: 2)
            .plan(profiles, shardCount: 2)

        XCTAssertEqual(lpt.makespan, 880_000)
        XCTAssertEqual(naive.makespan, 980_000)
        XCTAssertLessThan(lpt.makespan, naive.makespan)
        XCTAssertLessThan(lpt.imbalance, naive.imbalance)
        // Both pay the same runner-time; the win is entirely in the packing.
        XCTAssertEqual(lpt.totalRunnerTime, naive.totalRunnerTime)
    }

    /// The load-bearing claim: past the runner pool's width, an extra shard
    /// makes the run **slower and more expensive at once**.
    ///
    /// Eight equal bundles, four concurrent runners. Four shards is the floor;
    /// eight shards needs two waves and each wave re-pays the boot tax.
    func testMakespanCurveHasAFloorAndRisesAfterIt() {
        let planner = ShardPlanner(fixedCostPerShard: 180_000, concurrencyLimit: 4)
        let profiles = (1...8).map { profile("T\($0)", 60_000) }
        let curve = planner.makespanCurve(for: profiles, maxShards: 8)

        XCTAssertEqual(curve.count, 8)
        XCTAssertEqual(curve.map(\.shardCount), Array(1...8))

        XCTAssertEqual(curve[0].makespan, 660_000)   // 1 shard:  180 + 480
        XCTAssertEqual(curve[3].makespan, 300_000)   // 4 shards: 180 + 120, one wave
        XCTAssertEqual(curve[7].makespan, 480_000)   // 8 shards: two waves of 240

        // Slower...
        XCTAssertGreaterThan(curve[7].makespan, curve[3].makespan)
        // ...and dearer.
        XCTAssertGreaterThan(curve[7].totalRunnerTime, curve[3].totalRunnerTime)
        XCTAssertEqual(curve[3].totalRunnerTime, 1_200_000)
        XCTAssertEqual(curve[7].totalRunnerTime, 1_920_000)

        XCTAssertEqual(planner.optimalShardCount(for: profiles, maxShards: 8), 4)
    }

    /// Runner-time is monotonically non-decreasing in shard count, always.
    /// Makespan is not — that asymmetry is the entire design problem.
    func testRunnerTimeNeverImprovesWithMoreShards() {
        let planner = ShardPlanner(fixedCostPerShard: 90_000, concurrencyLimit: 3)
        let profiles = (1...7).map { profile("T\($0)", $0 * 20_000) }
        let curve = planner.makespanCurve(for: profiles, maxShards: 7)
        for (earlier, later) in zip(curve, curve.dropFirst()) {
            XCTAssertLessThanOrEqual(
                earlier.totalRunnerTime,
                later.totalRunnerTime,
                "runner time fell going from \(earlier.shardCount) to \(later.shardCount) shards"
            )
        }
    }

    func testOptimalShardCountPrefersFewerShardsOnATie() {
        // Two bundles, a pool of two, and a boot cost that dwarfs the work:
        // 1 shard is 100 + 2 = 102; 2 shards is 100 + 1 = 101. Distinct.
        // Make them tie by giving the second bundle no work at all.
        let planner = ShardPlanner(fixedCostPerShard: 100_000, concurrencyLimit: 2)
        let profiles = [profile("A", 40_000), profile("B", 0)]
        let curve = planner.makespanCurve(for: profiles, maxShards: 2)
        XCTAssertEqual(curve[0].makespan, 140_000)
        XCTAssertEqual(curve[1].makespan, 140_000)
        // Tied makespan, so the cheaper plan wins.
        XCTAssertEqual(planner.optimalShardCount(for: profiles, maxShards: 2), 1)
    }

    func testSerialAndMaximallyParallelBaselines() {
        let planner = ShardPlanner(fixedCostPerShard: 180_000, concurrencyLimit: 4)
        let profiles = (1...8).map { profile("T\($0)", 60_000) }
        XCTAssertEqual(planner.serialMakespan(for: profiles), 660_000)
        XCTAssertEqual(planner.maximallyParallelMakespan(for: profiles), 480_000)
        XCTAssertEqual(planner.serialMakespan(for: []), 0)
        XCTAssertEqual(planner.maximallyParallelMakespan(for: []), 0)
    }

    // MARK: - Pinning

    func testPinnedTargetsShareAShard() {
        let planner = ShardPlanner(fixedCostPerShard: 10_000, concurrencyLimit: 4)
        let profiles = [
            profile("Flaky1", 20_000),
            profile("Flaky2", 20_000),
            profile("Clean1", 30_000),
            profile("Clean2", 30_000)
        ]
        let plan = planner.plan(
            profiles,
            shardCount: 4,
            pinnedTogether: [TargetID("Flaky1"), TargetID("Flaky2")]
        )

        let host = plan.shards.first { $0.targets.contains(TargetID("Flaky1")) }
        XCTAssertNotNil(host)
        XCTAssertTrue(host?.targets.contains(TargetID("Flaky2")) ?? false)
        XCTAssertEqual(plan.assignedTargets.count, 4)
    }

    func testPinningOneTargetChangesNothing() {
        let planner = ShardPlanner(fixedCostPerShard: 10_000, concurrencyLimit: 4)
        let profiles = [profile("A", 10_000), profile("B", 20_000), profile("C", 30_000)]
        XCTAssertEqual(
            planner.plan(profiles, shardCount: 3, pinnedTogether: [TargetID("B")]),
            planner.plan(profiles, shardCount: 3)
        )
    }

    func testPinningUnknownTargetsIsHarmless() {
        let planner = ShardPlanner(fixedCostPerShard: 10_000, concurrencyLimit: 4)
        let profiles = [profile("A", 10_000), profile("B", 20_000)]
        let plan = planner.plan(
            profiles,
            shardCount: 2,
            pinnedTogether: [TargetID("Ghost1"), TargetID("Ghost2")]
        )
        XCTAssertEqual(Set(plan.assignedTargets), [TargetID("A"), TargetID("B")])
    }

    // MARK: - Arithmetic safety at the boundary

    func testAbsurdDurationsClampInsteadOfTrapping() {
        let planner = ShardPlanner(fixedCostPerShard: .max, concurrencyLimit: 2)
        let profiles = [
            profile("A", .max),
            profile("B", .max)
        ]
        let plan = planner.plan(profiles, shardCount: 2)
        XCTAssertEqual(plan.makespan, .max)
        XCTAssertEqual(plan.totalRunnerTime, .max)
        XCTAssertEqual(plan.imbalance, 0)
    }
}
