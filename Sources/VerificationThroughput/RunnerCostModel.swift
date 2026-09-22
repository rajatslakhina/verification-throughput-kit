import Foundation

/// Money in millionths of a US dollar.
///
/// Integer, like every other quantity here. Accumulating per-shard costs in
/// `Double` and rounding at the end produces a total that disagrees with the
/// sum of the line items, which is the one property a cost report must have.
public typealias MicroUSD = Int

public enum RunnerClass: Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case macOS
    case linux

    public var description: String {
        switch self {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        }
    }
}

public struct RunnerRate: Sendable, Hashable {
    public let microUSDPerMinute: MicroUSD

    public init(microUSDPerMinute: MicroUSD) {
        self.microUSDPerMinute = max(0, microUSDPerMinute)
    }
}

/// Converts runner-time into money.
///
/// Rates are **always injected**. This package ships no authoritative price:
/// hosted-runner pricing differs by plan, by runner size, by self-hosted vs.
/// hosted, and it changes. ``illustrative`` exists so the demo has numbers to
/// render and so the tests have a fixture — it is not a quote. Put your own
/// billing rates in before you show anyone a cost figure.
public struct RunnerCostModel: Sendable, Hashable {

    public let rates: [RunnerClass: RunnerRate]

    public init(rates: [RunnerClass: RunnerRate]) {
        self.rates = rates
    }

    /// Placeholder rates for the demo and the test fixtures.
    ///
    /// The macOS-to-Linux ratio here (roughly 6.5×) is the shape of the problem
    /// this package exists for — it is why moving verification off the Mac is
    /// the first thing anyone suggests, and why it does not work for a test
    /// suite that needs a simulator. The absolute numbers are placeholders.
    public static let illustrative = RunnerCostModel(rates: [
        .macOS: RunnerRate(microUSDPerMinute: 62_000),
        .linux: RunnerRate(microUSDPerMinute: 9_600)
    ])

    /// Cost of `runnerTime` on `runnerClass`, rounded up to the whole minute
    /// because that is how runner-minutes are actually billed. A 61-second job
    /// costs two minutes, and a plan that models it as 1.02 minutes will
    /// under-predict every invoice it ever produces.
    public func cost(runnerTime: Milliseconds, on runnerClass: RunnerClass) -> MicroUSD {
        guard runnerTime > 0, let rate = rates[runnerClass] else { return 0 }
        let minutes = billedMinutes(for: runnerTime)
        return SaturatingMath.multiply(minutes, rate.microUSDPerMinute)
    }

    /// Whole billed minutes, rounding up. Per-shard, because each shard is a
    /// separate runner with its own partial final minute.
    public func billedMinutes(for runnerTime: Milliseconds) -> Int {
        guard runnerTime > 0 else { return 0 }
        return SaturatingMath.divide(SaturatingMath.add(runnerTime, 59_999), by: 60_000)
    }

    /// Cost of a shard plan, billing each shard's minute independently.
    public func cost(of plan: ShardPlan, on runnerClass: RunnerClass) -> MicroUSD {
        plan.shards.reduce(0) { total, shard in
            let shardTime = SaturatingMath.add(plan.fixedCostPerShard, shard.work)
            return SaturatingMath.add(total, cost(runnerTime: shardTime, on: runnerClass))
        }
    }

    /// `"$1.23"`. Formatted with integer arithmetic so the string never
    /// disagrees with the value it came from.
    public static func formatted(_ microUSD: MicroUSD) -> String {
        let sign = microUSD < 0 ? "-" : ""
        // `abs(Int.min)` traps; magnitude does not.
        let magnitude = microUSD.magnitude
        let dollars = magnitude / 1_000_000
        let cents = (magnitude % 1_000_000) / 10_000
        return "\(sign)$\(dollars).\(cents < 10 ? "0" : "")\(cents)"
    }
}
