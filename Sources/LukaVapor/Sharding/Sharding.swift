import Vapor

/// Stable hashing for assigning poll sessions to shards. Each shard is a Fly machine with
/// its own dedicated static egress IP, so a stable username → shard mapping pins every
/// Dexcom account to one IP — the single-household traffic shape Dexcom tolerates.
enum ShardHash {
    /// FNV-1a 64-bit over the string's UTF-8 bytes. Swift's `hashValue` is seeded per
    /// process, so it must never be used here — two machines would disagree on ownership
    /// and either double-poll or orphan sessions.
    static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// The shard that owns a username. Hashes the raw username exactly as stored in the
    /// schedule sorted set — no normalization, or the filter would miss members.
    static func shard(for username: String, count: Int) -> Int {
        Int(hash(username) % UInt64(count))
    }
}

/// Which slice of the poll schedule this process is responsible for.
struct ShardConfig: Sendable, Equatable {
    let index: Int
    let count: Int

    func owns(_ username: String) -> Bool {
        ShardHash.shard(for: username, count: count) == index
    }

    /// Resolves this process's shard from the environment, or nil if it must not run the
    /// scheduler at all (the HTTP-only `app` process group, or a misconfigured worker).
    ///
    /// - `SHARD_INDEX` + `SHARD_COUNT` both set: explicit override for local/multi-process
    ///   testing.
    /// - `SHARD_COUNT` unset: legacy single-process mode (0, 1) — local dev, and the
    ///   rollback path for a fly.toml without worker groups.
    /// - `SHARD_COUNT` set: shard index comes from Fly's process group name — `worker<i>`
    ///   runs shard i; anything else (`app`) is HTTP-only. An index outside the count is a
    ///   deploy misconfiguration: refuse to poll rather than double-cover another shard.
    static func detect(
        env: (String) -> String? = { Environment.get($0) },
        logger: Logger
    ) -> ShardConfig? {
        if let indexString = env("SHARD_INDEX"), let countString = env("SHARD_COUNT") {
            guard let index = Int(indexString), let count = Int(countString),
                  count > 0, (0..<count).contains(index) else {
                logger.error("Invalid SHARD_INDEX=\(indexString)/SHARD_COUNT=\(countString), scheduler disabled")
                return nil
            }
            return ShardConfig(index: index, count: count)
        }

        guard let countString = env("SHARD_COUNT") else {
            return ShardConfig(index: 0, count: 1)
        }

        guard let count = Int(countString), count > 0 else {
            logger.error("Invalid SHARD_COUNT=\(countString), scheduler disabled")
            return nil
        }

        let group = env("FLY_PROCESS_GROUP") ?? ""
        guard group.hasPrefix("worker"), let index = Int(group.dropFirst("worker".count)) else {
            return nil
        }
        guard (0..<count).contains(index) else {
            logger.error("Process group \(group) has no shard within SHARD_COUNT=\(count), scheduler disabled")
            return nil
        }
        return ShardConfig(index: index, count: count)
    }
}
