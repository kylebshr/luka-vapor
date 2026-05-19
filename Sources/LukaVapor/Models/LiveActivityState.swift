//
//  LiveActivityState.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 10/19/25.
//

import Foundation
import Dexcom

struct LiveActivityState: Codable, Hashable {
    struct Reading: Codable, Hashable {
        /// timestamp
        var t: Date
        /// value
        var v: Int16
    }

    enum StaleLevel: Int, Codable, Hashable {
        case fresh = 0
        case warning = 1
        case stale = 2
        case offline = 3
    }

    /// current
    var c: GlucoseReading?
    /// history
    var h: [Reading]
    /// sessionExpired
    var se: Bool? = nil
    /// staleLevel
    var s: StaleLevel? = nil
}
