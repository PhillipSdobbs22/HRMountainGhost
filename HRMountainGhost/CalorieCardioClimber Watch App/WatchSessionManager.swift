//
//  WatchSessionManager.swift
//  CalorieCardioClimber Watch App
//
//  Manages WCSession on the Watch side. Routes commands from
//  the iPhone (start/stop HR streaming) to WorkoutManager.
//

import Foundation
import WatchConnectivity

final class WatchSessionManager: NSObject, @unchecked Sendable {
    static let shared = WatchSessionManager()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            print("Watch WCSession error: \(error)")
        } else {
            print("Watch WCSession active: \(activationState.rawValue)")
        }
    }

    /// Handle commands from the iPhone app.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let command = message["command"] as? String else { return }

        Task { @MainActor in
            switch command {
            case "startHR":
                await WorkoutManager.shared.requestAuthorization()
                WorkoutManager.shared.startWorkout()
            case "stopHR":
                WorkoutManager.shared.stopWorkout()
            default:
                break
            }
        }
    }
}
