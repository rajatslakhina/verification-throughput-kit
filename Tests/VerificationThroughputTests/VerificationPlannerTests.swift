import XCTest
@testable import VerificationThroughput

final class VerificationPlannerTests: XCTestCase {

    private let coreTests = TargetID("CoreTests")
    private let checkoutTests = TargetID("CheckoutTests")
    private let checkoutUITests = TargetID("CheckoutUITests")

    private func makeGraph() -> BuildGraph {
        BuildGraph(targets: [
            BuildTarget(id: TargetID("Core"), kind: .library, sourceRoots: ["Sources/Core"]),
            BuildTarget(
                id: TargetID("Checkout"), kind: .library,
                sourceRoots: ["Sources/Checkout"], dependencies: [TargetID("Core")]
            ),
            BuildTarget(
                id: TargetID("CheckoutUI"), kind: .library,
                sourceRoots: ["Sources/CheckoutUI"], dependencies: [TargetID("Checkout")]
            ),
            BuildTarget(
                id: coreTests, kind: .testBundle,
                sourceRoots: ["Tests/CoreTests"], dependencies: [TargetID("Core")]
            ),
            BuildTarget(
                id: checkoutTests, kind: .testBundle,
                sourceRoots: ["Tests/CheckoutTests"], dependencies: [TargetID("Checkout")]
            ),
            BuildTarget(
                id: checkoutUITests, kind: .testBundle,
                sourceRoots: ["Tests/CheckoutUITests"], dependencies: [TargetID("CheckoutUI")]
            )
        ])
    }

    private var profiles: [TestTargetProfile] {
        [
            TestTargetProfile(id: coreTests, historicalDuration: 120_000, testCount: 180),
            TestTargetProfile(id: checkoutTests, historicalDuration: 240_000, testCount: 320),
            TestTargetProfile(id: checkoutUITests, historicalDuration: 300_000, testCount: 95)
        ]
    }

    private func makePlanner(
        contract: AgentTestContract = AgentTestContract(maximumTestRuntime: 30_000)
    ) -> VerificationPlanner {
        VerificationPlanner(
            policy: VerificationPolicy(
                maximumShards: 4,
                concurrencyLimit: 2,
                fixedCostPerShard: 180_000,
                smokeTargetLimit: 1,
                contract: contract,
                runnerClass: .macOS,
                costModel: .illustrative
            )
        )
    }

    private func cleanTests() -> [TestCaseDescriptor] {
        [coreTests, checkoutTests, checkoutUITests].map { target in
            TestCaseDescriptor(
                identifier: "\(target.rawValue).testExample",
                targetID: target,
                declaredTimeout: 4_000,
                authorship: .agent(model: "some-model")
            )
        }
    }

    // MARK: - Tier selection

    func testFullTierRunsEverythingRegardlessOfTheChangeSet() {
        let plan = makePlanner().plan(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .full
        )
        XCTAssertEqual(Set(plan.selectedProfiles.map(\.id)), [coreTests, checkoutTests, checkoutUITests])
        XCTAssertEqual(plan.shardCount, 2)
        XCTAssertEqual(plan.makespan, 540_000)
        XCTAssertEqual(plan.totalRunnerTime, 1_020_000)
    }

    func testImpactedTierDropsUnreachableBundles() {
        let plan = makePlanner().plan(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .impacted
        )
        XCTAssertEqual(Set(plan.selectedProfiles.map(\.id)), [checkoutTests, checkoutUITests])
        XCTAssertFalse(plan.selectedProfiles.contains { $0.id == self.coreTests })
        XCTAssertEqual(plan.shardCount, 2)
        XCTAssertEqual(plan.makespan, 480_000)
        XCTAssertEqual(plan.totalRunnerTime, 900_000)
        XCTAssertLessThan(plan.makespan, plan.fullSuiteSerialMakespan)
    }

    func testSmokeTierTakesTheCheapestImpactedBundle() {
        let plan = makePlanner().plan(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .smoke
        )
        XCTAssertEqual(plan.selectedProfiles.map(\.id), [checkoutTests])
        XCTAssertEqual(plan.totalRunnerTime, 420_000)
    }

    /// A smoke run must never be silently empty. An empty run reports green,
    /// and a green that tested nothing is the worst output this system can
    /// produce.
    func testSmokeTierFallsBackWhenNothingWasImpacted() {
        let plan = makePlanner().plan(
            changedPaths: ["docs/adr/0004.md"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .smoke
        )
        XCTAssertTrue(plan.impact.impactedTestTargets.isEmpty)
        XCTAssertEqual(plan.selectedProfiles.map(\.id), [coreTests])
        XCTAssertFalse(plan.shardPlan.shards.isEmpty)
    }

    func testUnownedPathMakesImpactedEquivalentToFull() {
        let planner = makePlanner()
        let impacted = planner.plan(
            changedPaths: ["fastlane/Fastfile"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .impacted
        )
        let full = planner.plan(
            changedPaths: ["fastlane/Fastfile"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .full
        )
        XCTAssertTrue(impacted.impact.wasConservativelyWidened)
        XCTAssertEqual(
            Set(impacted.selectedProfiles.map(\.id)),
            Set(full.selectedProfiles.map(\.id))
        )
        XCTAssertEqual(impacted.totalRunnerTime, full.totalRunnerTime)
    }

    // MARK: - Contract feeds the packer

    func testShardUnsafeBundlesArePinnedOntoOneShard() {
        let unsafeTests = [
            TestCaseDescriptor(
                identifier: "CheckoutTests.testSharedFixture",
                targetID: checkoutTests,
                declaredTimeout: 4_000,
                touchesSharedMutableState: true,
                authorship: .agent(model: "some-model")
            ),
            TestCaseDescriptor(
                identifier: "CheckoutUITests.testSharedFixture",
                targetID: checkoutUITests,
                declaredTimeout: 4_000,
                touchesSharedMutableState: true,
                authorship: .agent(model: "some-model")
            )
        ]

        let plan = makePlanner().plan(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: unsafeTests,
            tier: .impacted
        )

        XCTAssertEqual(plan.pinnedTargets, [checkoutTests, checkoutUITests])
        XCTAssertEqual(plan.shardCount, 1, "pinned bundles cannot be split")
        XCTAssertEqual(plan.makespan, 720_000)
        // Serialising them is slower than the 480s the unpinned plan achieved —
        // the contract violation has a price, and the plan shows it.
        XCTAssertGreaterThan(plan.makespan, 480_000)
        XCTAssertFalse(plan.contractReport.isShardSafe)
    }

    // MARK: - Tiered cost

    func testTieredCostIsComputedByPlanningEachTier() {
        let cost = makePlanner().tieredCost(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests()
        )
        XCTAssertEqual(cost.smoke, 420_000)
        XCTAssertEqual(cost.impacted, 900_000)
        XCTAssertEqual(cost.full, 1_020_000)
        XCTAssertLessThan(cost.smoke, cost.impacted)
        XCTAssertLessThan(cost.impacted, cost.full)
    }

    /// End to end: plan, price the tiers, then ask the real controller.
    func testPlanFeedsTheAdmissionControllerUnderPressure() async {
        let planner = makePlanner()
        let cost = planner.tieredCost(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests()
        )

        let controller = AdmissionController(
            policy: AdmissionPolicy(
                budgetPerWindow: 1_500_000,
                windowLength: 3_600_000,
                mergeQueueReserveBasisPoints: 2_000
            )
        )
        // A merge-queue job takes most of the hour's budget.
        _ = await controller.admit(
            AdmissionRequest(
                id: "landing",
                jobClass: .mergeQueue,
                desiredTier: .full,
                cost: TieredCost(smoke: 900_000, impacted: 900_000, full: 900_000)
            ),
            now: 0
        )

        let outcome = await controller.admit(
            AdmissionRequest(id: "pr", jobClass: .pullRequest, desiredTier: .full, cost: cost),
            now: 0
        )
        // A pull-request job may draw on 1_200_000; 900_000 is gone, leaving
        // 300_000 — enough for smoke (420_000)? No. So it waits.
        XCTAssertFalse(outcome.isAdmittedOrDegraded)
    }

    // MARK: - Baselines and empty inputs

    func testBaselinesAreReported() {
        let plan = makePlanner().plan(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .impacted
        )
        // Whole suite, one shard: 180s boot + 660s of tests.
        XCTAssertEqual(plan.fullSuiteSerialMakespan, 840_000)
        // The two impacted bundles, one shard.
        XCTAssertEqual(plan.selectedSerialMakespan, 720_000)
        XCTAssertEqual(plan.savedVersusFullSuite, 360_000)
        XCTAssertEqual(plan.shardCountCurve.map(\.shardCount), [1, 2])
    }

    func testEmptyProfileTableProducesAnEmptyButValidPlan() {
        let plan = makePlanner().plan(
            changedPaths: ["Sources/Checkout/Cart.swift"],
            graph: makeGraph(),
            profiles: [],
            tests: [],
            tier: .full
        )
        XCTAssertTrue(plan.selectedProfiles.isEmpty)
        XCTAssertEqual(plan.makespan, 0)
        XCTAssertEqual(plan.projectedCost, 0)
        XCTAssertEqual(plan.savedVersusFullSuite, 0)
        XCTAssertTrue(plan.shardCountCurve.isEmpty)
    }

    func testShardCountOverrideIsHonouredAndClamped() {
        let planner = makePlanner()
        let forced = planner.plan(
            changedPaths: ["Sources/Core/Money.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .full,
            shardCountOverride: 3
        )
        XCTAssertEqual(forced.shardCount, 3)
        // The override is deliberately allowed to be worse than the optimum —
        // that is the point of being able to see the curve.
        XCTAssertGreaterThan(forced.makespan, 540_000)

        let clamped = planner.plan(
            changedPaths: ["Sources/Core/Money.swift"],
            graph: makeGraph(),
            profiles: profiles,
            tests: cleanTests(),
            tier: .full,
            shardCountOverride: -4
        )
        XCTAssertEqual(clamped.shardCount, 1)
    }
}

final class RunnerCostModelTests: XCTestCase {

    func testMinutesAlwaysRoundUp() {
        let model = RunnerCostModel.illustrative
        XCTAssertEqual(model.billedMinutes(for: 0), 0)
        XCTAssertEqual(model.billedMinutes(for: 1), 1)
        XCTAssertEqual(model.billedMinutes(for: 60_000), 1)
        XCTAssertEqual(model.billedMinutes(for: 60_001), 2)
        XCTAssertEqual(model.billedMinutes(for: 119_999), 2)
        XCTAssertEqual(model.billedMinutes(for: -5), 0)
    }

    /// Each shard is its own runner with its own partial final minute, so cost
    /// must be summed per shard. Rounding the total instead under-bills every
    /// multi-shard plan — here by a whole minute.
    func testPerShardRoundingIsNotTheSameAsRoundingTheTotal() {
        let model = RunnerCostModel.illustrative
        let plan = ShardPlan(
            shards: [
                Shard(index: 0, targets: [TargetID("A")], work: 61_000),
                Shard(index: 1, targets: [TargetID("B")], work: 61_000)
            ],
            fixedCostPerShard: 0,
            concurrencyLimit: 2
        )
        // Per shard: 2 minutes each → 4 minutes.
        XCTAssertEqual(model.cost(of: plan, on: .macOS), 4 * 62_000)
        // Rounding the 122s total would have billed 3 minutes.
        XCTAssertEqual(model.cost(runnerTime: plan.totalRunnerTime, on: .macOS), 3 * 62_000)
    }

    func testUnknownRunnerClassCostsNothingRatherThanCrashing() {
        let model = RunnerCostModel(rates: [.linux: RunnerRate(microUSDPerMinute: 9_600)])
        XCTAssertEqual(model.cost(runnerTime: 600_000, on: .macOS), 0)
        XCTAssertEqual(model.cost(runnerTime: 600_000, on: .linux), 10 * 9_600)
    }

    func testFormattingUsesIntegerArithmetic() {
        XCTAssertEqual(RunnerCostModel.formatted(0), "$0.00")
        XCTAssertEqual(RunnerCostModel.formatted(1_234_567), "$1.23")
        XCTAssertEqual(RunnerCostModel.formatted(90_000), "$0.09")
        XCTAssertEqual(RunnerCostModel.formatted(-1_234_567), "-$1.23")
        // `abs(Int.min)` traps; `magnitude` does not.
        XCTAssertTrue(RunnerCostModel.formatted(.min).hasPrefix("-$"))
    }

    func testCostArithmeticSaturatesOnAbsurdInput() {
        let model = RunnerCostModel(rates: [.macOS: RunnerRate(microUSDPerMinute: .max)])
        XCTAssertEqual(model.cost(runnerTime: .max, on: .macOS), .max)
        XCTAssertEqual(RunnerRate(microUSDPerMinute: -10).microUSDPerMinute, 0)
    }
}
