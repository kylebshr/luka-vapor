@testable import LukaVapor
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

    @Test("Burst backlog offsets spread across the window")
    func spreadOffsets() {
        #expect(LiveActivityScheduler.spreadOffsets(count: 0, window: 180).isEmpty)

        let offsets = LiveActivityScheduler.spreadOffsets(count: 90, window: 180)
        #expect(offsets.count == 90)
        // Each offset is its even-spacing slot plus up to 2s of jitter.
        for (index, offset) in offsets.enumerated() {
            let slot = Double(index) / 90 * 180
            #expect(offset >= slot)
            #expect(offset <= slot + 2)
        }
        // The backlog actually spans most of the window rather than clumping.
        #expect(offsets.last! > 150)
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
