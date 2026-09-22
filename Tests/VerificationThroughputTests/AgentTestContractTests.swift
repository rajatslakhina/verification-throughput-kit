import XCTest
@testable import VerificationThroughput

final class AgentTestContractTests: XCTestCase {

    private let bundle = TargetID("CheckoutTests")

    private func clean(_ name: String, authorship: Authorship = .human) -> TestCaseDescriptor {
        TestCaseDescriptor(
            identifier: name,
            targetID: bundle,
            declaredTimeout: 5_000,
            authorship: authorship
        )
    }

    private var contract: AgentTestContract {
        AgentTestContract(maximumTestRuntime: 30_000)
    }

    func testAWellDeclaredSuiteIsShardSafe() {
        let report = contract.audit([
            clean("testAddsItem"),
            clean("testRemovesItem", authorship: .agent(model: "some-model"))
        ])
        XCTAssertTrue(report.violations.isEmpty)
        XCTAssertTrue(report.isShardSafe)
        XCTAssertTrue(report.shardUnsafeTargets.isEmpty)
    }

    /// The core mutation check: hand the contract a deliberately broken test
    /// and assert it **fails**. A gate that returns "shard-safe" for this input
    /// is worse than no gate, because the sharding downstream would be invalid
    /// and nothing would say so.
    func testDeliberatelyUnsafeAgentTestIsBlocked() {
        let report = contract.audit([
            TestCaseDescriptor(
                identifier: "testWritesGlobalCache",
                targetID: bundle,
                declaredTimeout: 5_000,
                touchesSharedMutableState: true,
                authorship: .agent(model: "some-model")
            )
        ])

        XCTAssertFalse(report.isShardSafe)
        XCTAssertEqual(report.blockingViolations.count, 1)
        XCTAssertEqual(report.blockingViolations.first?.hazard, .sharedMutableState)
        XCTAssertEqual(report.shardUnsafeTargets, [bundle])
    }

    /// The authorship rule, stated as an executable difference. The two
    /// descriptors are identical apart from who wrote them.
    func testAuthorshipDecidesSeverityForSoftHazards() {
        let human = TestCaseDescriptor(
            identifier: "testHitsStaging",
            targetID: bundle,
            declaredTimeout: 5_000,
            usesRealNetwork: true,
            authorship: .human
        )
        let agent = TestCaseDescriptor(
            identifier: "testHitsStaging",
            targetID: bundle,
            declaredTimeout: 5_000,
            usesRealNetwork: true,
            authorship: .agent(model: "some-model")
        )

        let humanReport = contract.audit([human])
        XCTAssertEqual(humanReport.violations.map(\.severity), [.advisory])
        XCTAssertTrue(humanReport.isShardSafe)

        let agentReport = contract.audit([agent])
        XCTAssertEqual(agentReport.violations.map(\.severity), [.blocking])
        XCTAssertFalse(agentReport.isShardSafe)
    }

    func testStrictModeIgnoresAuthorship() {
        let strict = AgentTestContract(maximumTestRuntime: 30_000, strictMode: true)
        let report = strict.audit([
            TestCaseDescriptor(
                identifier: "testHitsStaging",
                targetID: bundle,
                declaredTimeout: 5_000,
                usesRealNetwork: true,
                authorship: .human
            )
        ])
        XCTAssertEqual(report.violations.map(\.severity), [.blocking])
    }

    /// Two hazards are blocking regardless of who wrote the test, because
    /// neither is a matter of judgement.
    func testOrderDependenceAndDuplicatesBlockForEveryAuthor() {
        let ordered = contract.audit([
            TestCaseDescriptor(
                identifier: "testSecond",
                targetID: bundle,
                declaredTimeout: 1_000,
                mustRunAfter: "testFirst",
                authorship: .human
            )
        ])
        XCTAssertEqual(ordered.blockingViolations.count, 1)
        XCTAssertEqual(ordered.blockingViolations.first?.hazard, .orderDependence(on: "testFirst"))

        let duplicated = contract.audit([clean("testSame"), clean("testSame")])
        XCTAssertEqual(
            duplicated.blockingViolations.map(\.hazard),
            [.duplicateIdentifier]
        )
    }

    func testUndeclaredAndOverlongTimeoutsAreHazards() {
        let undeclared = TestCaseDescriptor(
            identifier: "testNoCeiling",
            targetID: bundle,
            declaredTimeout: nil,
            authorship: .agent(model: "some-model")
        )
        let overlong = TestCaseDescriptor(
            identifier: "testForever",
            targetID: bundle,
            declaredTimeout: 45_000,
            authorship: .agent(model: "some-model")
        )

        let report = contract.audit([undeclared, overlong])
        XCTAssertEqual(report.blockingViolations.count, 2)
        XCTAssertTrue(report.violations.contains { $0.hazard == .undeclaredTimeout })
        XCTAssertTrue(
            report.violations.contains {
                $0.hazard == .runtimeExceedsCeiling(declared: 45_000, ceiling: 30_000)
            }
        )
        // Exactly at the ceiling is fine.
        let atCeiling = contract.audit([
            TestCaseDescriptor(
                identifier: "testAtLimit",
                targetID: bundle,
                declaredTimeout: 30_000,
                authorship: .agent(model: "some-model")
            )
        ])
        XCTAssertTrue(atCeiling.isShardSafe)
    }

    /// Pinning fixes co-location hazards, not correctness ones. A duplicate
    /// identifier is still blocking but must not be reported as something a
    /// shard assignment can solve — otherwise the planner "fixes" it by
    /// grouping and the build goes green on a real bug.
    func testOnlyCoLocationHazardsProducePinnedTargets() {
        let report = contract.audit([clean("testSame"), clean("testSame")])
        XCTAssertFalse(report.isShardSafe)
        XCTAssertTrue(report.shardUnsafeTargets.isEmpty)

        XCTAssertTrue(IsolationHazard.sharedMutableState.isFixedByPinning)
        XCTAssertTrue(IsolationHazard.orderDependence(on: "x").isFixedByPinning)
        XCTAssertFalse(IsolationHazard.duplicateIdentifier.isFixedByPinning)
        XCTAssertFalse(IsolationHazard.realNetworkAccess.isFixedByPinning)
        XCTAssertFalse(IsolationHazard.undeclaredTimeout.isFixedByPinning)
    }

    func testEmptySuiteIsVacuouslySafe() {
        let report = contract.audit([])
        XCTAssertTrue(report.violations.isEmpty)
        XCTAssertTrue(report.isShardSafe)
    }

    func testReportOrderIsDeterministic() {
        let a = TargetID("ATests")
        let b = TargetID("BTests")
        let tests = [
            TestCaseDescriptor(identifier: "z", targetID: b, declaredTimeout: nil, authorship: .agent(model: "m")),
            TestCaseDescriptor(identifier: "a", targetID: b, declaredTimeout: nil, authorship: .agent(model: "m")),
            TestCaseDescriptor(identifier: "m", targetID: a, declaredTimeout: nil, authorship: .agent(model: "m"))
        ]
        let first = contract.audit(tests).violations
        let second = contract.audit(tests.reversed()).violations
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.testIdentifier), ["m", "a", "z"])
    }

    func testNegativeTimeoutsAreClampedAtConstruction() {
        let descriptor = TestCaseDescriptor(
            identifier: "t",
            targetID: bundle,
            declaredTimeout: -1
        )
        XCTAssertEqual(descriptor.declaredTimeout, 0)
        XCTAssertEqual(AgentTestContract(maximumTestRuntime: -5).maximumTestRuntime, 0)
    }
}
