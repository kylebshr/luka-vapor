//
//  EndLiveActivityRequest.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation

struct EndLiveActivityRequest: Codable {
    var pushToken: LiveActivityPushToken
    var username: String
    // Stable per-activity identity (ActivityKit's `Activity.id`). Preferred for matching
    // since the push token may have rotated since the client last saw it. Optional for
    // older clients that only send the push token.
    var activityID: String?
}

struct EndLiveActivitiesRequest: Codable {
    var username: String
}

extension EndLiveActivitiesRequest {
    var logID: String { username.redactedEmailLogID }
}
