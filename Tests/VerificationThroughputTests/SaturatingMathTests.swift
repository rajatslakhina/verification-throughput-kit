import XCTest
@testable import VerificationThroughput

/// Every assertion here names an expression that **traps** in stock Swift.
/// Plain `a + b`, `a / b`, `a % b` and `Int(someDouble)` would abort the
/// process on these inputs; the point of the suite is that a corrupt duration
/// table degrades a plan instead of killing the orchestrator.
final class SaturatingMathTests: XCTestCase {

    func testAdditionClampsInsteadOfTrapping() {
        XCTAssertEqual(SaturatingMath.add(.max, 1), .max)
        XCTAssertEqual(SaturatingMath.add(.max, .max), .max)
        XCTAssertEqual(SaturatingMath.add(.min, -1), .min)
        XCTAssertEqual(SaturatingMath.add(.min, .min), .min)
        // Ordinary arithmetic is untouched.
        XCTAssertEqual(SaturatingMath.add(7, 5), 12)
        XCTAssertEqual(SaturatingMath.add(-7, 5), -2)
    }

    func testSubtractionClampsInsteadOfTrapping() {
        XCTAssertEqual(SaturatingMath.subtract(.min, 1), .min)
        XCTAssertEqual(SaturatingMath.subtract(.max, -1), .max)
        XCTAssertEqual(SaturatingMath.subtract(3, 10), -7)
    }

    func testMultiplicationClampsWithCorrectSign() {
        XCTAssertEqual(SaturatingMath.multiply(.max, 2), .max)
        XCTAssertEqual(SaturatingMath.multiply(.max, -2), .min)
        XCTAssertEqual(SaturatingMath.multiply(.min, 2), .min)
        XCTAssertEqual(SaturatingMath.multiply(-3, -4), 12)
        XCTAssertEqual(SaturatingMath.multiply(0, .max), 0)
    }

    func testDivisionHandlesBothTrappingCases() {
        // `x / 0` traps.
        XCTAssertEqual(SaturatingMath.divide(10, by: 0), 0)
        XCTAssertEqual(SaturatingMath.divide(10, by: 0, fallback: -1), -1)
        // `Int.min / -1` overflows because `-Int.min` is not representable.
        XCTAssertEqual(SaturatingMath.divide(.min, by: -1), .max)
        XCTAssertEqual(SaturatingMath.divide(-7, by: 2), -3)
    }

    func testRemainderHandlesBothTrappingCases() {
        XCTAssertEqual(SaturatingMath.remainder(10, 0), 0)
        // `Int.min % -1` overflows in Swift; its mathematical value is 0.
        XCTAssertEqual(SaturatingMath.remainder(.min, -1), 0)
        XCTAssertEqual(SaturatingMath.remainder(7, 3), 1)
    }

    func testSumOfEmptySequenceIsZeroAndOverflowClamps() {
        XCTAssertEqual(SaturatingMath.sum([Int]()), 0)
        XCTAssertEqual(SaturatingMath.sum([Int.max, Int.max, 1]), .max)
        XCTAssertEqual(SaturatingMath.sum([1, 2, 3]), 6)
    }

    func testDoubleConversionIsTotal() {
        // All four of these trap under `Int(_:)`.
        XCTAssertEqual(Int.saturating(from: Double.nan), 0)
        XCTAssertEqual(Int.saturating(from: Double.nan, nanFallback: 42), 42)
        XCTAssertEqual(Int.saturating(from: .infinity), .max)
        XCTAssertEqual(Int.saturating(from: -.infinity), .min)
        XCTAssertEqual(Int.saturating(from: 1e300), .max)
        XCTAssertEqual(Int.saturating(from: -1e300), .min)
        // And the ordinary path still rounds toward zero like `Int(_:)`.
        XCTAssertEqual(Int.saturating(from: 3.9), 3)
        XCTAssertEqual(Int.saturating(from: -3.9), -3)
        XCTAssertEqual(Int.saturating(from: 0.0), 0)
    }

    /// `0.0 / 0.0` is NaN, and a ratio over an empty duration table produces
    /// exactly that. This is the path that would otherwise crash a view body.
    func testRatioOverEmptyTableDoesNotTrap() {
        let total = 0.0
        let count = 0.0
        XCTAssertEqual(Int.saturating(from: total / count), 0)
    }

    /// The `Int`-range ceilings are derived from `Int.max`/`Int.min`, not from
    /// 64-bit literals. If someone replaces them with literals this still
    /// passes on 64-bit — so the guard is the comment plus this documented
    /// identity, which at least pins the exact boundary behaviour.
    func testBoundaryValuesRoundTrip() {
        XCTAssertEqual(Int.saturating(from: Double(Int.max)), .max)
        XCTAssertEqual(Int.saturating(from: Double(Int.min)), .min)
    }
}
