import Vapor
import APNS
import APNSCore
import VaporAPNS
@preconcurrency import Redis
import Queues
import QueuesRedisDriver

// configures your application
public func configure(_ app: Application) async throws {
    // Block bot/scanner traffic probing for PHP vulnerabilities
    app.middleware.use(BotBlockerMiddleware())

    // Axiom observability (no-op if AXIOM_TOKEN / AXIOM_DATASET unset)
    app.axiom = AxiomClient(client: app.client, logger: app.logger)
    if app.axiom == nil {
        app.logger.info("Axiom not configured (set AXIOM_TOKEN and AXIOM_DATASET to enable)")
    } else {
        app.logger.info("Axiom observability enabled")
    }

    // Configure Redis (use REDIS_URL env var on Fly, localhost for local dev)
    let redisURL = Environment.get("REDIS_URL") ?? "redis://localhost:6379"
    app.redis.configuration = try RedisConfiguration(url: redisURL)

    // Configure Queues with Redis
    try app.queues.use(.redis(url: redisURL))

    // Configure APNS
    if let pemString = Environment.get("PUSH_NOTIFICATION_PEM"),
       let keyID = Environment.get("PUSH_NOTIFICATION_ID"),
       let teamID = Environment.get("TEAM_IDENTIFIER") {

        app.logger.info("Setting up APNS")

        let apnsdev = APNSClientConfiguration(
            authenticationMethod: .jwt(
                privateKey: try .loadFrom(string: pemString),
                keyIdentifier: keyID,
                teamIdentifier: teamID
            ),
            environment: .development
        )

        let apnsprod = APNSClientConfiguration(
            authenticationMethod: .jwt(
                privateKey: try .loadFrom(string: pemString),
                keyIdentifier: keyID,
                teamIdentifier: teamID
            ),
            environment: .production
        )

        await app.apns.containers.use(
            apnsdev,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .development
        )

        await app.apns.containers.use(
            apnsprod,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .production
        )
    }

    // register routes
    try routes(app)

    // One-time cleanup of legacy Live Activity keys left behind by the old `luka-vapor`
    // (pre-poll-schedule) implementation. Runs as a post-boot lifecycle handler — Redis
    // connection pools only exist after boot, so this must not run inline in configure().
    // Idempotent and namespace-disjoint from the current poll-session keys, so it's safe to
    // run on every boot. Remove once Redis is confirmed clean.
    app.lifecycle.use(LegacyKeyCleanup())

    // Register scheduled job to run every second
    app.queues.schedule(LiveActivityScheduler()).everySecond()

    // Start scheduled jobs worker
    try app.queues.startScheduledJobs()
}

/// Runs the legacy-key cleanup after the app has booted, when Redis connection pools are
/// available. Registered via `app.lifecycle.use` after Redis is configured, so its
/// `didBootAsync` fires after RediStack's own boot lifecycle has set up the pools.
struct LegacyKeyCleanup: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        await runStartupRedisCleanup(application)
    }
}

/// One-time Redis cleanup run after boot. Two concerns, both idempotent and best-effort:
///
/// 1. Legacy keys from the old `luka-vapor` app (pre-poll-schedule rewrite):
///    `live-activities:schedule` (a sorted set) and `live-activity:data:*` (per-activity
///    hashes). These prefixes are disjoint from the current `live-activities:poll*`
///    namespace, so removing them only touches old data.
///
/// 2. Orphaned current-namespace data hashes that predate the TTL backstop (added in
///    ba513d9): every live write now sets an 8h `EXPIRE`, so a `live-activities:poll:*`
///    hash with no TTL is an orphan the scheduler isn't refreshing — a memory leak. We
///    delete those. The persistent `live-activities:poll-schedule` set (no TTL by design)
///    is never matched by the `poll:*` glob, so it's safe.
///
/// Retries on failure: even at `didBoot` the connection pool may not be able to lease a
/// connection yet (TLS handshake to the Redis host, pool warmup), so the first attempt(s)
/// can fail with `timedOutWaitingForConnection`. We retry with a short delay until the pool
/// is ready, then give up after `maxAttempts` rather than retrying forever.
private func runStartupRedisCleanup(_ app: Application) async {
    let maxAttempts = 6
    for attempt in 1...maxAttempts {
        do {
            // 1. Legacy keys from the pre-poll-schedule implementation.
            let deletedSchedule = try await app.redis.delete([RedisKey("live-activities:schedule")]).get()

            var cursor = 0
            var deletedData = 0
            repeat {
                let (next, keys) = try await app.redis.scan(
                    startingFrom: cursor,
                    matching: "live-activity:data:*",
                    count: 250
                ).get()
                cursor = next
                if !keys.isEmpty {
                    deletedData += try await app.redis.delete(keys.map { RedisKey($0) }).get()
                }
            } while cursor != 0

            // 2. Orphaned current-namespace hashes with no TTL (leaked before the backstop).
            var orphanCursor = 0
            var deletedOrphans = 0
            repeat {
                let (next, keys) = try await app.redis.scan(
                    startingFrom: orphanCursor,
                    matching: "live-activities:poll:*",
                    count: 250
                ).get()
                orphanCursor = next
                for key in keys {
                    if case .unlimited = try await app.redis.ttl(RedisKey(key)).get() {
                        deletedOrphans += try await app.redis.delete([RedisKey(key)]).get()
                    }
                }
            } while orphanCursor != 0

            if deletedSchedule > 0 || deletedData > 0 || deletedOrphans > 0 {
                app.logger.info("🧹 Redis cleanup: legacy schedule=\(deletedSchedule), legacy data=\(deletedData), orphaned poll hashes (no TTL)=\(deletedOrphans)")
            } else {
                app.logger.info("🧹 Redis cleanup: nothing to remove")
            }
            return
        } catch {
            if attempt == maxAttempts {
                app.logger.warning("Startup Redis cleanup failed after \(maxAttempts) attempts: \(error)")
            } else {
                app.logger.info("Startup Redis cleanup attempt \(attempt) failed, retrying: \(error)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
