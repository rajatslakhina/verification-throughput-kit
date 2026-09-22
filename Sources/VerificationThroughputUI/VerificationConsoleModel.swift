#if canImport(SwiftUI)
import Foundation
import Observation
import VerificationThroughput

/// A named change set the console can plan against.
public struct VerificationScenario: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    public let changedPaths: [String]

    public init(id: String, title: String, detail: String, changedPaths: [String]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.changedPaths = changedPaths
    }
}

/// Everything the console needs to plan.
///
/// The host app owns and supplies this. The library deliberately ships no
/// fixture of its own, so no number rendered here can be mistaken for a
/// measurement this package took of a real repository.
public struct VerificationWorkspace: Sendable {
    public let graph: BuildGraph
    public let profiles: [TestTargetProfile]
    public let tests: [TestCaseDescriptor]
    public let policy: VerificationPolicy
    public let admissionPolicy: AdmissionPolicy
    public let scenarios: [VerificationScenario]

    public init(
        graph: BuildGraph,
        profiles: [TestTargetProfile],
        tests: [TestCaseDescriptor],
        policy: VerificationPolicy,
        admissionPolicy: AdmissionPolicy,
        scenarios: [VerificationScenario]
    ) {
        self.graph = graph
        self.profiles = profiles
        self.tests = tests
        self.policy = policy
        self.admissionPolicy = admissionPolicy
        self.scenarios = scenarios
    }
}

/// Everything the console derives from its inputs, computed as one unit so the
/// plan, its price and its admission decision can never be shown out of step
/// with each other.
public struct ConsoleOutput: Sendable {
    public let plan: VerificationPlan
    public let tieredCost: TieredCost
    public let admission: AdmissionOutcome
}

@MainActor
@Observable
public final class VerificationConsoleModel {

    public let workspace: VerificationWorkspace

    public var selectedScenarioID: String
    public var tier: VerificationTier
    public var jobClass: JobClass
    /// When on, the planner picks the shard count from the makespan curve.
    public var usesOptimalShardCount: Bool
    public var manualShardCount: Int
    /// Simulated existing load on the runner budget, as a percentage.
    public var budgetPressurePercent: Int

    @ObservationIgnored private let planner: VerificationPlanner
    @ObservationIgnored private var memo: (key: InputKey, output: ConsoleOutput)?

    public init(workspace: VerificationWorkspace) {
        self.workspace = workspace
        self.planner = VerificationPlanner(policy: workspace.policy)
        self.selectedScenarioID = workspace.scenarios.first?.id ?? ""
        // `.impacted` rather than `.full` on purpose: at `.full` the change-set
        // picker — the first control on screen — changes nothing, because the
        // full tier runs everything regardless. Opening on the tier where
        // selection actually does work is the difference between a console
        // that demonstrates something and one that looks broken.
        self.tier = .impacted
        self.jobClass = .pullRequest
        self.usesOptimalShardCount = true
        self.manualShardCount = 4
        self.budgetPressurePercent = 40
    }

    public var selectedScenario: VerificationScenario? {
        workspace.scenarios.first { $0.id == selectedScenarioID } ?? workspace.scenarios.first
    }

    public var shardCountCeiling: Int {
        max(1, min(workspace.policy.maximumShards, max(1, workspace.profiles.count)))
    }

    /// Derived state.
    ///
    /// Computed rather than recomputed from `didSet` hooks: with `@Observable`,
    /// a computed property that reads tracked storage invalidates the view on
    /// its own, and there is no second copy of state to fall out of sync. The
    /// memo exists only so a `body` that reads this a dozen times pays for one
    /// plan, not a dozen — it is keyed on every input, so a stale hit is not
    /// representable.
    public var output: ConsoleOutput {
        let key = InputKey(
            scenarioID: selectedScenarioID,
            tier: tier,
            jobClass: jobClass,
            usesOptimalShardCount: usesOptimalShardCount,
            manualShardCount: manualShardCount,
            budgetPressurePercent: budgetPressurePercent
        )
        if let memo, memo.key == key { return memo.output }
        let fresh = compute(key)
        memo = (key, fresh)
        return fresh
    }

    public var plan: VerificationPlan { output.plan }
    public var tieredCost: TieredCost { output.tieredCost }
    public var admission: AdmissionOutcome { output.admission }

    // MARK: - Internals

    private struct InputKey: Hashable {
        let scenarioID: String
        let tier: VerificationTier
        let jobClass: JobClass
        let usesOptimalShardCount: Bool
        let manualShardCount: Int
        let budgetPressurePercent: Int
    }

    private func compute(_ key: InputKey) -> ConsoleOutput {
        let paths = selectedScenario?.changedPaths ?? []

        let plan = planner.plan(
            changedPaths: paths,
            graph: workspace.graph,
            profiles: workspace.profiles,
            tests: workspace.tests,
            tier: key.tier,
            shardCountOverride: key.usesOptimalShardCount ? nil : key.manualShardCount
        )

        let cost = planner.tieredCost(
            changedPaths: paths,
            graph: workspace.graph,
            profiles: workspace.profiles,
            tests: workspace.tests
        )

        let clamped = min(100, max(0, key.budgetPressurePercent))
        let preloaded = SaturatingMath.divide(
            SaturatingMath.multiply(workspace.admissionPolicy.budgetPerWindow, clamped),
            by: 100
        )
        let ledger = SyntheticLedger(policy: workspace.admissionPolicy, preloaded: preloaded)
        let admission = ledger.admit(
            AdmissionRequest(
                id: "console",
                jobClass: key.jobClass,
                desiredTier: key.tier,
                cost: cost
            )
        )

        return ConsoleOutput(plan: plan, tieredCost: cost, admission: admission)
    }
}

/// A synchronous stand-in that applies the same tier-walk arithmetic as
/// ``AdmissionController`` without the actor hop, so the view can render a
/// decision during layout.
///
/// It models **one first-attempt decision** against a pre-loaded budget, which
/// is exactly what the console claims to show and no more. It deliberately does
/// not reimplement aging or the rolling-window ledger: a second copy of those
/// rules would be a second thing to keep correct, and the property that matters
/// about them — that nothing starves — is proved against the real actor by
/// ``StarvationAuditor`` in the test suite, not here.
struct SyntheticLedger: Sendable {
    let policy: AdmissionPolicy
    let preloaded: Milliseconds

    func admit(_ request: AdmissionRequest) -> AdmissionOutcome {
        let allowance = policy.allowance(for: request.jobClass)
        let usable = max(0, SaturatingMath.subtract(allowance, preloaded))

        // Same rule as the actor: nothing to verify at the requested tier is a
        // legitimate no-op admission, but a *lower* tier that costs nothing
        // would run nothing, and is never a valid degradation target.
        if request.cost.cost(for: request.desiredTier) == 0 {
            return .admitted(tier: request.desiredTier, reserved: 0, effectiveClass: request.jobClass)
        }

        var candidate = request.desiredTier
        while true {
            let price = request.cost.cost(for: candidate)
            if price > 0 && price <= usable {
                if candidate == request.desiredTier {
                    return .admitted(tier: candidate, reserved: price, effectiveClass: request.jobClass)
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
        return .deferred(retryAfter: policy.retryBackoff, attempt: 1)
    }
}

// MARK: - Formatting

public enum DurationFormat {
    /// `"38s"`, `"4m 12s"`, `"1h 02m"`. Integer arithmetic throughout.
    public static func short(_ milliseconds: Milliseconds) -> String {
        let total = max(0, milliseconds)
        let seconds = SaturatingMath.divide(total, by: 1_000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = SaturatingMath.divide(seconds, by: 60)
        if minutes < 60 {
            return "\(minutes)m \(SaturatingMath.remainder(seconds, 60))s"
        }
        let hours = SaturatingMath.divide(minutes, by: 60)
        let remainingMinutes = SaturatingMath.remainder(minutes, 60)
        return "\(hours)h \(remainingMinutes < 10 ? "0" : "")\(remainingMinutes)m"
    }
}
#endif
