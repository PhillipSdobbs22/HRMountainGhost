import SwiftUI
import UIKit
import Combine

// MARK: - App-wide colors

private let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)

// MARK: - Root TabView

struct ContentView: View {
    @StateObject private var vm = RideViewModel()

    var body: some View {
        TabView {
            ClimbTab(vm: vm)
                .tabItem {
                    Image(systemName: "mountain.2.fill")
                    Text("Climb")
                }

            HistoryTab(vm: vm)
                .tabItem {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("History")
                }

            SettingsTab(vm: vm)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
        }
        .tint(yellow)
        .preferredColorScheme(.dark)
        .task {
            await vm.requestAccess()
            await vm.loadAutoGhostPace()
        }
    }
}

// MARK: - Climb Tab

struct ClimbTab: View {
    @ObservedObject var vm: RideViewModel
    @AppStorage("bodyWeightLb") private var weightLb: Double = 180
    @AppStorage("climbDistanceFt") private var climbDistanceFt: Double = 1000
    @AppStorage("userAvatar") private var userAvatar: String = "\u{1F60A}"
    @AppStorage("userAge") private var userAge: Int = 0
    @AppStorage("userSex") private var userSex: Int = 0
    @AppStorage("maxHRManual") private var maxHRManual: Int = 0
    @AppStorage("maxHROverride") private var maxHROverride: Bool = false

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var progress: Double {
        min(max(vm.displayedFt / vm.mountain.totalGainFt, 0), 1)
    }

    private var effectiveMaxHR: Int {
        if maxHROverride && maxHRManual > 0 { return maxHRManual }
        return MaxHRFormula.calculate(age: userAge, sex: userSex)
    }

    var body: some View {
        ZStack {
            navy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    // Nudge banner when falling back to calorie mode
                    if vm.isCalorieFallback {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Set your age in Settings to unlock HR Zone climbing")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    progressBar
                    tiles
                    if vm.isRunning && vm.climbMode == .hrZone {
                        zoneIndicator
                    }
                    ForEach(vm.ghosts) { ghost in
                        ghostRow(ghost)
                    }
                    Text("MOUNTAIN PROFILE")
                        .font(.footnote.bold())
                        .foregroundStyle(yellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProfileStrip(
                        progress: progress,
                        ghosts: vm.ghosts.map { g in
                            let isManual: Bool = { if case .manual = g.source { return true }; return false }()
                            return GhostDot(progress: min(max(g.currentFeet / vm.mountain.totalGainFt, 0), 1), name: g.name, isManual: isManual)
                        },
                        accent: yellow,
                        userAvatar: userAvatar,
                        markers: sprintRestMarkers
                    )
                    if !vm.ghosts.isEmpty {
                        GhostRadar(
                            radarGhosts: vm.ghosts.map { g in
                                let isManual: Bool = { if case .manual = g.source { return true }; return false }()
                                return RadarGhost(
                                    gap: vm.displayedFt - g.currentFeet,
                                    emoji: isManual ? "\u{1F47B}" : "\u{1F3C6}",
                                    isManual: isManual
                                )
                            },
                            userAvatar: userAvatar
                        )
                    }
                    if vm.isRunning {
                        sprintRestButtons
                        sprintRestStats
                    }
                    if vm.isRunning { rpeSlider }
                    if vm.showRideSummary {
                        rideSummaryCard
                    } else {
                        controls
                    }
                    if !vm.isRunning && !vm.showRideSummary { instructions }
                    if !vm.statusMessage.isEmpty {
                        Text(vm.statusMessage).font(.footnote).foregroundStyle(.white)
                    }
                }
                .padding()
            }
        }
        .onReceive(timer) { _ in vm.tick() }
        .onChange(of: vm.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: weightLb) { _, newValue in
            vm.weightLb = newValue
        }
        .onChange(of: climbDistanceFt) { _, newValue in
            vm.climbDistanceFt = newValue
        }
        .onAppear {
            vm.climbDistanceFt = climbDistanceFt
            syncClimbSettings()
        }
        .onChange(of: userAge) { _, _ in syncClimbSettings() }
        .onChange(of: userSex) { _, _ in syncClimbSettings() }
        .onChange(of: maxHRManual) { _, _ in syncClimbSettings() }
        .onChange(of: maxHROverride) { _, _ in syncClimbSettings() }
    }

    /// Set maxHR on the view model — it auto-selects the climb mode.
    private func syncClimbSettings() {
        vm.maxHR = effectiveMaxHR
    }

    private var avgFtPerMin: Double {
        guard vm.elapsed > 0 else { return 0 }
        return vm.displayedFt / (vm.elapsed / 60.0)
    }

    // MARK: - Zone indicator

    private var zoneIndicator: some View {
        HStack(spacing: 6) {
            ForEach(HRZone.allCases, id: \.rawValue) { zone in
                let active = vm.currentZone == zone
                VStack(spacing: 2) {
                    Text("Z\(zone.rawValue)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Text(zone.label)
                        .font(.system(size: 8))
                    Text("\(Int(zone.feetPerMin))")
                        .font(.system(size: 9, weight: .bold))
                    Text("ft/m")
                        .font(.system(size: 7))
                }
                .foregroundStyle(active ? navy : .white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(active ? zoneColor(zone) : Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func zoneColor(_ zone: HRZone) -> Color {
        switch zone {
        case .zone1: return Color(red: 0.5, green: 0.8, blue: 0.95)
        case .zone2: return Color(red: 0.4, green: 0.85, blue: 0.4)
        case .zone3: return Color(red: 1.0, green: 0.83, blue: 0.0)
        case .zone4: return Color(red: 1.0, green: 0.5, blue: 0.2)
        case .zone5: return Color(red: 1.0, green: 0.25, blue: 0.2)
        }
    }

    // MARK: - Existing views

    private var header: some View {
        VStack(spacing: 2) {
            HStack {
                Text(vm.mountain.name).font(.title2.bold())
                Spacer()
                Text("\(Int(vm.displayedFt)) / \(Int(vm.mountain.totalGainFt)) ft").font(.title3.bold())
            }
            if vm.isRunning || vm.displayedFt > 0 {
                HStack {
                    Spacer()
                    Text("\(String(format: "%.1f", avgFtPerMin)) ft/min")
                        .font(.subheadline.bold())
                        .foregroundStyle(yellow)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.3))
                Capsule().fill(yellow).frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 10)
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            Tile(value: vm.heartRate.map { String($0) } ?? "--", label: "HR bpm", icon: "heart.fill", iconColor: .red)
            Tile(value: String(Int(vm.activeKcal)), label: "Active kcal")
            Tile(value: timeString(vm.elapsed), label: "Time", icon: "clock.fill", iconColor: navy)
        }
    }

    private func gapColor(for ghost: Ghost) -> Color {
        let gap = vm.displayedFt - ghost.currentFeet
        if gap >= 0 {
            let intensity = min(gap / 100.0, 1.0)
            return Color(
                red: 0.3 - 0.3 * intensity,
                green: 0.85,
                blue: 0.3 - 0.2 * intensity
            )
        } else {
            let deficit = min(abs(gap) / 150.0, 1.0)
            if deficit < 0.5 {
                let t = deficit / 0.5
                return Color(red: 1.0, green: 0.85 - 0.35 * t, blue: 0.1 * (1.0 - t))
            } else {
                let t = (deficit - 0.5) / 0.5
                return Color(red: 1.0, green: 0.5 - 0.4 * t, blue: 0.0)
            }
        }
    }

    private func gapString(for ghost: Ghost) -> String {
        let gap = vm.displayedFt - ghost.currentFeet
        if abs(gap) < 1 { return "TIED" }
        let sign = gap > 0 ? "+" : ""
        return "\(sign)\(Int(gap)) ft"
    }

    private func ghostRow(_ ghost: Ghost) -> some View {
        let isManual: Bool = {
            if case .manual = ghost.source { return true }
            return false
        }()
        let emoji = isManual ? "\u{1F47B}" : "\u{1F3C6}"

        return HStack(spacing: 8) {
            Tile(
                value: "\(Int(ghost.currentFeet)) ft",
                label: "\(emoji) \(ghost.name)"
            )
            Tile(
                value: gapString(for: ghost),
                label: "Gap",
                bgColor: gapColor(for: ghost)
            )
        }
    }

    private let rpeLabels = ["Really Easy", "Easy", "Not Easy", "Hard", "Really Hard"]

    private var rpeSlider: some View {
        VStack(spacing: 6) {
            HStack {
                Text("RPE")
                    .font(.caption.bold())
                    .foregroundStyle(yellow)
                Spacer()
                Text("\(vm.rpe) — \(rpeLabels[vm.rpe])")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
            HStack(spacing: 0) {
                ForEach(0..<5) { level in
                    Button {
                        vm.rpe = level
                    } label: {
                        Text("\(level)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(vm.rpe == level ? rpeColor(level) : Color(white: 0.2))
                            .foregroundStyle(vm.rpe == level ? navy : .white.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(3)
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func rpeColor(_ level: Int) -> Color {
        switch level {
        case 0: return Color(red: 0.4, green: 0.85, blue: 0.4)
        case 1: return Color(red: 0.6, green: 0.9, blue: 0.3)
        case 2: return Color(red: 1.0, green: 0.83, blue: 0.0)
        case 3: return Color(red: 1.0, green: 0.5, blue: 0.2)
        case 4: return Color(red: 1.0, green: 0.25, blue: 0.2)
        default: return .gray
        }
    }

    private let feelingOptions: [(emoji: String, label: String)] = [
        ("\u{1F4A9}", "Tired"),
        ("\u{1F60A}", "Good"),
        ("\u{1F4AA}", "Strong")
    ]

    private var feelingPicker: some View {
        VStack(spacing: 6) {
            HStack {
                Text("HOW DID YOU FEEL?")
                    .font(.caption.bold())
                    .foregroundStyle(yellow)
                Spacer()
                if let f = vm.feeling {
                    Text(f)
                        .font(.title3)
                }
            }
            HStack(spacing: 10) {
                ForEach(Array(feelingOptions.enumerated()), id: \.offset) { _, opt in
                    Button {
                        vm.feeling = opt.emoji
                    } label: {
                        VStack(spacing: 4) {
                            Text(opt.emoji)
                                .font(.system(size: 36))
                            Text(opt.label)
                                .font(.caption2.bold())
                                .foregroundStyle(vm.feeling == opt.emoji ? .white : .white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(vm.feeling == opt.emoji ? Color.white.opacity(0.15) : Color(white: 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(vm.feeling == opt.emoji ? yellow : Color.clear, lineWidth: 2)
                        )
                    }
                }
            }
        }
    }

    private var rideSummaryCard: some View {
        VStack(spacing: 12) {
            Text("RIDE COMPLETE")
                .font(.headline.bold())
                .foregroundStyle(yellow)

            HStack(spacing: 8) {
                Tile(value: "\(Int(vm.displayedFt)) ft", label: "Elevation")
                Tile(value: String(Int(vm.activeKcal)), label: "Active kcal")
                Tile(value: timeString(vm.elapsed), label: "Time")
            }

            rpeSlider
            feelingPicker

            HStack(spacing: 10) {
                Button {
                    vm.confirmSave()
                } label: {
                    Text("SAVE")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    vm.discardRide()
                } label: {
                    Text("DISCARD")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var sprintRestMarkers: [MarkerDot] {
        guard vm.mountain.totalGainFt > 0 else { return [] }
        let gain = vm.mountain.totalGainFt
        var dots: [MarkerDot] = []
        for (i, s) in vm.recordedSprintMarkers.enumerated() {
            dots.append(MarkerDot(
                progress: min(max(s.elevationFt / gain, 0), 1),
                isSprint: true,
                label: "S\(i + 1)"
            ))
        }
        for (i, r) in vm.recordedRestMarkers.enumerated() {
            dots.append(MarkerDot(
                progress: min(max(r.elevationFt / gain, 0), 1),
                isSprint: false,
                label: "R\(i + 1)"
            ))
        }
        return dots
    }

    private var sprintRestButtons: some View {
        HStack(spacing: 10) {
            Button {
                vm.startSprint()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16))
                    if vm.isSprinting {
                        Text(String(format: "%.0f", vm.sprintTimeRemaining) + "s")
                            .font(.headline.bold().monospacedDigit())
                    } else {
                        Text("SPRINT")
                            .font(.headline.bold())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    vm.isSprinting
                        ? Color.green.opacity(0.4)
                        : Color.green.opacity(0.15)
                )
                .foregroundStyle(.green)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(vm.isSprinting || vm.isResting)

            Button {
                if vm.isResting {
                    vm.resumeExercise()
                } else {
                    vm.startRest()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cross.fill")
                        .font(.system(size: 16))
                    if vm.isResting {
                        Text("RESUME")
                            .font(.headline.bold())
                    } else {
                        Text("REST")
                            .font(.headline.bold())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    vm.isResting
                        ? Color.red.opacity(0.4)
                        : Color.red.opacity(0.15)
                )
                .foregroundStyle(.red)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red, lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(vm.isSprinting)
        }
    }

    private var sprintRestStats: some View {
        HStack(spacing: 20) {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Sprints: \(vm.sprintCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Rests: \(vm.restCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if vm.totalRestTime > 0 || vm.isResting {
                let restSec = Int(vm.totalRestTime + vm.currentRestDuration)
                Text("Rest: \(restSec / 60):\(String(format: "%02d", restSec % 60))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
    }

    private var controls: some View {
        Button {
            if vm.isRunning { vm.stop() } else { vm.start(weightLb: weightLb) }
        } label: {
            Text(vm.isRunning ? "STOP" : "START")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.white)
                .foregroundStyle(navy)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var instructions: some View {
        Group {
            if vm.climbMode == .hrZone {
                Text("1. On your Watch, start any workout.\n2. Tap START here at the same moment.\n3. Your HR zone determines your climbing speed — higher effort = faster ascent. Equal across all workout types.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("1. On your Watch, start the Indoor Cycle workout.\n2. Tap START here at the same moment.\n3. Pedal. Climb is counted from calories after you tap START.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - History Tab

struct HistoryTab: View {
    @ObservedObject var vm: RideViewModel
    @State private var rides: [RideRecord] = []

    var body: some View {
        NavigationStack {
            ZStack {
                navy.ignoresSafeArea()
                Group {
                    if rides.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "figure.outdoor.cycle")
                                .font(.system(size: 48))
                                .foregroundStyle(yellow)
                            Text("No rides yet")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                            Text("Complete a climb to see your history here.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding()
                    } else {
                        List {
                            ForEach(rides) { ride in
                                historyRow(ride)
                                    .listRowBackground(Color(white: 0.12))
                            }
                            .onDelete(perform: deleteRide)
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("History")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { reloadRides() }
        }
    }

    private func reloadRides() {
        rides = RideStore.shared.rides
    }

    private func deleteRide(at offsets: IndexSet) {
        for index in offsets {
            let ride = rides[index]
            RideStore.shared.delete(ride.id)
        }
        reloadRides()
    }

    private func historyRow(_ ride: RideRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ride.label ?? dateString(ride.date))
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if let feeling = ride.feeling {
                    Text(feeling)
                        .font(.title3)
                }
            }

            HStack(spacing: 16) {
                Label("\(Int(ride.peakFeet)) ft", systemImage: "mountain.2")
                Label("\(Int(ride.activeKcal)) kcal", systemImage: "flame")
                Label(durationString(ride.duration), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 16) {
                Text("\(String(format: "%.1f", ride.avgFeetPerMin)) ft/min avg")
                    .foregroundStyle(yellow)
                if let rpe = ride.rpe {
                    Text("RPE \(rpe)")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 4)
    }

    private func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func durationString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Settings Tab

struct SettingsTab: View {
    @ObservedObject var vm: RideViewModel
    @AppStorage("bodyWeightLb") private var weightLb: Double = 180
    @AppStorage("climbDistanceFt") private var climbDistanceFt: Double = 1000
    @AppStorage("userAvatar") private var userAvatar: String = "\u{1F60A}"
    @AppStorage("userAge") private var userAge: Int = 0
    @AppStorage("userSex") private var userSex: Int = 0
    @AppStorage("maxHRManual") private var maxHRManual: Int = 0
    @AppStorage("maxHROverride") private var maxHROverride: Bool = false

    // Manual ghost state
    @State private var manualEnabled = false
    @State private var ghostName = "Ghost"
    @State private var ghostPace: Double = 10

    // History ghost state
    @State private var historyEnabled = false
    @State private var historyMode = 0  // 0 = best pace, 1 = pick ride
    @State private var showHistory = false

    // Health import state
    @State private var showHealthImport = false

    // Profile loading state
    @State private var loadingProfile = false

    private var calculatedMaxHR: Int {
        MaxHRFormula.calculate(age: userAge, sex: userSex)
    }

    private var effectiveMaxHR: Int {
        if maxHROverride && maxHRManual > 0 { return maxHRManual }
        return calculatedMaxHR
    }

    private var sexLabel: String {
        switch userSex {
        case 1: return "Male"
        case 2: return "Female"
        default: return "Not Set"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Climb Mode (auto-selected)
                Section {
                    HStack {
                        Text("Active Engine")
                        Spacer()
                        Text(vm.climbMode == .hrZone ? "HR Zone" : "Calorie")
                            .fontWeight(.bold)
                            .foregroundStyle(yellow)
                    }

                    if vm.isCalorieFallback {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Set your age below to enable HR Zone mode — it's fairer across all activity types.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("HR Zone mode is active. Elevation scales with your heart rate zone — fair across all workout types.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Climb Mode")
                }

                // MARK: Profile
                Section {
                        HStack {
                            Text("Age")
                            Spacer()
                            TextField("Age", value: $userAge, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }

                        Picker("Sex", selection: $userSex) {
                            Text("Not Set").tag(0)
                            Text("Male").tag(1)
                            Text("Female").tag(2)
                        }

                        Button {
                            loadingProfile = true
                            Task {
                                let profile = await vm.loadHealthProfile()
                                if let age = profile.age, age > 0 {
                                    userAge = age
                                }
                                if let isFemale = profile.isFemale {
                                    userSex = isFemale ? 2 : 1
                                }
                                loadingProfile = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(.red)
                                Text(loadingProfile ? "Loading…" : "Auto-fill from Apple Health")
                            }
                        }
                        .disabled(loadingProfile)

                        Text("Age and sex are used to calculate your max heart rate. You can override them anytime.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Profile")
                    }

                    Section {
                        if userAge > 0 {
                            HStack {
                                Text("Calculated")
                                Spacer()
                                Text("\(calculatedMaxHR) bpm")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Using \(MaxHRFormula.formulaName(sex: userSex)) formula for \(sexLabel.lowercased()), age \(userAge).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Enter your age above to calculate max HR.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Manual override", isOn: $maxHROverride)

                        if maxHROverride {
                            HStack {
                                Text("Max HR")
                                Spacer()
                                TextField("bpm", value: $maxHRManual, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("bpm")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Use this if you know your true max HR from a lab test or field test.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if effectiveMaxHR > 0 {
                            HStack {
                                Text("Active Max HR")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(effectiveMaxHR) bpm")
                                    .fontWeight(.bold)
                                    .foregroundStyle(yellow)
                            }
                        }
                    } header: {
                        Text("Max Heart Rate")
                    }

                    Section {
                        ForEach(HRZone.allCases, id: \.rawValue) { zone in
                            HStack {
                                Text("Z\(zone.rawValue)")
                                    .font(.system(.body, design: .rounded).bold())
                                    .frame(width: 30)
                                Text(zone.label)
                                    .frame(width: 70, alignment: .leading)
                                Text(zone.rangeLabel)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(zone.feetPerMin)) ft/min")
                                    .font(.system(.body, design: .rounded).bold())
                                    .foregroundStyle(yellow)
                            }
                            .font(.subheadline)
                        }
                    } header: {
                        Text("HR Zones")
                    }

                Section("Body weight") {
                    TextField("Pounds", value: $weightLb, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section("Your avatar") {
                    let avatars = ["\u{1F4A9}", "\u{1F60A}", "\u{1F4AA}"]
                    let labels = ["Poop", "Smiley", "Strong"]
                    HStack(spacing: 12) {
                        ForEach(Array(avatars.enumerated()), id: \.offset) { idx, emoji in
                            Button {
                                userAvatar = emoji
                            } label: {
                                VStack(spacing: 4) {
                                    Text(emoji)
                                        .font(.system(size: 32))
                                    Text(labels[idx])
                                        .font(.caption2)
                                        .foregroundStyle(userAvatar == emoji ? .primary : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(userAvatar == emoji ? Color.accentColor.opacity(0.15) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(userAvatar == emoji ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Climb distance") {
                    HStack {
                        Text("Goal")
                        Spacer()
                        TextField("Feet", value: $climbDistanceFt, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("ft")
                            .foregroundStyle(.secondary)
                    }
                    Text("Default is 1,000 ft. Mt Whitney is 6,100 ft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Manual Ghost \u{1F47B}") {
                    Toggle("Enable manual ghost", isOn: $manualEnabled)

                    if manualEnabled {
                        TextField("Ghost name", text: $ghostName)
                        HStack {
                            Text("Pace")
                            Spacer()
                            TextField("ft/min", value: $ghostPace, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("ft/min")
                                .foregroundStyle(.secondary)
                        }
                        if let autoPace = vm.autoGhostPace {
                            Text("Default pace \(String(format: "%.1f", autoPace)) ft/min based on your last 42 days of workouts. Adjust to override.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("A pace of 10 ft/min finishes a 1,000 ft climb in about 1 hr 40 min.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("History Ghost \u{1F3C6}") {
                    Toggle("Enable history ghost", isOn: $historyEnabled)

                    if historyEnabled {
                        Picker("Source", selection: $historyMode) {
                            Text("Best pace").tag(0)
                            Text("Pick Activity").tag(1)
                        }
                        .pickerStyle(.segmented)

                        if historyMode == 0 {
                            if let best = RideStore.shared.rides.max(by: { $0.avgFeetPerMin < $1.avgFeetPerMin }) {
                                Text("Will use: \(best.label ?? "Ride") (\(String(format: "%.1f", best.avgFeetPerMin)) ft/min)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No rides recorded yet. Complete a ride first.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if historyMode == 1 {
                            Button("Select from ride history") {
                                showHistory = true
                            }
                            if let g = vm.historyGhost {
                                Text("Using: \(g.name)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Import from Apple Health \u{1F34F}") {
                    Button {
                        showHealthImport = true
                    } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                            Text("Browse Apple Health Workouts")
                        }
                    }

                    Text("Import past workouts from any app that syncs to Apple Health (Garmin, Strava, Nike, Coros, RunGap, etc.) and use them as ghost pacers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Both ghosts can run at the same time. Manual ghost uses a constant pace; history ghost replays a recorded ride. Import workouts from Apple Health to race against any past activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showHistory) {
                GhostPickerView(vm: vm, onSelect: { record in
                    vm.setHistoryGhost(record)
                    historyMode = 1
                    showHistory = false
                })
            }
            .sheet(isPresented: $showHealthImport) {
                HealthWorkoutPickerView(
                    weightLb: weightLb,
                    climbModeRaw: vm.climbMode == .hrZone ? 1 : 0,
                    maxHR: effectiveMaxHR,
                    vm: vm,
                    onImport: { record in
                        RideStore.shared.save(record)
                        vm.setHistoryGhost(record)
                        historyEnabled = true
                        historyMode = 1
                        showHealthImport = false
                    }
                )
            }
            .onAppear {
                if let g = vm.manualGhost {
                    manualEnabled = true
                    if case .manual(let fpm, let name) = g.source {
                        ghostName = name
                        ghostPace = fpm
                    }
                } else if let pace = vm.autoGhostPace {
                    // No manual ghost yet — use auto pace as default
                    ghostPace = pace
                }
                if vm.historyGhost != nil {
                    historyEnabled = true
                    historyMode = 1
                }
                // If auto ghost pace hasn't loaded yet, kick it off
                if vm.autoGhostPace == nil {
                    Task {
                        await vm.loadAutoGhostPace()
                        if vm.manualGhost == nil, let pace = vm.autoGhostPace {
                            ghostPace = pace
                        }
                    }
                }
            }
            .onDisappear {
                applyGhosts()
            }
        }
    }

    private func applyGhosts() {
        if manualEnabled {
            vm.setManualGhost(name: ghostName, feetPerMin: ghostPace)
        } else {
            vm.clearManualGhost()
        }

        if historyEnabled {
            if historyMode == 0 {
                vm.setBestPaceGhost()
            }
        } else {
            vm.clearHistoryGhost()
        }
    }
}

// MARK: - Tile

struct Tile: View {
    let value: String
    let label: String
    var bgColor: Color = .white
    var icon: String? = nil
    var iconColor: Color? = nil

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(iconColor ?? navy)
                }
                Text(label).font(.caption)
            }
        }
        .foregroundStyle(navy)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Mountain Profile

struct GhostDot {
    let progress: Double
    let name: String
    let isManual: Bool
}

struct MarkerDot {
    let progress: Double
    let isSprint: Bool
    let label: String
}

struct ProfileStrip: View {
    let progress: Double
    let ghosts: [GhostDot]
    let accent: Color
    var userAvatar: String = "\u{1F60A}"
    var markers: [MarkerDot] = []

    private let manualColor = Color(red: 0.6, green: 0.85, blue: 1.0)
    private let historyColor = Color(red: 1.0, green: 0.6, blue: 0.4)

    private let pts: [CGPoint] = [
        CGPoint(x: 0, y: 88), CGPoint(x: 60, y: 70), CGPoint(x: 120, y: 62),
        CGPoint(x: 180, y: 44), CGPoint(x: 240, y: 36), CGPoint(x: 300, y: 14),
        CGPoint(x: 358, y: 4)
    ]

    private func yAt(_ x: CGFloat) -> CGFloat {
        for i in 1..<pts.count where x <= pts[i].x {
            let a = pts[i - 1], b = pts[i]
            let t = (x - a.x) / (b.x - a.x)
            return a.y + (b.y - a.y) * t
        }
        return pts[pts.count - 1].y
    }

    var body: some View {
        GeometryReader { geo in
            let sx = geo.size.width / 358
            let sy = geo.size.height / 90
            let cx = CGFloat(progress) * 358
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    for pt in pts { p.addLine(to: CGPoint(x: pt.x * sx, y: pt.y * sy)) }
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.2, green: 0.255, blue: 0.361))

                Path { p in
                    p.move(to: CGPoint(x: 0, y: pts[0].y * sy))
                    for pt in pts where pt.x < cx { p.addLine(to: CGPoint(x: pt.x * sx, y: pt.y * sy)) }
                    p.addLine(to: CGPoint(x: cx * sx, y: yAt(cx) * sy))
                }
                .stroke(accent, lineWidth: 4)

                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    let mx = CGFloat(marker.progress) * 358
                    let my = yAt(mx) * sy
                    if marker.isSprint {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                            .position(x: mx * sx, y: my - 14)
                    } else {
                        Image(systemName: "cross.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .position(x: mx * sx, y: my - 14)
                    }
                }

                Image(systemName: "flag.checkered")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .position(x: 358 * sx, y: yAt(358) * sy - 16)

                Text(userAvatar)
                    .font(.system(size: 32))
                    .position(x: cx * sx, y: yAt(cx) * sy - 8)

                ForEach(Array(ghosts.enumerated()), id: \.offset) { _, ghost in
                    let gx = CGFloat(ghost.progress) * 358
                    let color = ghost.isManual ? manualColor : historyColor
                    let emoji = ghost.isManual ? "\u{1F47B}" : "\u{1F3C6}"
                    Circle()
                        .fill(color)
                        .opacity(0.85)
                        .frame(width: 16, height: 16)
                        .position(x: gx * sx, y: yAt(gx) * sy)

                    Text(emoji)
                        .font(.system(size: 20))
                        .position(x: gx * sx, y: yAt(gx) * sy - 16)
                }
            }
        }
        .frame(height: 130)
    }
}

// MARK: - Ghost Radar

struct RadarGhost {
    let gap: Double
    let emoji: String
    let isManual: Bool
}

struct GhostRadar: View {
    let radarGhosts: [RadarGhost]
    var userAvatar: String = "\u{1F60A}"

    private let halfRange: Double = 50

    private let ghostColors: [Color] = [
        Color(red: 0.6, green: 0.85, blue: 1.0),
        Color(red: 1.0, green: 0.6, blue: 0.4)
    ]

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("GHOST RADAR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ghostColors[0].opacity(0.7))
                Spacer()
                Text("\u{00B1}\(Int(halfRange)) ft window")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }

            GeometryReader { geo in
                let midX = geo.size.width / 2
                let barH = geo.size.height

                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.15))

                    Rectangle()
                        .fill(yellow)
                        .frame(width: 2, height: barH)
                        .position(x: midX, y: barH / 2)

                    ForEach([-25, 25], id: \.self) { offset in
                        let frac = Double(offset) / halfRange
                        let x = midX + CGFloat(frac) * midX
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 1, height: barH * 0.4)
                            .position(x: x, y: barH / 2)
                    }

                    ForEach(Array(radarGhosts.enumerated()), id: \.offset) { idx, rg in
                        let raw = -rg.gap / halfRange
                        let clamped = min(max(raw, -1.0), 1.0)
                        let inRange = abs(rg.gap) <= halfRange
                        let color = ghostColors[idx % ghostColors.count]

                        if inRange {
                            let gx = midX + CGFloat(clamped) * midX
                            VStack(spacing: 0) {
                                Text(rg.emoji)
                                    .font(.system(size: 14))
                                Text("\(Int(abs(rg.gap))) ft")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(color)
                            }
                            .position(x: gx, y: barH / 2)
                        } else {
                            let isAhead = rg.gap < 0
                            let edgeX = isAhead ? geo.size.width - 16 : CGFloat(16)
                            let arrow = isAhead ? "\u{25B6}" : "\u{25C0}"

                            VStack(spacing: 0) {
                                HStack(spacing: 2) {
                                    Text(rg.emoji)
                                        .font(.system(size: 12))
                                    Text(arrow)
                                        .font(.system(size: 8))
                                        .foregroundStyle(color)
                                }
                                Text("\(Int(abs(rg.gap))) ft")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(color)
                            }
                            .position(x: edgeX, y: barH / 2)
                        }
                    }

                    Text(userAvatar)
                        .font(.system(size: 14))
                        .position(x: midX, y: barH - 6)
                }
            }
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Ghost Picker (for Settings ghost selection)

struct GhostPickerView: View {
    @ObservedObject var vm: RideViewModel
    let onSelect: (RideRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if RideStore.shared.rides.isEmpty {
                    VStack(spacing: 12) {
                        Text("No rides yet")
                            .font(.title3.bold())
                        Text("Complete a ride to see it here. You can then race against your past self.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(RideStore.shared.rides) { ride in
                            Button {
                                onSelect(ride)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ride.label ?? dateString(ride.date))
                                        .font(.headline)
                                    HStack(spacing: 16) {
                                        Label("\(Int(ride.peakFeet)) ft", systemImage: "mountain.2")
                                        Label("\(Int(ride.activeKcal)) kcal", systemImage: "flame")
                                        Label(durationString(ride.duration), systemImage: "clock")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    HStack(spacing: 16) {
                                        Text("\(String(format: "%.1f", ride.avgFeetPerMin)) ft/min avg")
                                        if let rpe = ride.rpe {
                                            Text("RPE \(rpe)")
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.2))
                                                .clipShape(Capsule())
                                        }
                                        if let feeling = ride.feeling {
                                            Text(feeling)
                                                .font(.system(size: 16))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Select Ghost Ride")
            .toolbar {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func durationString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Health Workout Picker

import HealthKit

struct HealthWorkoutPickerView: View {
    let weightLb: Double
    let climbModeRaw: Int
    let maxHR: Int
    @ObservedObject var vm: RideViewModel
    let onImport: (RideRecord) -> Void

    @StateObject private var importer = HealthHistoryImporter()
    @Environment(\.dismiss) private var dismiss
    @State private var importing: UUID? = nil

    private var isHRZoneMode: Bool { climbModeRaw == 1 }

    var body: some View {
        NavigationStack {
            Group {
                if importer.isLoading {
                    ProgressView("Loading workouts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = importer.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await importer.fetchWorkouts() }
                        }
                    }
                    .padding()
                } else if importer.workouts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "heart.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No workouts found")
                            .font(.title3.bold())
                        Text("Make sure your fitness apps (Garmin, Strava, Nike, etc.) are set to sync workouts to Apple Health.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        if isHRZoneMode {
                            Section {
                                Text("Importing using HR Zone engine (Max HR: \(maxHR) bpm). Elevation is calculated from heart rate zones, equal across all workout types.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(importer.workouts, id: \.uuid) { workout in
                            workoutRow(workout)
                        }
                    }
                }
            }
            .navigationTitle("Apple Health")
            .toolbar {
                Button("Cancel") { dismiss() }
            }
            .task {
                do {
                    try await importer.requestAccess()
                } catch {
                    importer.errorMessage = error.localizedDescription
                    return
                }
                await importer.fetchWorkouts()
            }
        }
    }

    private func workoutRow(_ workout: HKWorkout) -> some View {
        let typeName = HealthHistoryImporter.workoutTypeName(
            workout.workoutActivityType
        )
        let source = workout.sourceRevision.source.name
        let kcal = workout.totalEnergyBurned?.doubleValue(
            for: .kilocalorie()
        ) ?? 0
        let duration = workout.endDate.timeIntervalSince(workout.startDate)
        let massKg = weightLb * 0.45359237
        let estFeet = ClimbMath.feet(kcal: kcal, massKg: massKg)
        let isImporting = importing == workout.uuid

        return Button {
            guard importing == nil else { return }
            importing = workout.uuid
            Task {
                let record: RideRecord?
                if isHRZoneMode {
                    record = await importer.importWorkoutHRZone(
                        workout, maxHR: maxHR
                    )
                } else {
                    record = await importer.importWorkout(
                        workout, massKg: massKg
                    )
                }
                if let record = record {
                    onImport(record)
                }
                importing = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(typeName)
                        .font(.headline)
                    Spacer()
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(HealthHistoryImporter.dateString(workout.startDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Label(
                        HealthHistoryImporter.durationString(duration),
                        systemImage: "clock"
                    )
                    Label("\(Int(kcal)) kcal", systemImage: "flame")
                    if !isHRZoneMode {
                        Label(
                            "\u{2248}\(Int(estFeet)) ft",
                            systemImage: "mountain.2"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isImporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
        .tint(.primary)
        .disabled(isImporting)
    }
}
