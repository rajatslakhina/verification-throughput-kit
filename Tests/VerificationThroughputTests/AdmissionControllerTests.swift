import XCTest
@testable import VerificationThroughput

final class AdmissionControllerTests: XCTestCase {

    private func policy(
        budget: Milliseconds = 100_000,
        window: Milliseconds = 3_600_000,
        bucket: Milliseconds = 60_000,
        reserveBasisPoints: Int = 2_000,
        aging: Int? = 2,
        trackedJobs: Int = 4_096
    ) -> AdmissionPolicy {
        AdmissionPolicy(
            budgetPerWindow: budget,
            windowLength: window,
            bucketSize: bucket,
            mergeQueueReserveBasisPoints: reserveBasisPoints,
            agingThreshold: aging,
            retryBackoff: 30_000,
            maximumTrackedJobs: trackedJobs,
            minimumTier: .smoke
        )
    }

    private func cost(_ smoke: Milliseconds, _ impacted: Milliseconds, _ full: Milliseconds) -> TieredCost {
        TieredCost(smoke: smoke, impacted: impacted, full: full)
    }

    // MARK: - Allowance arithmetic

    func testMergeQueueReserveIsWithheldFromEveryoneElse() {
        let subject = policy(budget: 100_000, reserveBasisPoints: 2_000)
        XCTAssertEqual(subject.allowance(for: .mergeQueue), 100_000)
        XCTAssertEqual(subject.allowance(for: .pullRequest), 80_000)
        XCTAssertEqual(subject.allowance(for: .speculative), 80_000)
    }

    func testReserveIsClampedToASaneRange() {
        XCTAssertEqual(
            AdmissionPolicy(budgetPerWindow: 100, windowLength: 1, mergeQueueReserveBasisPoints: -500)
                .mergeQueueReserveBasisPoints,
            0
        )
        XCTAssertEqual(
            AdmissionPolicy(budgetPerWindow: 100, windowLength: 1, mergeQueueReserveBasisPoints: 99_999)
                .mergeQueueReserveBasisPoints,
            10_000
        )
        // A 100% reserve leaves nothing for anyone below merge-queue class.
        let total = AdmissionPolicy(
            budgetPerWindow: 100,
            windowLength: 1,
            mergeQueueReserveBasisPoints: 10_000
        )
        XCTAssertEqual(total.allowance(for: .pullRequest), 0)
        XCTAssertEqual(total.allowance(for: .mergeQueue), 100)
    }

    func testAbsurdBudgetDoesNotTrapTheAllowanceMath() {
        let subject = AdmissionPolicy(
            budgetPerWindow: .max,
            windowLength: 1,
            mergeQueueReserveBasisPoints: 5_000
        )
        // `budget * 10_000` overflows; it must clamp rather than abort.
        XCTAssertGreaterThanOrEqual(subject.allowance(for: .pullRequest), 0)
        XCTAssertEqual(subject.allowance(for: .mergeQueue), .max)
    }

    // MARK: - Degrade before deferring

    func testFullIsAdmittedWhenTheBudgetIsClear() async {
        let controller = AdmissionController(policy: policy())
        let outcome = await controller.admit(
            AdmissionRequest(
                id: "a",
                jobClass: .pullRequest,
                desiredTier: .full,
                cost: cost(10_000, 30_000, 70_000)
            ),
            now: 0
        )
        XCTAssertEqual(outcome, .admitted(tier: .full, reserved: 70_000, effectiveClass: .pullRequest))
        let used = await controller.utilisation(now: 0)
        XCTAssertEqual(used, 70_000)
    }

    func testPressureDegradesRatherThanRejects() async {
        let controller = AdmissionController(policy: policy())
        // Soak up 60s of the 80s a pull-request job may draw on.
        _ = await controller.admit(
            AdmissionRequest(id: "soak", jobClass: .pullRequest, desiredTier: .full, cost: cost(60_000, 60_000, 60_000)),
            now: 0
        )

        let outcome = await controller.admit(
            AdmissionRequest(id: "b", jobClass: .pullRequest, desiredTier: .full, cost: cost(10_000, 18_000, 70_000)),
            now: 0
        )
        XCTAssertEqual(
            outcome,
            .degraded(tier: .impacted, from: .full, reserved: 18_000, reason: .budgetPressure)
        )
    }

    func testDeferralOnlyHappensWhenEvenSmokeDoesNotFit() async {
        let controller = AdmissionController(policy: policy())
        _ = await controller.admit(
            AdmissionRequest(id: "soak", jobClass: .pullRequest, desiredTier: .full, cost: cost(80_000, 80_000, 80_000)),
            now: 0
        )

        let outcome = await controller.admit(
            AdmissionRequest(id: "c", jobClass: .speculative, desiredTier: .full, cost: cost(5_000, 20_000, 50_000)),
            now: 0
        )
        guard case .deferred(let retryAfter, let attempt) = outcome else {
            return XCTFail("expected a deferral, got \(outcome)")
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(retryAfter, 30_000)
    }

    func testAdmissionClearsAJobsDeferralHistory() async {
        let controller = AdmissionController(policy: policy())
        _ = await controller.admit(
            AdmissionRequest(id: "soak", jobClass: .pullRequest, desiredTier: .full, cost: cost(80_000, 80_000, 80_000)),
            now: 0
        )
        let request = AdmissionRequest(
            id: "d",
            jobClass: .speculative,
            desiredTier: .full,
            cost: cost(5_000, 20_000, 50_000)
        )
        _ = await controller.admit(request, now: 0)
        let deferred = await controller.deferralCount(for: "d")
        XCTAssertEqual(deferred, 1)

        // A fresh window: the soak has aged out, so the job gets in and its
        // aging credit is reset.
        _ = await controller.admit(request, now: 4_000_000)
        let cleared = await controller.deferralCount(for: "d")
        XCTAssertEqual(cleared, 0)
    }

    // MARK: - The bounded-memory claims

    func testLedgerSizeIsBoundedByTheWindow() async {
        // 10-minute window, 1-minute buckets → at most 11 live entries.
        let controller = AdmissionController(
            policy: policy(budget: .max, window: 600_000, bucket: 60_000)
        )
        for index in 0..<2_000 {
            _ = await controller.admit(
                AdmissionRequest(
                    id: "job-\(index)",
                    jobClass: .mergeQueue,
                    desiredTier: .smoke,
                    cost: cost(1, 1, 1)
                ),
                now: index * 1_000
            )
        }
        let entries = await controller.ledgerEntryCount()
        XCTAssertLessThanOrEqual(entries, 11)
        XCTAssertGreaterThan(entries, 0)
    }

    func testDeferralTrackingIsBounded() async {
        let controller = AdmissionController(policy: policy(budget: 0, trackedJobs: 4))
        for index in 0..<10 {
            _ = await controller.admit(
                AdmissionRequest(
                    id: "job-\(index)",
                    jobClass: .speculative,
                    desiredTier: .smoke,
                    cost: cost(1, 1, 1)
                ),
                now: 0
            )
        }
        // The four most recent are retained; everything older was evicted.
        for index in 0..<6 {
            let count = await controller.deferralCount(for: "job-\(index)")
            XCTAssertEqual(count, 0, "job-\(index) should have been evicted")
        }
        for index in 6..<10 {
            let count = await controller.deferralCount(for: "job-\(index)")
            XCTAssertEqual(count, 1, "job-\(index) should still be tracked")
        }
    }

    // MARK: - Starvation

    /// The mutation test for the whole aging design.
    ///
    /// The same auditor, the same load, the same victim — the only difference
    /// is `agingThreshold`. If the auditor reported "starvation-free" for both,
    /// it would be measuring nothing, and the README's guarantee would be
    /// decoration. It must **fail** the aging-disabled policy.
    func testStarvationAuditorDistinguishesAgingFromNoAging() async {
        let auditor = StarvationAuditor(horizon: 64)
        let victim = cost(15_000, 40_000, 90_000)
        let load: Milliseconds = 80_000

        let withAging = await auditor.audit(
            policy: policy(aging: 2),
            victimCost: victim,
            loadCost: load
        )
        XCTAssertTrue(withAging.isStarvationFree)
        // Two promotions at a threshold of two: speculative → pull-request →
        // merge-queue, at which point the reserve is reachable.
        XCTAssertEqual(withAging.admittedAfterDeferrals, 4)

        let withoutAging = await auditor.audit(
            policy: policy(aging: nil),
            victimCost: victim,
            loadCost: load
        )
        XCTAssertFalse(
            withoutAging.isStarvationFree,
            "the auditor failed to detect starvation in a policy that plainly starves"
        )
        XCTAssertNil(withoutAging.admittedAfterDeferrals)
        XCTAssertEqual(withoutAging.horizon, 64)
    }

    /// Aging is capped at merge-queue class; it never invents a priority above
    /// the top of the ladder, and it never lets a job in that genuinely cannot
    /// fit. A victim whose smoke tier is larger than the entire budget is
    /// correctly reported as starving even with aging on — the auditor is not
    /// just checking a flag.
    func testAgingCannotAdmitAJobThatDoesNotFitAtAll() async {
        let auditor = StarvationAuditor(horizon: 16)
        let report = await auditor.audit(
            policy: policy(aging: 1),
            victimCost: cost(500_000, 500_000, 500_000),
            loadCost: 80_000
        )
        XCTAssertFalse(report.isStarvationFree)
    }

    func testMergeQueueJobsReachTheReserveImmediately() async {
        let controller = AdmissionController(policy: policy())
        _ = await controller.admit(
            AdmissionRequest(id: "soak", jobClass: .pullRequest, desiredTier: .full, cost: cost(80_000, 80_000, 80_000)),
            now: 0
        )
        let outcome = await controller.admit(
            AdmissionRequest(id: "land", jobClass: .mergeQueue, desiredTier: .smoke, cost: cost(15_000, 40_000, 90_000)),
            now: 0
        )
        XCTAssertEqual(outcome, .admitted(tier: .smoke, reserved: 15_000, effectiveClass: .mergeQueue))
    }

    // MARK: - A tier that runs nothing is not a degradation target

    /// The subtle one. `impacted` costs nothing because the change set reached
    /// no bundle — so "degrading" `full` → `impacted` would admit a job that
    /// runs *nothing* and reports green, under budget pressure that should
    /// have made it wait. Zero-priced lower tiers are skipped, and the job
    /// waits for the verification it actually asked for.
    ///
    /// Drop the `price > 0` condition in `admit` and this fails.
    func testAZeroCostLowerTierIsNeverADegradationTarget() async {
        let controller = AdmissionController(policy: policy())
        _ = await controller.admit(
            AdmissionRequest(id: "soak", jobClass: .pullRequest, desiredTier: .full, cost: cost(80_000, 80_000, 80_000)),
            now: 0
        )

        let outcome = await controller.admit(
            AdmissionRequest(
                id: "inert-but-full",
                jobClass: .pullRequest,
                desiredTier: .full,
                // Nothing was impacted, so impacted and smoke both price at 0.
                cost: cost(0, 0, 90_000)
            ),
            now: 0
        )

        guard case .deferred = outcome else {
            return XCTFail("a job must never be 'admitted' into a tier that runs nothing — got \(outcome)")
        }
    }

    /// The other half: when the tier the caller actually asked for costs
    /// nothing, there is genuinely nothing to verify and admitting a no-op is
    /// correct. It must not consume budget and must not be deferred forever.
    func testAZeroCostDesiredTierIsAdmittedAsANoOp() async {
        let controller = AdmissionController(policy: policy())
        let outcome = await controller.admit(
            AdmissionRequest(
                id: "docs-only",
                jobClass: .pullRequest,
                desiredTier: .impacted,
                cost: cost(0, 0, 120_000)
            ),
            now: 0
        )
        XCTAssertEqual(outcome, .admitted(tier: .impacted, reserved: 0, effectiveClass: .pullRequest))

        let used = await controller.utilisation(now: 0)
        XCTAssertEqual(used, 0, "a no-op must not consume budget")
    }

    func testBackoffGrowsWithAttemptsButIsCapped() async {
        let controller = AdmissionController(policy: policy(budget: 0))
        let request = AdmissionRequest(
            id: "e",
            jobClass: .speculative,
            desiredTier: .smoke,
            cost: cost(1, 1, 1)
        )
        var lastBackoff: Milliseconds = 0
        for _ in 0..<40 {
            let outcome = await controller.admit(request, now: 0)
            guard case .deferred(let retryAfter, _) = outcome else {
                return XCTFail("a zero budget must always defer")
            }
            lastBackoff = retryAfter
        }
        // 30s base, capped at a 16× multiplier.
        XCTAssertEqual(lastBackoff, 480_000)
    }
}
