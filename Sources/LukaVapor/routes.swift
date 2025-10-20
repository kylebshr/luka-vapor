import Vapor
import Dexcom
import APNS

func routes(_ app: Application) throws {
    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    app.post("end-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(EndLiveActivityRequest.self)

        await req.application.liveActivityManager.stopPolling(
            pushToken: body.pushToken,
            app: app
        )

        return .ok
    }

    app.post("start-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(StartLiveActivityRequest.self)

        // Start background polling
        await req.application.liveActivityManager.startPolling(
            sessionID: body.sessionID,
            accountID: body.accountID,
            accountLocation: body.accountLocation,
            pushToken: body.pushToken,
            environment: body.environment,
            durationHours: body.durationHours,
            app: req.application
        )

        return .ok
    }
}
