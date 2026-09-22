import Foundation

public struct SimulatorID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public static func < (lhs: SimulatorID, rhs: SimulatorID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A monotonically increasing lease generation.
///
/// The token is the entire reason this pool is safe. A CI job can be paused by
/// the OS, lose its network, or simply run past its lease without dying — and
/// while it is unreachable the pool reclaims its simulator and hands it to
/// someone else. When the zombie wakes up it still believes it owns the device.
/// Comparing tokens is what lets the pool tell "the current holder is releasing"
/// apart from "a dead job is releasing a device that is no longer its own",
/// which would otherwise hand a live job's simulator to a third job mid-run.
///
/// Same idea as a fencing token in front of a distributed lock: the lock alone
/// is not enough, the holder has to prove *which* acquisition it holds.
public struct FencingToken: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public var description: String { "fence-\(value)" }

    public static func < (lhs: FencingToken, rhs: FencingToken) -> Bool {
        lhs.value < rhs.value
    }
}

public struct SimulatorLease: Sendable, Hashable {
    public let simulator: SimulatorID
    public let token: FencingToken
    public let expiresAt: Milliseconds
    /// `true` when the device was already booted, so this shard skipped the
    /// boot tax entirely. The fraction of warm acquisitions is the single
    /// number that decides whether sharding pays.
    public let wasWarm: Bool
}

public enum LeaseError: Error, Equatable, Sendable {
    case poolExhausted(capacity: Int)
    case staleToken(held: FencingToken, presented: FencingToken)
    case notLeased(SimulatorID)
    case tokenSpaceExhausted
}

public struct PoolSnapshot: Sendable, Equatable {
    public let capacity: Int
    public let warm: [SimulatorID]
    public let cold: [SimulatorID]
    public let booting: [SimulatorID]
    public let leased: [SimulatorID]

    public var created: Int { warm.count + cold.count + booting.count + leased.count }
}

/// A bounded pool of leased iOS simulators.
///
/// Boot cost is paid once per *device*, not once per shard, which is the whole
/// point: a shard that acquires a warm simulator starts running tests
/// immediately. That only works if the pool can safely take a device back from
/// a job that stopped responding — hence leases, TTLs, and fencing tokens.
public actor SimulatorPool {

    private let capacity: Int
    private let warmTarget: Int
    private let leaseTTL: Milliseconds

    private var warm: [SimulatorID] = []
    private var cold: [SimulatorID] = []
    private var booting: Set<SimulatorID> = []
    private var leases: [SimulatorID: (token: FencingToken, expiresAt: Milliseconds)] = [:]

    private var nextTokenValue: UInt64
    private var createdCount: Int = 0

    /// - Parameters:
    ///   - capacity: hard ceiling on devices that may exist. Never exceeded —
    ///     an unbounded pool is how a runner host ends up swapping itself to
    ///     death while every shard slows down together.
    ///   - warmTarget: how many booted-and-idle devices to keep ready.
    ///   - leaseTTL: how long a lease is honoured before the pool reclaims it.
    ///   - initialTokenValue: exposed only so the exhaustion path near
    ///     `UInt64.max` is reachable from a test instead of being an untested
    ///     `guard` that nobody has ever run.
    public init(
        capacity: Int,
        warmTarget: Int,
        leaseTTL: Milliseconds,
        initialTokenValue: UInt64 = 1
    ) {
        self.capacity = max(0, capacity)
        self.warmTarget = min(max(0, warmTarget), max(0, capacity))
        self.leaseTTL = max(0, leaseTTL)
        self.nextTokenValue = initialTokenValue
    }

    public func snapshot() -> PoolSnapshot {
        PoolSnapshot(
            capacity: capacity,
            warm: warm.sorted(),
            cold: cold.sorted(),
            booting: booting.sorted(),
            leased: leases.keys.sorted()
        )
    }

    public var warmCount: Int { warm.count }
    public var leasedCount: Int { leases.count }

    /// Takes a device, preferring one that is already booted.
    ///
    /// Synchronous within the actor by design: there is no `await` between
    /// choosing a device and recording its lease, so there is no window in
    /// which two callers can be handed the same device.
    public func acquire(now: Milliseconds) throws -> SimulatorLease {
        _ = reclaimExpired(now: now)

        let device: SimulatorID
        let wasWarm: Bool

        if !warm.isEmpty {
            device = warm.removeFirst()
            wasWarm = true
        } else if !cold.isEmpty {
            device = cold.removeFirst()
            wasWarm = false
        } else if createdCount < capacity {
            createdCount += 1
            device = SimulatorID("sim-\(createdCount)")
            wasWarm = false
        } else {
            throw LeaseError.poolExhausted(capacity: capacity)
        }

        guard nextTokenValue < UInt64.max else {
            // Put the device back rather than losing it to the failed acquire.
            if wasWarm { warm.insert(device, at: 0) } else { cold.insert(device, at: 0) }
            throw LeaseError.tokenSpaceExhausted
        }

        let token = FencingToken(nextTokenValue)
        nextTokenValue += 1
        let expiry = SaturatingMath.add(now, leaseTTL)
        leases[device] = (token, expiry)

        return SimulatorLease(simulator: device, token: token, expiresAt: expiry, wasWarm: wasWarm)
    }

    /// Returns a device. Rejects a lease whose token is not the one currently
    /// held, which is what stops a zombie job from releasing a device that has
    /// since been re-leased to someone else.
    @discardableResult
    public func release(_ lease: SimulatorLease, now: Milliseconds) throws -> SimulatorID {
        guard let active = leases[lease.simulator] else {
            throw LeaseError.notLeased(lease.simulator)
        }
        guard active.token == lease.token else {
            throw LeaseError.staleToken(held: active.token, presented: lease.token)
        }
        leases.removeValue(forKey: lease.simulator)
        // A cleanly released device is still booted, so it goes back warm.
        warm.append(lease.simulator)
        return lease.simulator
    }

    /// Reclaims devices whose lease has expired.
    ///
    /// Reclaimed devices go back **cold**, not warm. An expired lease means the
    /// holder stopped reporting mid-run, so the device's state is unknown:
    /// simulator defaults, keychain, installed builds, a modal alert left on
    /// screen. Recycling it warm is how one crashed job turns into a week of
    /// "flaky on CI only." Erase, then re-boot.
    @discardableResult
    public func reclaimExpired(now: Milliseconds) -> [SimulatorID] {
        let expired = leases
            .filter { $0.value.expiresAt <= now }
            .keys
            .sorted()
        for device in expired {
            leases.removeValue(forKey: device)
            cold.append(device)
        }
        return expired
    }

    /// Boots devices until `warmTarget` idle-and-booted devices exist.
    ///
    /// This is the one genuinely reentrant method in the pool: `boot` suspends,
    /// and while it is suspended other callers run `acquire` and `release`
    /// against this same actor. Two rules follow, and each has a test that
    /// fails if you break it:
    ///
    /// 1. The candidate moves into `booting` **before** the `await`, so during
    ///    the suspension it is accounted for exactly once and a concurrent
    ///    `acquire` cannot hand out a half-booted device.
    ///    (`testDeviceIsAccountedForAndUnleasableWhileMidBoot`)
    /// 2. The loop condition is re-evaluated **after** every `await` rather
    ///    than a `needed` count being computed once up front. Caching it is the
    ///    classic actor-reentrancy bug: a concurrent `release` refilling `warm`
    ///    during the suspension leaves the pool booting devices it no longer
    ///    needs and overshooting its target.
    ///    (`testPrewarmRereadsTheWarmTargetAfterEveryAwait`)
    ///
    /// The `stillUnowned` re-check below is **not** a third rule — it is
    /// redundant given rule 1, because nothing can claim a device parked in
    /// `booting`. It is kept as a cheap assertion against a future change that
    /// weakens rule 1, and it is deliberately not described as load-bearing.
    ///
    /// - Returns: the number of devices successfully booted by this call.
    @discardableResult
    public func prewarm(boot: @Sendable @escaping (SimulatorID) async -> Bool) async -> Int {
        var booted = 0
        // Bounded by capacity: even if `boot` always fails, this cannot spin.
        var attemptsRemaining = capacity
        // A device whose boot just failed is not retried in the same pass.
        // Without this, one broken device is picked, fails, goes back cold, and
        // is picked again — burning the whole attempt budget on the one device
        // least likely to work.
        var attempted: Set<SimulatorID> = []

        while attemptsRemaining > 0 {
            attemptsRemaining -= 1

            // Re-read state on every iteration. Never cached across an await.
            guard warm.count + booting.count < warmTarget else { break }

            let candidate: SimulatorID
            if let index = cold.firstIndex(where: { !attempted.contains($0) }) {
                candidate = cold.remove(at: index)
            } else if createdCount < capacity {
                createdCount += 1
                candidate = SimulatorID("sim-\(createdCount)")
            } else {
                break
            }

            attempted.insert(candidate)
            booting.insert(candidate)

            let succeeded = await boot(candidate)

            // --- Everything above this line may be stale. Re-check. ---
            booting.remove(candidate)

            // Redundant given rule 1 (see above): nothing can claim a device
            // parked in `booting`. Kept as a cheap assertion, not relied upon.
            let stillUnowned = leases[candidate] == nil
                && !warm.contains(candidate)
                && !cold.contains(candidate)

            guard stillUnowned else { continue }

            if succeeded {
                warm.append(candidate)
                booted += 1
            } else {
                cold.append(candidate)
            }
        }

        return booted
    }

    /// `true` when every device is accounted for exactly once and the pool has
    /// never exceeded its capacity. Checked by the test suite after concurrent
    /// workloads; a pool that silently leaks devices is worse than one that
    /// refuses them.
    public func invariantsHold() -> Bool {
        let all = warm + cold + booting.sorted() + leases.keys.sorted()
        guard Set(all).count == all.count else { return false }
        guard all.count == createdCount else { return false }
        return createdCount <= capacity
    }
}
