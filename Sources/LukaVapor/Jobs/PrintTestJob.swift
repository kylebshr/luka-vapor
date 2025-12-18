import Vapor
import Queues
import Redis

struct PrintTestJob: AsyncJob {
    typealias Payload = JobPayload

    struct JobPayload: Codable {
        let id: UUID
    }

    static func runningKey(for id: UUID) -> RedisKey {
        RedisKey("print-test-job:\(id.uuidString)")
    }

    func dequeue(_ context: QueueContext, _ payload: JobPayload) async throws {
        // Check if this job should still be running
        let isRunning = try await context.application.redis.get(Self.runningKey(for: payload.id), as: Int.self).get() ?? 0

        guard isRunning == 1 else { return }

        print("test [\(payload.id.uuidString.prefix(8))]")

        // Reschedule with a NEW JobIdentifier (required by queues)
        try await context.queue.dispatch(PrintTestJob.self, payload, delayUntil: Date().addingTimeInterval(1))
    }
}
