import XCTest
@testable import VerificationThroughput

final class ChangeImpactTests: XCTestCase {

    // Core ← Checkout ← CheckoutUI, each with its own test bundle.
    // `Sources/Checkout` and `Sources/CheckoutUI` are deliberately adjacent:
    // a naive `hasPrefix` makes Checkout swallow every CheckoutUI file.
    private func makeGraph() -> BuildGraph {
        BuildGraph(targets: [
            BuildTarget(id: TargetID("Core"), kind: .library, sourceRoots: ["Sources/Core"]),
            BuildTarget(
                id: TargetID("Checkout"),
                kind: .library,
                sourceRoots: ["Sources/Checkout"],
                dependencies: [TargetID("Core")]
            ),
            BuildTarget(
                id: TargetID("CheckoutUI"),
                kind: .library,
                sourceRoots: ["Sources/CheckoutUI"],
                dependencies: [TargetID("Checkout")]
            ),
            BuildTarget(
                id: TargetID("CoreTests"),
                kind: .testBundle,
                sourceRoots: ["Tests/CoreTests"],
                dependencies: [TargetID("Core")]
            ),
            BuildTarget(
                id: TargetID("CheckoutTests"),
                kind: .testBundle,
                sourceRoots: ["Tests/CheckoutTests"],
                dependencies: [TargetID("Checkout")]
            ),
            BuildTarget(
                id: TargetID("CheckoutUITests"),
                kind: .testBundle,
                sourceRoots: ["Tests/CheckoutUITests"],
                dependencies: [TargetID("CheckoutUI")]
            )
        ])
    }

    func testLeafChangeSelectsOnlyDownstreamBundles() {
        let impact = ChangeImpactAnalyzer()
            .impact(of: ["Sources/Checkout/Cart.swift"], in: makeGraph())

        XCTAssertEqual(
            impact.impactedTestTargets,
            [TargetID("CheckoutTests"), TargetID("CheckoutUITests")]
        )
        XCTAssertFalse(impact.impactedTestTargets.contains(TargetID("CoreTests")))
        XCTAssertFalse(impact.wasConservativelyWidened)
    }

    func testRootChangeReachesEveryBundle() {
        let impact = ChangeImpactAnalyzer()
            .impact(of: ["Sources/Core/Money.swift"], in: makeGraph())

        XCTAssertEqual(impact.impactedTestTargets, makeGraph().testTargets)
        XCTAssertFalse(impact.wasConservativelyWidened)
    }

    /// Prefix matching must be directory-aligned.
    ///
    /// The longest-prefix-first sort is *not* enough on its own, and this test
    /// is built so that it isn't: `Sources/Check` is a strict string prefix of
    /// `Sources/Checkout/Cart.swift` and is the **only** candidate root, so the
    /// sort cannot save it. A naive `hasPrefix` attributes the file to `Check`;
    /// directory-aligned matching correctly attributes it to nobody. Replace
    /// `isDirectoryPrefix` with `path.hasPrefix(prefix)` and this fails.
    func testStringPrefixIsNotOwnership() {
        let graph = BuildGraph(targets: [
            BuildTarget(id: TargetID("Check"), kind: .library, sourceRoots: ["Sources/Check"]),
            BuildTarget(
                id: TargetID("CheckTests"), kind: .testBundle,
                sourceRoots: ["Tests/CheckTests"], dependencies: [TargetID("Check")]
            )
        ])

        // `Sources/Check` must not swallow `Sources/Checkout/...`.
        XCTAssertNil(graph.owner(ofPath: "Sources/Checkout/Cart.swift"))
        // ...but it still owns its own directory and the directory itself.
        XCTAssertEqual(graph.owner(ofPath: "Sources/Check/Thing.swift"), TargetID("Check"))
        XCTAssertEqual(graph.owner(ofPath: "Sources/Check"), TargetID("Check"))

        // And the consequence the analyser draws from it: an unowned path
        // widens, rather than being silently attributed to the wrong module.
        let impact = ChangeImpactAnalyzer().impact(of: ["Sources/Checkout/Cart.swift"], in: graph)
        XCTAssertTrue(impact.wasConservativelyWidened)
        XCTAssertEqual(impact.unattributedPaths, ["Sources/Checkout/Cart.swift"])
    }

    /// The same rule in the richer fixture, where the sort *does* help — kept
    /// because this is the shape real graphs have.
    func testAdjacentDirectoryNamesAreNotConfused() {
        let graph = makeGraph()
        XCTAssertEqual(graph.owner(ofPath: "Sources/CheckoutUI/View.swift"), TargetID("CheckoutUI"))
        XCTAssertEqual(graph.owner(ofPath: "Sources/Checkout/Cart.swift"), TargetID("Checkout"))

        let impact = ChangeImpactAnalyzer().impact(of: ["Sources/CheckoutUI/View.swift"], in: graph)
        XCTAssertEqual(impact.impactedTestTargets, [TargetID("CheckoutUITests")])
    }

    /// The fail-safe. An unowned path could affect anything, so the plan widens
    /// to the whole suite rather than silently narrowing.
    ///
    /// The second half of this test is the part that matters: it pins what the
    /// *unsafe* implementation would have produced. Dropping unowned paths
    /// yields an empty selection here, so an implementation that "optimises"
    /// this away fails on `isEmpty`, not merely on a flag.
    func testUnownedPathWidensRatherThanNarrows() {
        let graph = makeGraph()
        let impact = ChangeImpactAnalyzer().impact(of: ["fastlane/Fastfile"], in: graph)

        XCTAssertTrue(impact.wasConservativelyWidened)
        XCTAssertEqual(impact.unattributedPaths, ["fastlane/Fastfile"])
        XCTAssertEqual(impact.impactedTestTargets, graph.testTargets)
        XCTAssertFalse(impact.impactedTestTargets.isEmpty)
        XCTAssertNil(graph.owner(ofPath: "fastlane/Fastfile"))
    }

    func testOneUnownedPathWidensEvenAlongsideOwnedOnes() {
        let graph = makeGraph()
        let impact = ChangeImpactAnalyzer().impact(
            of: ["Sources/Checkout/Cart.swift", "Package.swift"],
            in: graph
        )
        XCTAssertTrue(impact.wasConservativelyWidened)
        XCTAssertEqual(impact.impactedTestTargets, graph.testTargets)
    }

    func testInertPathsNeitherSelectNorWiden() {
        let impact = ChangeImpactAnalyzer()
            .impact(of: ["docs/adr/0004-sharding.md", "README.md"], in: makeGraph())

        XCTAssertFalse(impact.wasConservativelyWidened)
        XCTAssertTrue(impact.impactedTestTargets.isEmpty)
        XCTAssertTrue(impact.unattributedPaths.isEmpty)
    }

    func testEmptyChangeSetSelectsNothing() {
        let impact = ChangeImpactAnalyzer().impact(of: [], in: makeGraph())
        XCTAssertTrue(impact.impactedTestTargets.isEmpty)
        XCTAssertFalse(impact.wasConservativelyWidened)
    }

    func testLeadingSlashAndDotSlashAreNormalised() {
        let graph = makeGraph()
        XCTAssertEqual(graph.owner(ofPath: "./Sources/Core/Money.swift"), TargetID("Core"))
        XCTAssertEqual(graph.owner(ofPath: "/Sources/Core/Money.swift"), TargetID("Core"))
        XCTAssertNil(graph.owner(ofPath: ""))
        XCTAssertNil(graph.owner(ofPath: "/"))
    }

    /// A malformed graph export can contain a cycle. Traversal must terminate
    /// and must not recurse — this would blow the stack on a recursive walk.
    func testDependencyCycleTerminates() {
        let graph = BuildGraph(targets: [
            BuildTarget(id: TargetID("A"), kind: .library, sourceRoots: ["A"], dependencies: [TargetID("B")]),
            BuildTarget(id: TargetID("B"), kind: .library, sourceRoots: ["B"], dependencies: [TargetID("A")]),
            BuildTarget(id: TargetID("ATests"), kind: .testBundle, sourceRoots: ["ATests"], dependencies: [TargetID("A")])
        ])

        let reached = graph.transitiveDependents(of: [TargetID("A")])
        XCTAssertEqual(reached, [TargetID("A"), TargetID("B"), TargetID("ATests")])

        let impact = ChangeImpactAnalyzer().impact(of: ["A/File.swift"], in: graph)
        XCTAssertEqual(impact.impactedTestTargets, [TargetID("ATests")])
    }

    func testMostSpecificSourceRootWins() {
        let graph = BuildGraph(targets: [
            BuildTarget(id: TargetID("Wide"), kind: .library, sourceRoots: ["Sources"]),
            BuildTarget(id: TargetID("Narrow"), kind: .library, sourceRoots: ["Sources/Feature/Payments"])
        ])
        XCTAssertEqual(graph.owner(ofPath: "Sources/Feature/Payments/Pay.swift"), TargetID("Narrow"))
        XCTAssertEqual(graph.owner(ofPath: "Sources/Other/Thing.swift"), TargetID("Wide"))
    }

    func testGraphWithNoTestBundlesProducesEmptySelectionEvenWhenWidened() {
        let graph = BuildGraph(targets: [
            BuildTarget(id: TargetID("Only"), kind: .library, sourceRoots: ["Sources/Only"])
        ])
        let impact = ChangeImpactAnalyzer().impact(of: ["unowned/path.rb"], in: graph)
        XCTAssertTrue(impact.wasConservativelyWidened)
        XCTAssertTrue(impact.impactedTestTargets.isEmpty)
    }
}
