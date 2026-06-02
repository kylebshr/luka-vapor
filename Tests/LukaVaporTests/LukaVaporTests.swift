@testable import LukaVapor
import VaporTesting
import Testing

@Suite("App Tests")
struct LukaVaporTests {
    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Rate limit reschedules to the next reading, skipping the missed cycle")
    func rateLimitSkipsToNextReading() {
        let floor = LiveActivityScheduler.rateLimitMinDelay
        let lastReading = Date()

        // Polled 20s after the expected reading (5m + 20s buffer) and got rate limited:
        // skip the missed reading and aim for the following one, ~5 min out.
        let overdueNow = lastReading.addingTimeInterval(LiveActivityScheduler.readingInterval + 20)
        let overdueDelay = LiveActivityScheduler.delayUntilNextReading(
            after: lastReading, now: overdueNow, minimumDelay: floor
        )
        #expect((280...320).contains(overdueDelay))

        // Rate limited 40s *before* a reading is due: don't aim for that imminent reading
        // (it'd just re-trigger the 429) — skip it and land on the following one, which is
        // a full reading interval further out and comfortably past the 4-minute floor.
        let beforeDueNow = lastReading.addingTimeInterval(LiveActivityScheduler.readingInterval - 40)
        let beforeDueDelay = LiveActivityScheduler.delayUntilNextReading(
            after: lastReading, now: beforeDueNow, minimumDelay: floor
        )
        #expect(beforeDueDelay >= floor)
        #expect((340...380).contains(beforeDueDelay)) // ~6 min: 40s to the skipped reading + 5m + buffer

        // With no prior reading to anchor to, fall back to at least the floor.
        let fallback = LiveActivityScheduler.delayUntilNextReading(after: nil, now: overdueNow, minimumDelay: floor)
        #expect(fallback >= floor)
    }

    @Test("Recovery floor decays toward minInterval then clears")
    func recoveryDecay() {
        // Starts at recoveryStartInterval (300) and shrinks by 0.6 each healthy poll.
        var floor = LiveActivityScheduler.decayedRecovery(LiveActivityScheduler.recoveryStartInterval)
        #expect((floor ?? 0) == 300 * 0.6) // 180
        floor = LiveActivityScheduler.decayedRecovery(floor) // 108
        floor = LiveActivityScheduler.decayedRecovery(floor) // 64.8
        #expect((floor ?? 0) > LiveActivityScheduler.minInterval)
        // Next step drops to/below minInterval, so recovery clears entirely.
        #expect(LiveActivityScheduler.decayedRecovery(floor) == nil) // 38.88 -> nil
        #expect(LiveActivityScheduler.decayedRecovery(nil) == nil)
    }
}
