//
//  File.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation
import Dexcom

struct StartLiveActivityRequest: Codable {
    var pushToken: String
    var accountID: UUID
    var sessionID: UUID
    var accountLocation: AccountLocation
    var duration: TimeInterval
}
