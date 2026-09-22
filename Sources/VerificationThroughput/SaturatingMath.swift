import Foundation

/// Wall-clock duration in milliseconds.
///
/// Durations are integers, never `Double`. A scheduler that compares and sums
/// durations thousands of times per plan must be exactly reproducible: two runs
/// over the same inputs have to produce byte-identical plans or the plan cache
/// is worthless and code review of a plan diff is meaningless. Floating point
/// addition is not associative, so summing the same shard's targets in a
/// different order can produce a different total — which is exactly the kind of
/// nondeterminism that makes a CI system untrustworthy.
public typealias Milliseconds = Int

/// Total (non-trapping) integer arithmetic.
///
/// Every arithmetic operation in this package goes through here. Swift's `+`,
/// `*`, `/` and `%` all trap on overflow or a zero divisor, and a scheduler
/// crashing the CI orchestrator because a historical-duration table contained a
/// garbage value is a strictly worse outcome than producing a clamped plan.
/// Clamping is the documented, tested behaviour — not an accident.
public enum SaturatingMath {

    /// `a + b`, clamped to the representable range instead of trapping.
    @inlinable
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflowed) = a.addingReportingOverflow(b)
        guard overflowed else { return result }
        return b > 0 ? Int.max : Int.min
    }

    /// `a - b`, clamped to the representable range instead of trapping.
    @inlinable
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (result, overflowed) = a.subtractingReportingOverflow(b)
        guard overflowed else { return result }
        return b < 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to the representable range instead of trapping.
    @inlinable
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflowed) = a.multipliedReportingOverflow(by: b)
        guard overflowed else { return result }
        return (a > 0) == (b > 0) ? Int.max : Int.min
    }

    /// `a / b`.
    ///
    /// Two cases trap in Swift and are handled here instead:
    /// - `b == 0` returns `fallback` (default `0`).
    /// - `Int.min / -1` overflows, because `-Int.min` is not representable;
    ///   it returns `Int.max`.
    @inlinable
    public static func divide(_ a: Int, by b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        guard !(a == Int.min && b == -1) else { return Int.max }
        return a / b
    }

    /// `a % b`.
    ///
    /// `b == 0` returns `fallback` (default `0`); `Int.min % -1` overflows in
    /// Swift and is defined here as `0`, which is its mathematical value.
    @inlinable
    public static func remainder(_ a: Int, _ b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        guard !(a == Int.min && b == -1) else { return 0 }
        return a % b
    }

    /// Sum of a sequence, clamped rather than trapping.
    @inlinable
    public static func sum<S: Sequence>(_ values: S) -> Int where S.Element == Int {
        values.reduce(0) { add($0, $1) }
    }
}

extension Int {

    /// Total conversion from `Double`.
    ///
    /// `Int(someDouble)` traps on NaN, on ±infinity, and on any finite value
    /// outside `Int`'s range. Every one of those is reachable from real inputs:
    /// a ratio computed from an empty duration table is `0/0` (NaN), and a
    /// percentage scaled by a corrupt multiplier can exceed `Int.max`.
    ///
    /// The bounds are derived from `Int.max` / `Int.min` rather than written as
    /// 64-bit literals, so this stays correct on a 32-bit `Int` platform.
    @inlinable
    public static func saturating(from value: Double, nanFallback: Int = 0) -> Int {
        if value.isNaN { return nanFallback }
        // `Double(Int.max)` rounds *up* to 2^63, so `>=` is the correct
        // comparison: any Double at or above it is out of range.
        if value >= Double(Int.max) { return .max }
        // `Double(Int.min)` is exactly -2^63 and therefore representable.
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }
}
