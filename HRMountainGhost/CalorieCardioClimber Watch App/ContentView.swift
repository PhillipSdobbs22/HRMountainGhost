//
//  ContentView.swift
//  CalorieCardioClimber Watch App
//
//  Standalone PaceGauge UI for Apple Watch.
//  Three screens: settings → gauge → summary.
//  Display auto-blanks after 3 seconds to save battery;
//  wrist raise wakes it.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm = WatchPaceViewModel()
    @State private var authorized = false
    @State private var displayOn = true
    @State private var displayTimer: Timer?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if vm.showSummary {
                summaryView
            } else if vm.isActive {
                activeView
            } else {
                startView
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active && vm.isActive {
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
                        .font(.system(size: 16))
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

                // Hare pace setter
                HStack {
                    Text("🐇")
                        .font(.system(size: 16))
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

                Button {
                    vm.start()
                    wakeDisplay()
                } label: {
                    Label("Start", systemImage: "figure.run")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!authorized)
            }
            .padding(.horizontal, 4)
        }
        .task {
            await vm.requestAuthorization()
            authorized = true
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
            // Gauge — fills entire screen
            PaceGaugeView(
                currentSpeed: vm.currentSpeedMPH,
                avgSpeed: vm.avgSpeedMPH,
                tortoise: vm.tortoisePace,
                hare: vm.harePace,
                gaugeMax: vm.gaugeMax
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            // HR overlay top-left
            VStack {
                HStack {
                    if vm.heartRate > 0 {
                        HStack(spacing: 1) {
                            Text("\(Int(vm.heartRate))")
                                .font(.system(size: 16, weight: .bold,
                                              design: .rounded))
                                .foregroundColor(.white)
                            Text("♥")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.top, 2)

                Spacer()
            }

            // Tiny stop button bottom-right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        displayTimer?.invalidate()
                        vm.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - Summary Screen

    private var summaryView: some View {
        VStack(spacing: 12) {
            Text("Run Complete")
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

            Button("Done") {
                vm.dismissSummary()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
    }
}

#Preview {
    ContentView()
}
