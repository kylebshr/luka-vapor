//
//  ClientEventRequest.swift
//  LukaVapor
//
//  Created by Claude on 9/12/26.
//

import Foundation

/// A batch of client-side Live Activity lifecycle observations. The app posts what it saw
/// (activity appeared, push token arrived, registration failed, …) so those land in Axiom
/// as `client_event` rows next to the server's own events under the same redacted user —
/// with the *device's* timestamp, since a batch from a background wake can reach the
/// server minutes later. One wake produces one request; events are sanitized before they
/// reach Axiom because the body is untrusted.
struct ClientEventRequest: Codable, Sendable {
    struct Event: Codable, Sendable {
        var name: String
        /// Seconds since 1970 on the device clock, when the event actually happened.
        var occurredAt: Double
        var activityID: String?
        var attributes: [String: String]?
    }

    var username: String
    var systemVersion: String?
    var deviceModel: String?
    var events: [Event]
}

extension ClientEventRequest {
    var logID: String { username.redactedEmailLogID }
}

/// Bounds and cleans untrusted client event data before it becomes Axiom fields.
enum ClientEventSanitizer {
    static let maxEvents = 50
    static let maxAttributes = 16
    static let maxValueLength = 200

    /// Fields the server stamps itself; a client must not be able to spoof them.
    static let reservedKeys: Set<String> = [
        "event", "user", "client_event", "client_time", "client_lag_s", "activity_prefix",
        "app_version", "app_build", "os_version", "device_model", "restart_source",
        "since_restart_s", "machine_id", "process_group", "shard", "shard_count", "region", "egress_ip",
    ]

    /// Lowercase snake_case, 1–40 chars. Anything else is dropped.
    static func name(_ raw: String) -> String? {
        guard (1...40).contains(raw.count), raw.allSatisfy(isNameCharacter) else { return nil }
        return raw
    }

    /// Keeps at most `maxAttributes` well-formed keys, truncates values, drops reserved keys.
    static func attributes(_ raw: [String: String]?) -> [String: String] {
        guard let raw else { return [:] }
        var clean: [String: String] = [:]
        for key in raw.keys.sorted() {
            guard clean.count < maxAttributes,
                  (1...32).contains(key.count), key.allSatisfy(isNameCharacter),
                  !reservedKeys.contains(key),
                  let value = raw[key]
            else { continue }
            clean[key] = String(value.prefix(maxValueLength))
        }
        return clean
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c == "_" || c.isNumber || (c.isLetter && c.isLowercase && c.isASCII)
    }
}
