import Foundation

public enum Authorship: Sendable, Hashable {
    case human
    case agent(model: String)

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}

/// The metadata a test must carry for the scheduler to place it safely.
///
/// This is deliberately a *declaration*, not an inference. Static analysis can
/// guess at shared state; it cannot know that a test depends on another one
/// having seeded a database. Making the author state it — and making CI fail
/// when the statement is missing — is the only version of this that holds up at
/// two thousand new tests a week.
public struct TestCaseDescriptor: Sendable, Hashable {
    public let identifier: String
    public let targetID: TargetID
    /// Declared upper bound on runtime. `nil` means undeclared, which is itself
    /// a hazard: a test with no ceiling cannot be packed, because the packer
    /// has nothing to pack with.
    public let declaredTimeout: Milliseconds?
    public let touchesSharedMutableState: Bool
    /// Identifier of a test this one must run after.
    public let mustRunAfter: String?
    public let usesRealNetwork: Bool
    public let authorship: Authorship

    public init(
        identifier: String,
        targetID: TargetID,
        declaredTimeout: Milliseconds? = nil,
        touchesSharedMutableState: Bool = false,
        mustRunAfter: String? = nil,
        usesRealNetwork: Bool = false,
        authorship: Authorship = .human
    ) {
        self.identifier = identifier
        self.targetID = targetID
        self.declaredTimeout = declaredTimeout.map { max(0, $0) }
        self.touchesSharedMutableState = touchesSharedMutableState
        self.mustRunAfter = mustRunAfter
        self.usesRealNetwork = usesRealNetwork
        self.authorship = authorship
    }
}

public enum IsolationHazard: Sendable, Hashable, CustomStringConvertible {
    case sharedMutableState
    case orderDependence(on: String)
    case undeclaredTimeout
    case runtimeExceedsCeiling(declared: Milliseconds, ceiling: Milliseconds)
    case realNetworkAccess
    case duplicateIdentifier

    public var description: String {
        switch self {
        case .sharedMutableState: return "touches shared mutable state"
        case .orderDependence(let other): return "must run after \(other)"
        case .undeclaredTimeout: return "no declared timeout"
        case .runtimeExceedsCeiling(let declared, let ceiling):
            return "declared runtime \(declared)ms exceeds ceiling \(ceiling)ms"
        case .realNetworkAccess: return "reaches the real network"
        case .duplicateIdentifier: return "duplicate test identifier"
        }
    }

    /// `true` when forcing the owning bundle onto a single shard removes the
    /// hazard. Cross-shard interference is fixed by co-location; a duplicate
    /// identifier or a live network call is not.
    public var isFixedByPinning: Bool {
        switch self {
        case .sharedMutableState, .orderDependence: return true
        case .undeclaredTimeout, .runtimeExceedsCeiling, .realNetworkAccess, .duplicateIdentifier:
            return false
        }
    }
}

public enum Severity: Sendable, Hashable {
    case advisory
    case blocking
}

public struct ContractViolation: Sendable, Hashable {
    public let testIdentifier: String
    public let targetID: TargetID
    public let hazard: IsolationHazard
    public let severity: Severity
}

public struct ContractReport: Sendable, Hashable {
    public let violations: [ContractViolation]

    public init(violations: [ContractViolation]) {
        self.violations = violations
    }

    public var blockingViolations: [ContractViolation] {
        violations.filter { $0.severity == .blocking }
    }

    public var advisoryViolations: [ContractViolation] {
        violations.filter { $0.severity == .advisory }
    }

    public var isShardSafe: Bool { blockingViolations.isEmpty }

    /// Bundles that must be packed onto a single shard together.
    public var shardUnsafeTargets: Set<TargetID> {
        Set(
            violations
                .filter { $0.severity == .blocking && $0.hazard.isFixedByPinning }
                .map(\.targetID)
        )
    }
}

/// Machine-checks the isolation contract that sharding silently assumes.
///
/// ## Why this is in a scheduling library
///
/// Sharding does not merely *benefit* from isolated tests, it is **invalid**
/// without them. Two bundles that share a file, a keychain entry, or a
/// simulator default produce different results depending on which shard they
/// land in — and shard assignment changes whenever a duration estimate does. So
/// the failure does not look like a bug, it looks like flakiness, and flakiness
/// destroys the economics of the whole thing: teams respond by retrying, and a
/// retry costs a full extra shard including its boot.
///
/// When most tests were written by people, code review was the enforcement
/// mechanism. At agent-authored volume it is not — nobody reads two thousand
/// new tests a week closely enough to catch a static `var` in a helper. So the
/// contract has to move from review into CI, and the artefact that moves it is
/// this: a declaration on the test, and a gate that fails the build.
///
/// ## The authorship rule, and its cost
///
/// By default an agent-authored test is held to `.blocking` on hazards where a
/// human-authored one is only `.advisory`. The justification is about where the
/// review gate actually is: a human integration test that deliberately hits a
/// staging endpoint had a reviewer who weighed that; the agent's did not.
///
/// This is the most arguable decision in the package, and it has two real
/// costs. Authorship metadata is self-reported and can be wrong or absent. And
/// a rule that treats two identical tests differently invites people to relabel
/// rather than fix. ``strictMode`` exists for teams that would rather pay the
/// friction than accept either: it ignores authorship and blocks on every
/// hazard.
///
/// Rejected alternative: infer hazards from source with a linter. It catches
/// the obvious `static var` and misses everything reached through a helper, two
/// files away — and a gate with a known false-negative rate is worse than no
/// gate, because people trust it.
public struct AgentTestContract: Sendable {

    /// Longest runtime a single test may declare before it is treated as
    /// unpackable. A test that runs longer than a shard's target makespan
    /// *is* the makespan.
    public let maximumTestRuntime: Milliseconds
    /// Ignore authorship; block on every hazard.
    public let strictMode: Bool

    public init(maximumTestRuntime: Milliseconds, strictMode: Bool = false) {
        self.maximumTestRuntime = max(0, maximumTestRuntime)
        self.strictMode = strictMode
    }

    public func audit(_ tests: [TestCaseDescriptor]) -> ContractReport {
        var violations: [ContractViolation] = []
        var seen: Set<String> = []
        var knownIdentifiers: Set<String> = []

        for test in tests { knownIdentifiers.insert(test.identifier) }

        // Deterministic order so a report diff is reviewable.
        for test in tests.sorted(by: { ($0.targetID, $0.identifier) < ($1.targetID, $1.identifier) }) {
            if !seen.insert(test.identifier).inserted {
                violations.append(
                    ContractViolation(
                        testIdentifier: test.identifier,
                        targetID: test.targetID,
                        hazard: .duplicateIdentifier,
                        // Always blocking: two tests answering to one name make
                        // every per-test duration record ambiguous, which
                        // corrupts the packer's input regardless of who wrote them.
                        severity: .blocking
                    )
                )
            }

            if test.touchesSharedMutableState {
                violations.append(violation(test, .sharedMutableState))
            }

            if let predecessor = test.mustRunAfter {
                violations.append(
                    ContractViolation(
                        testIdentifier: test.identifier,
                        targetID: test.targetID,
                        hazard: .orderDependence(on: predecessor),
                        // Always blocking. An ordering constraint is not a
                        // style preference; it is a statement that the suite
                        // cannot be split, and no authorship makes that false.
                        severity: .blocking
                    )
                )
            }

            if test.usesRealNetwork {
                violations.append(violation(test, .realNetworkAccess))
            }

            switch test.declaredTimeout {
            case .none:
                violations.append(violation(test, .undeclaredTimeout))
            case .some(let declared) where declared > maximumTestRuntime:
                violations.append(
                    violation(test, .runtimeExceedsCeiling(declared: declared, ceiling: maximumTestRuntime))
                )
            case .some:
                break
            }
        }

        return ContractReport(violations: violations)
    }

    private func violation(_ test: TestCaseDescriptor, _ hazard: IsolationHazard) -> ContractViolation {
        let severity: Severity = (strictMode || test.authorship.isAgent) ? .blocking : .advisory
        return ContractViolation(
            testIdentifier: test.identifier,
            targetID: test.targetID,
            hazard: hazard,
            severity: severity
        )
    }
}
