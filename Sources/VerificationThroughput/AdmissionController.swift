import Foundation

/// How much verification a job gets.
public enum VerificationTier: Int, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    /// A minimal signal: build plus the smallest meaningful bundle.
    case smoke = 0
    /// Only the bundles the change can reach.
    case impacted = 1
    /// Everything.
    case full = 2

    public var description: String {
        switch self {
        case .smoke: return "smoke"
        case .impacted: return "impacted"
        case .full: return "full"
        }
    }

    public static func < (lhs: VerificationTier, rhs: VerificationTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Why a job is asking for runners.
public enum JobClass: Int, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    /// An agent pushing an intermediate commit while it iterates. High volume,
    /// low value per run — and the reason the queue is saturated at all.
    case speculative = 0
    /// A human-or-agent PR awaiting review.
    case pullRequest = 1
    /// About to land on the trunk. Blocking everyone.
    case mergeQueue = 2

    public var description: String {
        switch self {
        case .speculative: return "speculative"
        case .pullRequest: return "pull-request"
        case .mergeQueue: return "merge-queue"
        }
    }

    public static func < (lhs: JobClass, rhs: JobClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Runner-time each tier of this job would consume.
public struct TieredCost: Sendable, Hashable {
    public let smoke: Milliseconds
    public let impacted: Milliseconds
    public let full: Milliseconds

    public init(smoke: Milliseconds, impacted: Milliseconds, full: Milliseconds) {
        self.smoke = max(0, smoke)
        self.impacted = max(0, impacted)
        self.full = max(0, full)
    }

    public func cost(for tier: VerificationTier) -> Milliseconds {
        switch tier {
        case .smoke: return smoke
        case .impacted: return impacted
        case .full: return full
        }
    }
}

public struct AdmissionRequest: Sendable, Hashable {
    public let id: String
    public let jobClass: JobClass
    public let desiredTier: VerificationTier
    public let cost: TieredCost

    public init(id: String, jobClass: JobClass, desiredTier: VerificationTier, cost: TieredCost) {
        self.id = id
        self.jobClass = jobClass
        self.desiredTier = desiredTier
        self.cost = cost
    }
}

public enum DegradeReason: Sendable, Hashable {
    case budgetPressure
}

public enum AdmissionOutcome: Sendable, Hashable {
    case admitted(tier: VerificationTier, reserved: Milliseconds, effectiveClass: JobClass)
    case degraded(tier: VerificationTier, from: VerificationTier, reserved: Milliseconds, reason: DegradeReason)
    case deferred(retryAfter: Milliseconds, attempt: Int)

    public var isAdmittedOrDegraded: Bool {
        switch self {
        case .admitted, .degraded: return true
        case .deferred: return false
        }
    }

    public var grantedTier: VerificationTier? {
        switch self {
        case .admitted(let tier, _, _): return tier
        case .degraded(let tier, _, _, _): return tier
        case .deferred: return nil
        }
    }
}

public struct AdmissionPolicy: Sendable, Hashable {
    /// Runner-time available per rolling window.
    public let budgetPerWindow: Milliseconds
    public let windowLength: Milliseconds
    /// Granularity of the rolling-window ledger. Reservations are bucketed by
    /// this, which is what keeps ledger memory bounded by
    /// `windowLength / bucketSize` entries regardless of request volume.
    public let bucketSize: Milliseconds
    /// Share of the budget held back for merge-queue traffic, in basis points
    /// (10_000 = 100%). Everything below merge-queue class draws only on the
    /// remainder, so a flood of speculative agent runs cannot block a landing.
    public let mergeQueueReserveBasisPoints: Int
    /// Consecutive deferrals after which a job's effective class is promoted
    /// one step. `nil` disables aging — the misconfiguration
    /// ``StarvationAuditor`` exists to catch.
    public let agingThreshold: Int?
    public let retryBackoff: Milliseconds
    /// Distinct job ids whose deferral history is retained.
    public let maximumTrackedJobs: Int
    /// The floor a job may be degraded to before it is deferred instead.
    public let minimumTier: VerificationTier

    public init(
        budgetPerWindow: Milliseconds,
        windowLength: Milliseconds,
        bucketSize: Milliseconds = 60_000,
        mergeQueueReserveBasisPoints: Int = 2_000,
        agingThreshold: Int? = 2,
        retryBackoff: Milliseconds = 30_000,
        maximumTrackedJobs: Int = 4_096,
        minimumTier: VerificationTier = .smoke
    ) {
        self.budgetPerWindow = max(0, budgetPerWindow)
        self.windowLength = max(1, windowLength)
        self.bucketSize = max(1, bucketSize)
        self.mergeQueueReserveBasisPoints = min(10_000, max(0, mergeQueueReserveBasisPoints))
        self.agingThreshold = agingThreshold.map { max(1, $0) }
        self.retryBackoff = max(0, retryBackoff)
        self.maximumTrackedJobs = max(1, maximumTrackedJobs)
        self.minimumTier = minimumTier
    }

    /// Runner-time a job of `jobClass` is allowed to draw on.
    public func allowance(for jobClass: JobClass) -> Milliseconds {
        guard jobClass < .mergeQueue else { return budgetPerWindow }
        let reserved = SaturatingMath.divide(
            SaturatingMath.multiply(budgetPerWindow, mergeQueueReserveBasisPoints),
            by: 10_000
        )
        return max(0, SaturatingMath.subtract(budgetPerWindow, reserved))
    }
}

/// Decides whether a verification job runs now, runs smaller, or waits.
///
/// The pipeline's constraint is not CPU, it is *paid macOS runner-minutes per
/// hour*. Without an admission step, a burst of agent-authored PRs converts
/// that fixed budget into a queue nobody can reason about: everything is
/// accepted, everything is slow, and the merge queue — the one thing with a
/// deadline — waits behind speculative runs that will be force-pushed over in
/// ninety seconds.
///
/// Two properties make this safe to put in front of a merge queue:
///
/// - **Degrade before deferring.** A job that cannot afford `full` is offered
///   `impacted`, then `smoke`, before it is told to wait. Partial signal now
///   beats complete signal in forty minutes.
/// - **Aging guarantees progress.** Every deferral moves a job's *effective*
///   class up, so a speculative job that keeps losing eventually outranks the
///   traffic beating it and reaches the reserved capacity. Strict priority
///   without aging is a livelock with good intentions, and
///   ``StarvationAuditor`` proves the difference rather than asserting it.
public actor AdmissionController {

    public let policy: AdmissionPolicy

    /// Reservation ledger, bucketed by time. Bounded by
    /// `windowLength / bucketSize + 1` entries by construction.
    private var buckets: [Int: Milliseconds] = [:]
    private var deferrals: [String: Int] = [:]
    private var deferralOrder: [String] = []

    public init(policy: AdmissionPolicy) {
        self.policy = policy
    }

    public func admit(_ request: AdmissionRequest, now: Milliseconds) -> AdmissionOutcome {
        prune(now: now)

        let attempt = deferrals[request.id] ?? 0
        let effectiveClass = promotedClass(from: request.jobClass, deferrals: attempt)
        let used = SaturatingMath.sum(buckets.values)
        let allowance = policy.allowance(for: effectiveClass)
        let usable = max(0, SaturatingMath.subtract(allowance, used))

        // A zero-priced *desired* tier means there is genuinely nothing to
        // verify — an inert change set, say. Admitting a no-op is the correct
        // answer and costs nothing.
        if request.cost.cost(for: request.desiredTier) == 0 {
            clearDeferral(for: request.id)
            return .admitted(tier: request.desiredTier, reserved: 0, effectiveClass: effectiveClass)
        }

        // Walk down from what was asked for to the configured floor.
        var candidate = request.desiredTier
        while true {
            let price = request.cost.cost(for: candidate)
            // `price > 0` is load-bearing, not defensive. A *lower* tier that
            // costs nothing is a tier that would run nothing, and degrading
            // into it is not a degradation — it is a silent skip that reports
            // green having tested nothing, which is the worst output this
            // system can produce. If the tier the caller actually wants does
            // not fit, waiting for budget is the honest answer.
            if price > 0 && price <= usable {
                reserve(price, now: now)
                clearDeferral(for: request.id)
                if candidate == request.desiredTier {
                    return .admitted(tier: candidate, reserved: price, effectiveClass: effectiveClass)
                }
                return .degraded(
                    tier: candidate,
                    from: request.desiredTier,
                    reserved: price,
                    reason: .budgetPressure
                )
            }
            guard candidate > policy.minimumTier,
                  let next = VerificationTier(rawValue: candidate.rawValue - 1) else { break }
            candidate = next
        }

        let nextAttempt = recordDeferral(for: request.id)
        let backoff = SaturatingMath.multiply(policy.retryBackoff, max(1, min(nextAttempt, 16)))
        return .deferred(retryAfter: backoff, attempt: nextAttempt)
    }

    /// Runner-time reserved inside the current window.
    public func utilisation(now: Milliseconds) -> Milliseconds {
        prune(now: now)
        return SaturatingMath.sum(buckets.values)
    }

    public func deferralCount(for id: String) -> Int { deferrals[id] ?? 0 }

    public func ledgerEntryCount() -> Int { buckets.count }

    // MARK: - Internals

    private func promotedClass(from jobClass: JobClass, deferrals count: Int) -> JobClass {
        guard let threshold = policy.agingThreshold, count > 0 else { return jobClass }
        let steps = SaturatingMath.divide(count, by: threshold)
        let raw = min(JobClass.mergeQueue.rawValue, SaturatingMath.add(jobClass.rawValue, steps))
        return JobClass(rawValue: raw) ?? .mergeQueue
    }

    private func bucketIndex(for now: Milliseconds) -> Int {
        SaturatingMath.divide(now, by: policy.bucketSize)
    }

    /// Drops buckets older than one window.
    ///
    /// Keeps everything *above* the cutoff, which means the bound on ledger
    /// size assumes `now` never moves backwards. That is a real assumption and
    /// it is deliberate: the caller owns the clock, and a scheduler fed a
    /// rewound clock has a bigger problem than ledger growth. Buckets from a
    /// future `now` are retained rather than discarded, so a clock that jumps
    /// forward and back does not silently free budget that was reserved.
    private func prune(now: Milliseconds) {
        let cutoff = bucketIndex(for: SaturatingMath.subtract(now, policy.windowLength))
        buckets = buckets.filter { $0.key > cutoff }
    }

    private func reserve(_ amount: Milliseconds, now: Milliseconds) {
        guard amount > 0 else { return }
        let index = bucketIndex(for: now)
        buckets[index] = SaturatingMath.add(buckets[index] ?? 0, amount)
    }

    private func recordDeferral(for id: String) -> Int {
        if deferrals[id] == nil {
            deferralOrder.append(id)
            // Bounded memory. The cost is that a job evicted here loses its
            // aging credit — acceptable, because exceeding `maximumTrackedJobs`
            // distinct in-flight jobs means the queue is already pathological
            // and starvation is not the first problem to solve.
            while deferralOrder.count > policy.maximumTrackedJobs {
                let evicted = deferralOrder.removeFirst()
                deferrals.removeValue(forKey: evicted)
            }
        }
        let next = SaturatingMath.add(deferrals[id] ?? 0, 1)
        deferrals[id] = next
        return next
    }

    private func clearDeferral(for id: String) {
        guard deferrals.removeValue(forKey: id) != nil else { return }
        if let index = deferralOrder.firstIndex(of: id) {
            deferralOrder.remove(at: index)
        }
    }
}

// MARK: - Starvation auditing

public struct StarvationReport: Sendable, Hashable {
    /// Ticks the victim waited before being admitted, or `nil` if it never was.
    public let admittedAfterDeferrals: Int?
    public let horizon: Int

    public var isStarvationFree: Bool { admittedAfterDeferrals != nil }
}

/// Proves — by simulation, against a real ``AdmissionController`` — that a
/// policy cannot starve a low-priority job.
///
/// This exists because "we added aging" is the kind of claim that survives in a
/// README long after someone sets the threshold to `nil` to debug something and
/// forgets. The auditor drives the actual controller under a saturating load
/// and reports whether the victim ever gets in. Run it over your production
/// policy in a unit test and the guarantee stops being prose.
public struct StarvationAuditor: Sendable {

    public let horizon: Int

    public init(horizon: Int = 64) {
        self.horizon = max(1, horizon)
    }

    /// - Parameters:
    ///   - policy: the policy under audit.
    ///   - victimCost: what the low-priority job needs at each tier.
    ///   - loadCost: runner-time each saturating background job reserves.
    public func audit(
        policy: AdmissionPolicy,
        victimCost: TieredCost,
        loadCost: Milliseconds
    ) async -> StarvationReport {
        let controller = AdmissionController(policy: policy)
        // Keep total simulated time inside one window so the saturating load
        // never ages out and hands the victim a free slot the policy did not
        // actually grant it.
        let tick = max(1, SaturatingMath.divide(policy.windowLength, by: SaturatingMath.add(horizon, 2)))

        var now: Milliseconds = 0
        for attempt in 0..<horizon {
            // Background traffic one class above the victim, refreshed each
            // tick so the non-reserved allowance stays full.
            _ = await controller.admit(
                AdmissionRequest(
                    id: "load-\(attempt)",
                    jobClass: .pullRequest,
                    desiredTier: .full,
                    cost: TieredCost(smoke: loadCost, impacted: loadCost, full: loadCost)
                ),
                now: now
            )

            let outcome = await controller.admit(
                AdmissionRequest(
                    id: "victim",
                    jobClass: .speculative,
                    desiredTier: .full,
                    cost: victimCost
                ),
                now: now
            )

            if outcome.isAdmittedOrDegraded {
                return StarvationReport(admittedAfterDeferrals: attempt, horizon: horizon)
            }

            now = SaturatingMath.add(now, tick)
        }

        return StarvationReport(admittedAfterDeferrals: nil, horizon: horizon)
    }
}
