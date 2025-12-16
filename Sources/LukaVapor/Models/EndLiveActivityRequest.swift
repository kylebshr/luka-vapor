//
//  EndLiveActivityRequest.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation

struct EndLiveActivityRequest: Codable {
    var pushToken: LiveActivityPushToken?
    var username: String?
}
