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

    // Register scheduled job to run every second
    app.queues.schedule(LiveActivityScheduler()).everySecond()

    // Start scheduled jobs worker
    try app.queues.startScheduledJobs()
}
