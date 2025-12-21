import Vapor
import Queues
@preconcurrency import Redis
import APNS
import APNSCore
import VaporAPNS

struct WidgetUpdateJob: AsyncScheduledJob {
    static func redisKey(for environment: PushEnvironment) -> RedisKey {
        switch environment {
        case .development: RedisKey("widget-tokens:development")
        case .production: RedisKey("widget-tokens:production")
        }
    }

    func run(context: QueueContext) async throws {
        let app = context.application

        // Process both environments
        await processTokens(app: app, environment: .development)
        await processTokens(app: app, environment: .production)
    }

    private func processTokens(app: Application, environment: PushEnvironment) async {
        let key = Self.redisKey(for: environment)

        // Get all tokens for this environment
        let tokens: [String]
        do {
            tokens = try await app.redis.smembers(of: key).get().compactMap { $0.string }
        } catch {
            app.logger.error("Failed to fetch widget tokens for \(environment): \(error)")
            return
        }

        guard !tokens.isEmpty else {
            app.logger.info("No widget tokens registered for \(environment)")
            return
        }

        app.logger.notice("Sending widget updates to \(tokens.count) \(environment) token(s)")

        let apnsClient = switch environment {
        case .development: await app.apns.client(.development)
        case .production: await app.apns.client(.production)
        }

        let notification = APNSWidgetsNotification(appID: "com.kylebashour.Glimpse")

        for token in tokens {
            do {
                try await apnsClient.sendWidgetsNotification(
                    notification: notification,
                    deviceToken: token
                )
                app.logger.info("Sent widget update to \(token.prefix(8))...")
            } catch let error as APNSCore.APNSError {
                app.logger.error("APNS error for \(token.prefix(8))...: \(error)")

                // Remove invalid tokens
                if let reason = error.reason,
                   reason == .badDeviceToken || reason == .unregistered || reason.reason == "ExpiredToken" {
                    app.logger.notice("Removing invalid widget token \(token.prefix(8))...")
                    _ = try? await app.redis.srem(token, from: key).get()
                }
            } catch {
                app.logger.error("Unexpected error sending widget push to \(token.prefix(8))...: \(error)")
            }
        }
    }
}
