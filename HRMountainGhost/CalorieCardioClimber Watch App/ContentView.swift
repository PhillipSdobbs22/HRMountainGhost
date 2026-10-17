//
//  ContentView.swift
//  CalorieCardioClimber Watch App
//
//  Standalone PaceGauge UI for Apple Watch.
//  Four screens: settings → gauge → stopped → summary.
//  Display auto-blanks after 5 seconds to save battery;
//  wrist raise wakes it.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm = WatchPaceViewModel()
    @State private var displayOn = true
    @State private var displayTimer: Timer?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if vm.showSummary {
                summaryView
            } else if vm.isPaused {
                stoppedView
            } else if vm.isActive {
                activeView
            } else {
                startView
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active && vm.isActive && !vm.isPaused {
                wakeDisplay()
            }
        }
    }

    // MARK: - Display Timer

    private func wakeDisplay() {
        displayTimer?.invalidate()
        displayOn = true
        displayTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0, repeats: false
        ) { _ in
            Task { @MainActor in displayOn = false }
        }
    }

    // MARK: - Start Screen

    private var startView: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("PaceGauge")
                    .font(.system(size: 16, weight: .bold,
                                  design: .rounded))
                    .foregroundColor(.white)

                // Tortoise pace setter
                HStack {
                    Text("🐢")
                        .font(.system(size: 32))
                    Stepper(
                        value: $vm.tortoisePace,
                        in: 0.5...vm.harePace - 0.5,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f mph",
                                    vm.tortoisePace))
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.orange)
                    }
                }

                // Goal pace setter
                HStack {
                    Text("🎯")
                        .font(.system(size: 32))
                    Stepper(
                        value: $vm.goalPace,
                        in: vm.tortoisePace...vm.harePace,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f mph",
                                    vm.goalPace))
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.yellow)
                    }
                }

                // Hare pace setter
                HStack {
                    Text("🐇")
                        .font(.system(size: 32))
                    Stepper(
                        value: $vm.harePace,
                        in: vm.tortoisePace + 0.5...vm.gaugeMax - 0.5,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f mph",
                                    vm.harePace))
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.green)
                    }
                }

                // Max HR setter for zone bar
                HStack {
                    Text("♥")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.red)
                    Stepper(
                        value: $vm.maxHR,
                        in: 140...220,
                        step: 1
                    ) {
                        Text("Max HR \(Int(vm.maxHR))")
                            .font(.system(size: 14, weight: .semibold,
                                          design: .rounded))
                            .foregroundColor(.red)
                    }
                }

                Button {
                    vm.start()
                    wakeDisplay()
                } label: {
                    Label("Start", systemImage: "figure.run")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.horizontal, 4)
        }
        .task {
            await vm.requestAuthorization()
        }
    }

    // MARK: - Active Screen

    private var activeView: some View {
        Group {
            if displayOn {
                gaugeScreen
            } else {
                // Blank black screen — tap or raise wrist to wake
                Color.black
                    .ignoresSafeArea()
                    .onTapGesture { wakeDisplay() }
            }
        }
    }

    private var gaugeScreen: some View {
        ZStack {
            // Gauge — fills screen but respects safe area
            PaceGaugeView(
                currentSpeed: vm.currentSpeedMPH,
                avgSpeed: vm.avgSpeedMPH,
                tortoise: vm.tortoisePace,
                hare: vm.harePace,
                gaugeMax: vm.gaugeMax
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Elapsed time — centered inside arc, semi-transparent, stretched wide
            Text(vm.elapsedFormatted)
                .font(.system(size: 54, weight: .bold,
                              design: .rounded))
                .foregroundColor(.white)
                .opacity(0.30)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .offset(y: 24)   // lower into the arc belly

            // HR zone bar — top of screen
            VStack {
                HRZoneBarView(heartRate: vm.heartRate,
                              maxHR: vm.maxHR)
                    .padding(.horizontal, 4)
                Spacer()
            }
            .offset(y: -10)

            // END button bottom-center — red filled capsule
            VStack {
                Spacer()
                Button {
                    displayTimer?.invalidate()
                    vm.pause()
                } label: {
                    Text("END")
                        .font(.system(size: 13, weight: .bold,
                                      design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.red)
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Stopped Screen (Resume / Save)

    private var stoppedView: some View {
        VStack(spacing: 16) {
            Text("Paused")
                .font(.system(size: 18, weight: .bold,
                              design: .rounded))
                .foregroundColor(.yellow)

            HStack(spacing: 12) {
                Button {
                    vm.resume()
                    wakeDisplay()
                } label: {
                    Text("Resume")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    vm.save()
                } label: {
                    Text("END")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    // MARK: - Summary Screen

    private var summaryView: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Pacer Complete")
                    .font(.system(size: 16, weight: .bold,
                                  design: .rounded))
                    .foregroundColor(.white)

                Text(String(format: "%.1f", vm.avgSpeedMPH))
                    .font(.system(size: 48, weight: .heavy,
                                  design: .rounded))
                    .foregroundColor(.green)

                Text("avg mph")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))

                // Goal pace comparison
                let diff = vm.avgSpeedMPH - vm.goalPace
                let sign = diff >= 0 ? "+" : ""
                Text("Keep it up!")
                    .font(.system(size: 16, weight: .bold,
                                  design: .rounded))
                    .foregroundColor(.yellow)
                    .padding(.top, 4)
                Text(String(format: "%@%.2f mph of goal pace",
                            sign, diff))
                    .font(.system(size: 14, weight: .semibold,
                                  design: .rounded))
                    .foregroundColor(diff >= 0 ? .green : .orange)

                Button("Done") {
                    vm.dismissSummary()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 8)
            }
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    ContentView()
}
