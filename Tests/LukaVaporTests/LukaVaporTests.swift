@testable import LukaVapor
import Dexcom
import VaporTesting
import Testing

@Suite("App Tests")
struct LukaVaporTests {
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

    @Test("Retry-After extends the rate limit floor past the default")
    func retryAfterExtendsFloor() {
        let lastReading = Date()
        let now = lastReading.addingTimeInterval(LiveActivityScheduler.readingInterval + 20)

        // Dexcom asked for a 10-minute wait — longer than rateLimitMinDelay (4 min), so
        // the header wins and the reschedule lands on the first reading boundary past it.
        let response = DexcomHTTPResponse(statusCode: 429, headers: ["Retry-After": "600"])
        let retryAfter = LiveActivityScheduler.honoredRetryAfter(response)
        #expect(retryAfter == 600)

        let delay = LiveActivityScheduler.delayUntilNextReading(
            after: lastReading, now: now, minimumDelay: max(LiveActivityScheduler.rateLimitMinDelay, retryAfter)
        )
        #expect(delay >= 600)
        #expect(delay <= 600 + LiveActivityScheduler.readingInterval)

        // A shorter Retry-After than our own floor doesn't shrink the backoff.
        let shortResponse = DexcomHTTPResponse(statusCode: 429, headers: ["Retry-After": "30"])
        let shortFloor = max(LiveActivityScheduler.rateLimitMinDelay, LiveActivityScheduler.honoredRetryAfter(shortResponse))
        #expect(shortFloor == LiveActivityScheduler.rateLimitMinDelay)
    }

    @Test("Retry-After is capped and absent headers fall back to 0")
    func retryAfterCapAndFallback() {
        // A far-future value can't park a session for hours.
        let huge = DexcomHTTPResponse(statusCode: 429, headers: ["Retry-After": "86400"])
        #expect(LiveActivityScheduler.honoredRetryAfter(huge) == LiveActivityScheduler.maxRetryAfter)

        // No header, unparseable header, or no response metadata at all: contribute
        // nothing, leaving rateLimitMinDelay as the effective floor.
        let noHeader = DexcomHTTPResponse(statusCode: 429)
        #expect(LiveActivityScheduler.honoredRetryAfter(noHeader) == 0)
        let garbage = DexcomHTTPResponse(statusCode: 429, headers: ["Retry-After": "soon"])
        #expect(LiveActivityScheduler.honoredRetryAfter(garbage) == 0)
        #expect(LiveActivityScheduler.honoredRetryAfter(nil) == 0)
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

@Suite("Sharding Tests")
struct ShardingTests {
    // Hardcoded FNV-1a 64 values: the hash is a persistence contract — usernames in the
    // Redis schedule set are routed by it, so a refactor that changes these values would
    // silently remap live users across shards (and egress IPs).
    @Test("FNV-1a hash is stable across releases")
    func hashStability() {
        #expect(ShardHash.hash("") == 0xcbf29ce484222325)
        #expect(ShardHash.hash("a") == 0xaf63dc4c8601ec8c)
        #expect(ShardHash.hash("kyle@example.com") == 0x9486e4cd016ae06f)
        #expect(ShardHash.hash("user@test.com") == 0xc3ecaf6e4f41ceed)
    }

    @Test("Every username is owned by exactly one shard, roughly evenly")
    func partition() {
        let count = 3
        let shards = (0..<count).map { ShardConfig(index: $0, count: count) }
        var perShard = [Int](repeating: 0, count: count)

        for i in 0..<1000 {
            let username = "user\(i)@example.com"
            let owners = shards.filter { $0.owns(username) }
            #expect(owners.count == 1)
            perShard[ShardHash.shard(for: username, count: count)] += 1
        }

        // Rough balance: each shard within ~20% of an even split.
        for shardCount in perShard {
            #expect(shardCount > 266)
            #expect(shardCount < 400)
        }
    }

    @Test("Shard config detection")
    func detect() {
        let logger = Logger(label: "test")
        func config(_ env: [String: String]) -> ShardConfig? {
            ShardConfig.detect(env: { env[$0] }, logger: logger)
        }

        // No env: legacy single-process mode.
        #expect(config([:]) == ShardConfig(index: 0, count: 1))

        // Fly worker process groups take their index from the group name.
        #expect(config(["SHARD_COUNT": "3", "FLY_PROCESS_GROUP": "worker0"]) == ShardConfig(index: 0, count: 3))
        #expect(config(["SHARD_COUNT": "3", "FLY_PROCESS_GROUP": "worker2"]) == ShardConfig(index: 2, count: 3))

        // The HTTP-only app process never runs the scheduler.
        #expect(config(["SHARD_COUNT": "3", "FLY_PROCESS_GROUP": "app"]) == nil)
        #expect(config(["SHARD_COUNT": "3"]) == nil)

        // A worker outside the count is a misconfiguration: refuse to poll.
        #expect(config(["SHARD_COUNT": "3", "FLY_PROCESS_GROUP": "worker5"]) == nil)
        #expect(config(["SHARD_COUNT": "0", "FLY_PROCESS_GROUP": "worker0"]) == nil)

        // Explicit override for local multi-process testing.
        #expect(config(["SHARD_INDEX": "1", "SHARD_COUNT": "2"]) == ShardConfig(index: 1, count: 2))
        #expect(config(["SHARD_INDEX": "2", "SHARD_COUNT": "2"]) == nil)
    }
}
