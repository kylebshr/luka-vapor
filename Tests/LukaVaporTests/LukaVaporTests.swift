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
        let lastReading = Date()
        // Polled 20s after the expected reading (5m + 20s buffer) and got rate limited:
        // skip the missed reading and aim for the following one, ~5 min out.
        let now = lastReading.addingTimeInterval(LiveActivityScheduler.readingInterval + 20)
        let delay = LiveActivityScheduler.delayUntilNextReading(after: lastReading, now: now)
        #expect((280...320).contains(delay))

        // With no prior reading to anchor to, fall back to one reading interval.
        let fallback = LiveActivityScheduler.delayUntilNextReading(after: nil, now: now)
        #expect(fallback == LiveActivityScheduler.readingInterval + 20)
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
