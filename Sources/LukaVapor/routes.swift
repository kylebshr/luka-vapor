import Vapor
import Dexcom
import APNS

func routes(_ app: Application) throws {
    app.get { req async in
        "Download Luka on the App Store."
    }

    app.post("end-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(EndLiveActivityRequest.self)

        await req.application.liveActivityManager.stopPolling(
            request: body,
            app: app
        )

        return .ok
    }

    app.post("start-live-activity") { req async throws -> HTTPStatus in
        let body = try req.content.decode(StartLiveActivityRequest.self)

        // Start background polling
        await req.application.liveActivityManager.startPolling(
            request: body,
            app: req.application
        )

        return .ok
    }
}
