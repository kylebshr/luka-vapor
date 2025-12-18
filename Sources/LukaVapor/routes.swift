import Vapor
import Dexcom
import APNS
import Queues
import Redis

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

    app.get("start-test-job") { req async throws -> Response in
        let id = UUID()
        try await req.redis.set(PrintTestJob.runningKey(for: id), to: 1).get()
        try await req.queue.dispatch(PrintTestJob.self, .init(id: id))
        return Response(status: .ok, body: .init(string: id.uuidString))
    }

    app.get("stop-test-job", ":id") { req async throws -> HTTPStatus in
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        try await req.redis.set(PrintTestJob.runningKey(for: id), to: 0).get()
        return .ok
    }
}
