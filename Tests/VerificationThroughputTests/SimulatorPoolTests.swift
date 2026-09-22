import XCTest
@testable import VerificationThroughput

final class SimulatorPoolTests: XCTestCase {

    func testWarmAcquisitionSkipsTheBootTax() async throws {
        let pool = SimulatorPool(capacity: 2, warmTarget: 2, leaseTTL: 60_000)
        let booted = await pool.prewarm { _ in true }
        XCTAssertEqual(booted, 2)

        let lease = try await pool.acquire(now: 0)
        XCTAssertTrue(lease.wasWarm)

        try await pool.release(lease, now: 1_000)
        let again = try await pool.acquire(now: 2_000)
        XCTAssertTrue(again.wasWarm, "a cleanly released device is still booted")
    }

    func testCapacityIsAHardCeiling() async throws {
        let pool = SimulatorPool(capacity: 2, warmTarget: 0, leaseTTL: 60_000)
        _ = try await pool.acquire(now: 0)
        _ = try await pool.acquire(now: 0)

        do {
            _ = try await pool.acquire(now: 0)
            XCTFail("a third lease must be refused")
        } catch let error as LeaseError {
            XCTAssertEqual(error, .poolExhausted(capacity: 2))
        }

        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.created, 2)
    }

    func testZeroCapacityPoolRefusesEverything() async {
        let pool = SimulatorPool(capacity: 0, warmTarget: 4, leaseTTL: 1_000)
        do {
            _ = try await pool.acquire(now: 0)
            XCTFail("an empty pool cannot lease")
        } catch let error as LeaseError {
            XCTAssertEqual(error, .poolExhausted(capacity: 0))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let booted = await pool.prewarm { _ in true }
        XCTAssertEqual(booted, 0)
    }

    func testReleasingAnUnleasedDeviceIsRejected() async throws {
        let pool = SimulatorPool(capacity: 1, warmTarget: 0, leaseTTL: 60_000)
        let lease = try await pool.acquire(now: 0)
        try await pool.release(lease, now: 1_000)

        do {
            try await pool.release(lease, now: 2_000)
            XCTFail("a double release must be rejected")
        } catch let error as LeaseError {
            XCTAssertEqual(error, .notLeased(lease.simulator))
        }
    }

    /// The whole reason fencing tokens exist, played out end to end.
    ///
    /// A job stalls past its TTL. The pool reclaims its device and leases it to
    /// a successor. The zombie then wakes up and tries to hand the device back.
    /// Without the token comparison that release succeeds and the successor's
    /// device is yanked out from under a running test bundle — a failure that
    /// surfaces as unreproducible CI flakiness, never as a crash.
    func testStaleTokenCannotStealTheSuccessorsDevice() async throws {
        let pool = SimulatorPool(capacity: 1, warmTarget: 0, leaseTTL: 1_000)

        let zombie = try await pool.acquire(now: 0)

        let reclaimed = await pool.reclaimExpired(now: 2_000)
        XCTAssertEqual(reclaimed, [zombie.simulator])

        let successor = try await pool.acquire(now: 2_000)
        XCTAssertEqual(successor.simulator, zombie.simulator)
        XCTAssertGreaterThan(successor.token, zombie.token)
        XCTAssertFalse(
            successor.wasWarm,
            "a reclaimed device is dirty and must be erased, not recycled warm"
        )

        do {
            try await pool.release(zombie, now: 2_100)
            XCTFail("the zombie's release must be refused")
        } catch let error as LeaseError {
            XCTAssertEqual(error, .staleToken(held: successor.token, presented: zombie.token))
        }

        // The successor still holds its device.
        let leased = await pool.leasedCount
        XCTAssertEqual(leased, 1)
        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.leased, [successor.simulator])
        XCTAssertTrue(snapshot.warm.isEmpty)
    }

    func testTokensAreStrictlyIncreasing() async throws {
        let pool = SimulatorPool(capacity: 3, warmTarget: 0, leaseTTL: 60_000)
        var tokens: [FencingToken] = []
        for _ in 0..<3 {
            tokens.append(try await pool.acquire(now: 0).token)
        }
        XCTAssertEqual(tokens, tokens.sorted())
        XCTAssertEqual(Set(tokens).count, 3)
    }

    /// The exhaustion guard is reachable, and it does not leak the device it
    /// had already taken out of the free list.
    func testTokenSpaceExhaustionRefusesWithoutLosingTheDevice() async {
        let pool = SimulatorPool(
            capacity: 1,
            warmTarget: 0,
            leaseTTL: 1_000,
            initialTokenValue: .max
        )
        do {
            _ = try await pool.acquire(now: 0)
            XCTFail("acquire must refuse once the token space is exhausted")
        } catch let error as LeaseError {
            XCTAssertEqual(error, .tokenSpaceExhausted)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.created, 1)
        XCTAssertEqual(snapshot.cold.count, 1)
        XCTAssertTrue(snapshot.leased.isEmpty)
        let holds = await pool.invariantsHold()
        XCTAssertTrue(holds)
    }

    func testExpiryIsInclusiveAndReclaimIsIdempotent() async throws {
        let pool = SimulatorPool(capacity: 1, warmTarget: 0, leaseTTL: 1_000)
        let lease = try await pool.acquire(now: 0)
        XCTAssertEqual(lease.expiresAt, 1_000)

        let tooEarly = await pool.reclaimExpired(now: 999)
        XCTAssertTrue(tooEarly.isEmpty)

        let atExpiry = await pool.reclaimExpired(now: 1_000)
        XCTAssertEqual(atExpiry, [lease.simulator])

        let second = await pool.reclaimExpired(now: 5_000)
        XCTAssertTrue(second.isEmpty)
    }

    func testFailedBootReturnsTheDeviceCold() async {
        let pool = SimulatorPool(capacity: 2, warmTarget: 2, leaseTTL: 1_000)
        let booted = await pool.prewarm { _ in false }
        XCTAssertEqual(booted, 0)

        let snapshot = await pool.snapshot()
        XCTAssertTrue(snapshot.warm.isEmpty)
        XCTAssertEqual(snapshot.cold.count, 2)
        XCTAssertTrue(snapshot.booting.isEmpty)
        let holds = await pool.invariantsHold()
        XCTAssertTrue(holds)
    }

    func testPrewarmStopsAtTheWarmTarget() async {
        let pool = SimulatorPool(capacity: 8, warmTarget: 3, leaseTTL: 1_000)
        let booted = await pool.prewarm { _ in true }
        XCTAssertEqual(booted, 3)
        let count = await pool.warmCount
        XCTAssertEqual(count, 3)
        // Already at target: a second pass boots nothing.
        let again = await pool.prewarm { _ in true }
        XCTAssertEqual(again, 0)
    }

    /// Reentrancy, with a genuine concurrent writer.
    ///
    /// `prewarm` suspends inside the actor on every boot. Twelve tasks hammer
    /// `acquire`/`release` across those suspension points. The invariant being
    /// checked is structural, not statistical: every device accounted for
    /// exactly once, nothing stranded mid-boot, capacity never exceeded.
    func testConcurrentPrewarmAndLeasingPreservesInvariants() async {
        let pool = SimulatorPool(capacity: 6, warmTarget: 4, leaseTTL: 1_000_000)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pool.prewarm { _ in
                    await Task.yield()
                    return true
                }
            }
            for worker in 0..<12 {
                group.addTask {
                    for _ in 0..<8 {
                        if let lease = try? await pool.acquire(now: Milliseconds(worker)) {
                            await Task.yield()
                            _ = try? await pool.release(lease, now: Milliseconds(worker))
                        }
                        await Task.yield()
                    }
                }
            }
        }

        let holds = await pool.invariantsHold()
        XCTAssertTrue(holds, "devices were double-counted or lost across a suspension point")

        let snapshot = await pool.snapshot()
        XCTAssertLessThanOrEqual(snapshot.created, 6)
        XCTAssertTrue(snapshot.booting.isEmpty, "a device was stranded mid-boot")
        XCTAssertTrue(snapshot.leased.isEmpty, "every worker released what it took")
    }

    /// A second concurrent shape: releases racing a prewarm. If `prewarm`
    /// cached its "how many do I still need" count across the `await`, the pool
    /// would end up over its warm target or holding a device in two lists.
    func testPrewarmRacingReleasesDoesNotDoubleFileADevice() async throws {
        let pool = SimulatorPool(capacity: 4, warmTarget: 4, leaseTTL: 1_000_000)
        let held = try await pool.acquire(now: 0)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pool.prewarm { _ in
                    await Task.yield()
                    return true
                }
            }
            group.addTask {
                await Task.yield()
                _ = try? await pool.release(held, now: 10)
            }
        }

        let holds = await pool.invariantsHold()
        XCTAssertTrue(holds)
        let snapshot = await pool.snapshot()
        XCTAssertEqual(Set(snapshot.warm).count, snapshot.warm.count, "a device was filed twice")
        XCTAssertLessThanOrEqual(snapshot.created, 4)
    }
}
