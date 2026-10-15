//
//  ContentView.swift
//  CalorieCardioClimber Watch App
//
//  Shows live HR on the Watch and a start/stop button.
//  HR is streamed to the iPhone via WatchConnectivity.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var manager = WorkoutManager.shared

    var body: some View {
        VStack(spacing: 8) {
            if manager.isActive {
                // Active — streaming HR
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
                    .font(.title2)

                Text(manager.currentHR > 0
                     ? "\(Int(manager.currentHR))"
                     : "—")
                    .font(.system(size: 48, weight: .bold,
                                  design: .monospaced))

                Text("bpm")
                    .font(.caption)
                    .foregroundColor(.gray)

                Text("Streaming to iPhone")
                    .font(.caption2)
                    .foregroundColor(.green)

                Button("Stop") {
                    manager.stopWorkout()
                }
                .tint(.red)
                .padding(.top, 4)
            } else {
                // Idle
                Text("🚴")
                    .font(.largeTitle)

                Text("CalorieCardio\nClimber")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Tap to stream HR")
                    .font(.caption2)
                    .foregroundColor(.gray)

                Button("Start HR") {
                    Task {
                        await manager.requestAuthorization()
                        manager.startWorkout()
                    }
                }
                .tint(.green)
                .padding(.top, 4)
            }
        }
    }
}
