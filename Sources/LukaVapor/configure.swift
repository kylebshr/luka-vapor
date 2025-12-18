import Vapor
import APNS
import APNSCore
import VaporAPNS
import Redis
import Queues
import QueuesRedisDriver

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Configure Redis
    app.redis.configuration = try RedisConfiguration(hostname: "localhost")

    // Configure Queues with Redis
    try app.queues.use(.redis(url: "redis://localhost:6379"))

    // Register jobs
    app.queues.add(PrintTestJob())
    app.queues.add(LiveActivityJob())

    // Start queue worker in-process
    try app.queues.startInProcessJobs()

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
}
