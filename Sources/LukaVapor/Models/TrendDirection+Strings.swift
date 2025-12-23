//
//  File.swift
//  LukaVapor
//
//  Created by Kyle Bashour on 12/22/25.
//

import Dexcom

extension TrendDirection {
    var adjective: String? {
        switch self {
        case .flat: "stable"

        case .fortyFiveUp: "rising slowly"
        case .singleUp: "rising"
        case .doubleUp: "rising quickly"

        case .fortyFiveDown: "falling slowly"
        case .singleDown: "falling"
        case .doubleDown: "falling quickly"

        case .none, .notComputable, .rateOutOfRange: "nil"
        }
    }
}
