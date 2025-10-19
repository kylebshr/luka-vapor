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

    app.post("start-live-activity") { req async throws in
        let body = try req.content.decode(StartLiveActivityRequest.self)

        let client = DexcomClient(
            username: nil,
            password: nil,
            existingAccountID: body.accountID,
            existingSessionID: body.sessionID,
            accountLocation: body.accountLocation
        )

        let readings = try await client.getGlucoseReadings(
            duration: .init(value: body.duration, unit: .hours)
        ).sorted { $0.date < $1.date }

        let state = LiveActivityState(c: readings.last, h: readings.map {
            .init(t: $0.date, v: Int16($0.value))
        })

        let apnsClient = switch body.environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        do {
            try await apnsClient.sendLiveActivityNotification(
                .init(
                    expiration: .immediately,
                    priority: .immediately,
                    appID: "com.kylebashour.Glimpse",
                    contentState: state,
                    event: .update,
                    timestamp: Int(Date.now.timeIntervalSince1970),
                    dismissalDate: .none,
                    apnsID: nil
                ),
                deviceToken: body.pushToken
            )
        } catch {
            print(error)
        }

        return HTTPStatus.ok
    }
}
