import Vapor
import APNS
import APNSCore
import VaporAPNS
import Redis
import Queues
import QueuesRedisDriver

// configures your application
public func configure(_ app: Application) async throws {
    // Block bot/scanner traffic probing for PHP vulnerabilities
    app.middleware.use(BotBlockerMiddleware())

    // Which slice of the poll schedule this process owns (nil = HTTP-only, no scheduler).
    let shard = ShardConfig.detect(logger: app.logger)

    // Axiom observability (no-op if AXIOM_TOKEN / AXIOM_DATASET unset). Machine/shard
    // identity rides on every event so 429 rates can be grouped per egress IP.
    var axiomDefaults = [
        "machine_id": Environment.get("FLY_MACHINE_ID") ?? "local",
        "region": Environment.get("FLY_REGION") ?? "local",
        "process_group": Environment.get("FLY_PROCESS_GROUP") ?? "local",
        "shard": shard.map { String($0.index) } ?? "none",
    ]
    if let shard {
        axiomDefaults["shard_count"] = String(shard.count)
    }
    app.axiom = AxiomClient(client: app.client, logger: app.logger, defaultAttributes: axiomDefaults)
    if app.axiom == nil {
        app.logger.info("Axiom not configured (set AXIOM_TOKEN and AXIOM_DATASET to enable)")
    } else {
        app.logger.info("Axiom observability enabled")
    }

    // One-shot boot event carrying this machine's public egress IP — the join key that
    // attributes Dexcom 429s to a specific IP in Axiom (per-IP rate limiting diagnosis).
    if let axiom = app.axiom {
        let client = app.client
        Task {
            let egressIP: String
            do {
                let response = try await client.get("https://api.ipify.org")
                egressIP = response.body.map { String(buffer: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "unknown"
            } catch {
                egressIP = "unknown"
            }
            axiom.emit("boot", attributes: ["egress_ip": egressIP])
        }
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

    // Register the polling scheduler for this process's shard. The HTTP-only `app`
    // process group (shard == nil) never polls — all Dexcom traffic leaves from the
    // worker machines' dedicated static egress IPs.
    if let shard {
        app.queues.schedule(LiveActivityScheduler(shard: shard)).everySecond()
        try app.queues.startScheduledJobs()
        app.logger.info("Scheduler enabled for shard \(shard.index)/\(shard.count)")
        app.axiom?.emit("scheduler_started")
    } else {
        app.logger.info("Scheduler disabled (HTTP-only process)")
    }
}
