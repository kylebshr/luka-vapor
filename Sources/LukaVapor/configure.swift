import Vapor
import APNS
import APNSCore
import VaporAPNS

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Configure APNS
    if let pemString = Environment.get("PUSH_NOTIFICATION_PEM"),
       let keyID = Environment.get("PUSH_NOTIFICATION_ID"),
       let teamID = Environment.get("TEAM_IDENTIFIER") {

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
