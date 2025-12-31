//
//  File.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation
import Dexcom

enum PushEnvironment: String, Codable, Sendable {
    case development
    case production
}

struct LiveActivityPreferences: Codable {
    var targetRange: ClosedRange<Int>
    var unit: GlucoseFormatter.Unit
}

struct StartLiveActivityRequest: Codable, Sendable {
    var pushToken: LiveActivityPushToken
    var environment: PushEnvironment
    var username: String?
    var password: String?
    var accountID: UUID?
    var sessionID: UUID?
    var accountLocation: AccountLocation
    var duration: TimeInterval
    var preferences: LiveActivityPreferences?
}

extension StartLiveActivityRequest {
    var logID: String {
        if let username {
            let parts = username.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return String(username.prefix(4)) }  // not a valid email

            let local = parts[0]
            let domain = parts[1]

            // Keep first character, replace the rest (if any) with dots
            guard let firstChar = local.first else { return String(username.prefix(4)) }

            let redactionCount = max(local.count - 1, 0)
            let redaction = String(repeating: "•", count: redactionCount)

            return "\(firstChar)\(redaction)@\(domain)"
        } else if let accountID {
            return String(accountID.uuidString.prefix(4))
        } else {
            return "n/a"
        }
    }
}
