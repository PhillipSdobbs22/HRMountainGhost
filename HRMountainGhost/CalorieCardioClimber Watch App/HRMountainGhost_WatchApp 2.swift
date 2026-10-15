//
//  CalorieCardioClimber_WatchApp.swift
//  CalorieCardioClimber Watch App
//
//  App entry point — activates WatchConnectivity on launch.
//

import SwiftUI

@main
struct CalorieCardioClimber_Watch_AppApp: App {
    init() {
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
