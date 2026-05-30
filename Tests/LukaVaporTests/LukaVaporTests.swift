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

    @Test("Rate limit backoff starts high, escalates, and caps")
    func rateLimitBackoff() {
        // ±60s jitter, so each step lands within a 120s-wide band.
        #expect((180...300).contains(LiveActivityScheduler.rateLimitBackoff(retryCount: 0)))
        #expect((420...540).contains(LiveActivityScheduler.rateLimitBackoff(retryCount: 1)))
        // Caps at 900s regardless of how high the retry count climbs.
        #expect((840...960).contains(LiveActivityScheduler.rateLimitBackoff(retryCount: 2)))
        #expect((840...960).contains(LiveActivityScheduler.rateLimitBackoff(retryCount: 99)))
    }

    @Test("Recovery floor decays toward minInterval then clears")
    func recoveryDecay() {
        // Starts at recoveryStartInterval (300) and shrinks by 0.6 each healthy poll.
        var floor = LiveActivityScheduler.decayedRecovery(LiveActivityScheduler.recoveryStartInterval)
        #expect((floor ?? 0) == 300 * 0.6)
        floor = LiveActivityScheduler.decayedRecovery(floor) // 108
        floor = LiveActivityScheduler.decayedRecovery(floor) // 64.8
        floor = LiveActivityScheduler.decayedRecovery(floor) // 38.88
        #expect((floor ?? 0) > LiveActivityScheduler.minInterval)
        // Next step drops to/below minInterval, so recovery clears entirely.
        #expect(LiveActivityScheduler.decayedRecovery(floor) == nil)
        #expect(LiveActivityScheduler.decayedRecovery(nil) == nil)
    }
}
