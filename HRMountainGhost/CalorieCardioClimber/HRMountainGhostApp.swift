//
//  CalorieCardioClimberApp.swift
//  CalorieCardioClimber
//
//  Created by phillip shawn dobbs on 10/11/26.
//

import SwiftUI

@main
struct CalorieCardioClimberApp: App {
    init() {
        // Activate WatchConnectivity so the iPhone can receive
        // live HR from the companion Watch app.
        PhoneConnectivityProvider.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
