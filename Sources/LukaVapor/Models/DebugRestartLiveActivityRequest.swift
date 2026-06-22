import Foundation

/// Manually triggers a push-to-start restart for one activity, for testing. Mirrors the
/// scheduler's max-duration restart (dismiss old, start new) without waiting for the time
/// limit. Matches the token by `activityID`.
struct DebugRestartLiveActivityRequest: Codable, Sendable {
    var username: String
    var activityID: String
}

extension DebugRestartLiveActivityRequest {
    var logID: String { username.redactedEmailLogID }
}
