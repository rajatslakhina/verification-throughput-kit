import Foundation

/// Stable identifier for a build target.
public struct TargetID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: TargetID, rhs: TargetID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TargetKind: Sendable, Hashable {
    case library
    case application
    case testBundle
}

/// One node in the build graph.
public struct BuildTarget: Sendable, Hashable {
    public let id: TargetID
    public let kind: TargetKind
    /// Directory prefixes this target owns, relative to the repository root.
    public let sourceRoots: [String]
    /// Targets this one links against.
    public let dependencies: Set<TargetID>

    public init(
        id: TargetID,
        kind: TargetKind,
        sourceRoots: [String],
        dependencies: Set<TargetID> = []
    ) {
        self.id = id
        self.kind = kind
        self.sourceRoots = sourceRoots
        self.dependencies = dependencies
    }
}

/// The dependency graph of an Xcode/SPM workspace, with reverse edges
/// precomputed so change impact is a single traversal.
public struct BuildGraph: Sendable {

    public let targets: [TargetID: BuildTarget]

    /// `dependents[x]` is the set of targets that depend **on** `x`.
    private let dependents: [TargetID: Set<TargetID>]

    /// Source roots sorted longest-first, so the most specific owner of a path
    /// wins. `Sources/Checkout/Payments` must beat `Sources/Checkout`.
    private let ownershipIndex: [(prefix: String, target: TargetID)]

    public init(targets: [BuildTarget]) {
        var byID: [TargetID: BuildTarget] = [:]
        byID.reserveCapacity(targets.count)
        for target in targets {
            // Last writer wins on duplicate ids, deterministically, rather than
            // crashing on a malformed graph export.
            byID[target.id] = target
        }
        self.targets = byID

        var reverse: [TargetID: Set<TargetID>] = [:]
        for target in byID.values {
            for dependency in target.dependencies {
                reverse[dependency, default: []].insert(target.id)
            }
        }
        self.dependents = reverse

        var index: [(prefix: String, target: TargetID)] = []
        for target in byID.values {
            for root in target.sourceRoots {
                let normalized = BuildGraph.normalize(root)
                guard !normalized.isEmpty else { continue }
                index.append((normalized, target.id))
            }
        }
        // Longest prefix first; ties broken by target id so the index — and
        // therefore every plan derived from it — is deterministic.
        index.sort { lhs, rhs in
            if lhs.prefix.count != rhs.prefix.count { return lhs.prefix.count > rhs.prefix.count }
            if lhs.prefix != rhs.prefix { return lhs.prefix < rhs.prefix }
            return lhs.target < rhs.target
        }
        self.ownershipIndex = index
    }

    public var testTargets: Set<TargetID> {
        Set(targets.values.filter { $0.kind == .testBundle }.map(\.id))
    }

    /// The target that owns `path`, or `nil` if no source root claims it.
    public func owner(ofPath path: String) -> TargetID? {
        let normalized = BuildGraph.normalize(path)
        guard !normalized.isEmpty else { return nil }
        for entry in ownershipIndex where BuildGraph.isDirectoryPrefix(entry.prefix, of: normalized) {
            return entry.target
        }
        return nil
    }

    /// Every target reachable from `seeds` by following reverse edges — i.e.
    /// everything that has to be rebuilt and re-verified because `seeds`
    /// changed.
    ///
    /// Iterative worklist, not recursion: a malformed graph export with a
    /// dependency cycle would blow the stack on a recursive walk, and an
    /// orchestrator that crashes on bad input is worse than one that returns a
    /// conservative answer.
    public func transitiveDependents(of seeds: Set<TargetID>) -> Set<TargetID> {
        var visited: Set<TargetID> = []
        var worklist = Array(seeds)
        while let current = worklist.popLast() {
            guard visited.insert(current).inserted else { continue }
            guard let next = dependents[current] else { continue }
            for dependent in next where !visited.contains(dependent) {
                worklist.append(dependent)
            }
        }
        return visited
    }

    // MARK: - Path handling

    static func normalize(_ path: String) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Directory-aligned prefix test. `Sources/Foo` owns `Sources/Foo/A.swift`
    /// and `Sources/Foo` itself, but **not** `Sources/FooBar/A.swift`.
    static func isDirectoryPrefix(_ prefix: String, of path: String) -> Bool {
        if path == prefix { return true }
        guard path.hasPrefix(prefix) else { return false }
        let boundary = path.index(path.startIndex, offsetBy: prefix.count)
        return path[boundary] == "/"
    }
}

/// What a change set implies for verification.
public struct ChangeImpact: Sendable, Equatable {
    /// Test bundles that must run.
    public let impactedTestTargets: Set<TargetID>
    /// Non-test targets touched or transitively affected.
    public let impactedTargets: Set<TargetID>
    /// Paths no target claimed.
    public let unattributedPaths: [String]
    /// `true` when an unattributed path forced a fall back to the full suite.
    public let wasConservativelyWidened: Bool

    public init(
        impactedTestTargets: Set<TargetID>,
        impactedTargets: Set<TargetID>,
        unattributedPaths: [String],
        wasConservativelyWidened: Bool
    ) {
        self.impactedTestTargets = impactedTestTargets
        self.impactedTargets = impactedTargets
        self.unattributedPaths = unattributedPaths
        self.wasConservativelyWidened = wasConservativelyWidened
    }
}

/// Maps a set of changed files to the test bundles that can observe them.
///
/// **The load-bearing decision is what to do with a path nobody owns.** A file
/// outside every declared source root — a new top-level script, an edited
/// `Package.swift`, a fastlane change, a path the graph exporter simply did not
/// know about — could affect anything. Skipping tests for it is fail-*open*:
/// the pipeline gets faster and silently stops catching a class of regression,
/// and nobody notices until production does. So an unattributed path widens the
/// plan to every test bundle and sets `wasConservativelyWidened`, which the
/// caller can surface as "we could not narrow this run, and here is why."
///
/// Rejected alternative: treat unattributed paths as no-ops and log a warning.
/// It produces better headline numbers and is the reason people stop trusting
/// selective testing.
public struct ChangeImpactAnalyzer: Sendable {

    /// Paths that never widen the plan even when unowned — pure documentation
    /// and metadata. Matched as directory-aligned prefixes or exact filenames.
    public let inertPathPrefixes: [String]

    public init(inertPathPrefixes: [String] = ChangeImpactAnalyzer.defaultInertPaths) {
        self.inertPathPrefixes = inertPathPrefixes.map(BuildGraph.normalize).filter { !$0.isEmpty }
    }

    public static let defaultInertPaths: [String] = [
        "docs",
        "README.md",
        "LICENSE",
        ".github/ISSUE_TEMPLATE"
    ]

    public func impact(of changedPaths: [String], in graph: BuildGraph) -> ChangeImpact {
        let allTestTargets = graph.testTargets

        guard !changedPaths.isEmpty else {
            return ChangeImpact(
                impactedTestTargets: [],
                impactedTargets: [],
                unattributedPaths: [],
                wasConservativelyWidened: false
            )
        }

        var seeds: Set<TargetID> = []
        var unattributed: [String] = []

        for path in changedPaths {
            let normalized = BuildGraph.normalize(path)
            guard !normalized.isEmpty else { continue }
            if isInert(normalized) { continue }
            if let owner = graph.owner(ofPath: normalized) {
                seeds.insert(owner)
            } else {
                unattributed.append(normalized)
            }
        }

        if !unattributed.isEmpty {
            return ChangeImpact(
                impactedTestTargets: allTestTargets,
                impactedTargets: Set(graph.targets.keys),
                unattributedPaths: unattributed,
                wasConservativelyWidened: true
            )
        }

        let affected = graph.transitiveDependents(of: seeds)
        return ChangeImpact(
            impactedTestTargets: affected.intersection(allTestTargets),
            impactedTargets: affected.subtracting(allTestTargets),
            unattributedPaths: [],
            wasConservativelyWidened: false
        )
    }

    private func isInert(_ normalizedPath: String) -> Bool {
        inertPathPrefixes.contains { BuildGraph.isDirectoryPrefix($0, of: normalizedPath) }
    }
}
