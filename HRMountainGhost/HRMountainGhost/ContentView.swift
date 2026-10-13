import SwiftUI
import UIKit
import Combine

struct ContentView: View {
    @StateObject private var vm = RideViewModel()
    @AppStorage("bodyWeightLb") private var weightLb: Double = 180
    @State private var showSettings = false

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let mountain = Mountain.whitney
    private let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
    private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)

    private var progress: Double {
        min(max(vm.displayedFt / mountain.totalGainFt, 0), 1)
    }

    var body: some View {
        ZStack {
            navy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    progressBar
                    tiles
                    ForEach(vm.ghosts) { ghost in
                        ghostRow(ghost)
                    }
                    delayCard
                    Text("MOUNTAIN PROFILE")
                        .font(.footnote.bold())
                        .foregroundStyle(yellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProfileStrip(
                        progress: progress,
                        ghosts: vm.ghosts.map { g in
                            let isManual: Bool = { if case .manual = g.source { return true }; return false }()
                            return GhostDot(progress: min(max(g.currentFeet / mountain.totalGainFt, 0), 1), name: g.name, isManual: isManual)
                        },
                        accent: yellow
                    )
                    if !vm.ghosts.isEmpty {
                        GhostRadar(
                            userFeet: vm.displayedFt,
                            ghosts: vm.ghosts
                        )
                    }
                    controls
                    if !vm.isRunning { instructions }
                    if !vm.statusMessage.isEmpty {
                        Text(vm.statusMessage).font(.footnote).foregroundStyle(.white)
                    }
                }
                .padding()
            }
        }
        .preferredColorScheme(.dark)
        .task { await vm.requestAccess() }
        .onReceive(timer) { _ in vm.tick() }
        .onChange(of: vm.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: weightLb) { _, newValue in
            vm.weightLb = newValue
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(weightLb: $weightLb, vm: vm)
        }
    }

    private var header: some View {
        HStack {
            Text(mountain.name).font(.title2.bold())
            Spacer()
            Text("\(Int(vm.displayedFt)) / \(Int(mountain.totalGainFt)) ft").font(.title3.bold())
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
            Tile(value: vm.heartRate.map { String($0) } ?? "--", label: "HR bpm")
            Tile(value: String(Int(vm.activeKcal)), label: "Active kcal")
            Tile(value: timeString(vm.elapsed), label: "Ride time")
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

    private var delayText: String {
        if let last = vm.lastDelay, let avg = vm.avgDelay {
            return "Newest heart rate sample was \(Int(last)) s old (average \(Int(avg)) s)."
        }
        return vm.isRunning
            ? "Waiting for Health data. Make sure the Watch workout is running."
            : "The delay between your Watch and this screen shows here during a ride."
    }

    private var delayCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DATA DELAY TEST").font(.caption.bold())
            Text(delayText).font(.subheadline)
        }
        .foregroundStyle(navy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(yellow)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                if vm.isRunning { vm.stop() } else { vm.start(weightLb: weightLb) }
            } label: {
                Text(vm.isRunning ? "Stop ride" : "Start ride")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white)
                    .foregroundStyle(navy)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.headline)
                    .padding()
                    .background(Color.white)
                    .foregroundStyle(navy)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var instructions: some View {
        Text("1. On your Watch, start the Indoor Cycle workout.\n2. Tap Start ride here at the same moment.\n3. Pedal. Climb is counted from calories after you tap Start ride.")
            .font(.footnote)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Tile

struct Tile: View {
    let value: String
    let label: String
    var bgColor: Color = .white

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label).font(.caption)
        }
        .foregroundStyle(Color(red: 0.043, green: 0.071, blue: 0.125))
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

struct ProfileStrip: View {
    let progress: Double
    let ghosts: [GhostDot]
    let accent: Color

    private let manualColor = Color(red: 0.6, green: 0.85, blue: 1.0)   // light blue
    private let historyColor = Color(red: 1.0, green: 0.6, blue: 0.4)   // orange

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
                // Mountain fill
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    for pt in pts { p.addLine(to: CGPoint(x: pt.x * sx, y: pt.y * sy)) }
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.2, green: 0.255, blue: 0.361))

                // User trail
                Path { p in
                    p.move(to: CGPoint(x: 0, y: pts[0].y * sy))
                    for pt in pts where pt.x < cx { p.addLine(to: CGPoint(x: pt.x * sx, y: pt.y * sy)) }
                    p.addLine(to: CGPoint(x: cx * sx, y: yAt(cx) * sy))
                }
                .stroke(accent, lineWidth: 4)

                // User dot
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .position(x: cx * sx, y: yAt(cx) * sy)

                // Ghost dots
                ForEach(Array(ghosts.enumerated()), id: \.offset) { _, ghost in
                    let gx = CGFloat(ghost.progress) * 358
                    let color = ghost.isManual ? manualColor : historyColor
                    let emoji = ghost.isManual ? "\u{1F47B}" : "\u{1F3C6}"
                    Circle()
                        .fill(color)
                        .opacity(0.85)
                        .frame(width: 12, height: 12)
                        .position(x: gx * sx, y: yAt(gx) * sy)

                    Text(emoji)
                        .font(.system(size: 10))
                        .position(x: gx * sx, y: yAt(gx) * sy - 12)
                }
            }
        }
        .frame(height: 90)
    }
}

// MARK: - Ghost Radar

struct GhostRadar: View {
    let userFeet: Double
    let ghosts: [Ghost]

    /// Half the visible window in feet. Total window = 300 ft.
    private let halfRange: Double = 150

    private let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
    private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)
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

                    ForEach([-100, -50, 50, 100], id: \.self) { offset in
                        let frac = Double(offset) / halfRange
                        let x = midX + CGFloat(frac) * midX
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 1, height: barH * 0.4)
                            .position(x: x, y: barH / 2)
                    }

                    // Ghost indicators
                    ForEach(Array(ghosts.enumerated()), id: \.offset) { idx, ghost in
                        let gap = userFeet - ghost.currentFeet
                        let raw = -gap / halfRange
                        let clamped = min(max(raw, -1.0), 1.0)
                        let inRange = abs(gap) <= halfRange
                        let color = ghostColors[idx % ghostColors.count]
                        let isManual: Bool = {
                            if case .manual = ghost.source { return true }
                            return false
                        }()
                        let emoji = isManual ? "\u{1F47B}" : "\u{1F3C6}"

                        if inRange {
                            let gx = midX + CGFloat(clamped) * midX
                            VStack(spacing: 0) {
                                Text(emoji)
                                    .font(.system(size: 14))
                                Text("\(Int(abs(gap))) ft")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(color)
                            }
                            .position(x: gx, y: barH / 2)
                        } else {
                            let isAhead = gap < 0
                            let edgeX = isAhead ? geo.size.width - 16 : CGFloat(16)
                            let arrow = isAhead ? "\u{25B6}" : "\u{25C0}"

                            VStack(spacing: 0) {
                                HStack(spacing: 2) {
                                    Text(emoji)
                                        .font(.system(size: 12))
                                    Text(arrow)
                                        .font(.system(size: 8))
                                        .foregroundStyle(color)
                                }
                                Text("\(Int(abs(gap))) ft")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(color)
                            }
                            .position(x: edgeX, y: barH / 2)
                        }
                    }

                    Text("YOU")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(yellow)
                        .position(x: midX, y: barH - 6)
                }
            }
            .frame(height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var weightLb: Double
    @ObservedObject var vm: RideViewModel
    @Environment(\.dismiss) private var dismiss

    // Manual ghost state
    @State private var manualEnabled = false
    @State private var ghostName = "Ghost"
    @State private var ghostPace: Double = 10

    // History ghost state
    @State private var historyEnabled = false
    @State private var historyMode = 0  // 0 = best pace, 1 = pick ride
    @State private var showHistory = false

    private let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
    private let yellow = Color(red: 1.0, green: 0.831, blue: 0.0)

    var body: some View {
        NavigationStack {
            Form {
                Section("Body weight") {
                    TextField("Pounds", value: $weightLb, format: .number)
                        .keyboardType(.decimalPad)
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
                        Text("A pace of 10 ft/min finishes Mt Whitney (~6,100 ft) in about 10 hours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("History Ghost \u{1F3C6}") {
                    Toggle("Enable history ghost", isOn: $historyEnabled)

                    if historyEnabled {
                        Picker("Source", selection: $historyMode) {
                            Text("Best pace").tag(0)
                            Text("Pick a ride").tag(1)
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

                Section {
                    Text("Both ghosts can run at the same time. Manual ghost uses a constant pace; history ghost replays a recorded ride.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") {
                    applyGhosts()
                    dismiss()
                }
            }
            .sheet(isPresented: $showHistory) {
                RideHistoryView(vm: vm, onSelect: { record in
                    vm.setHistoryGhost(record)
                    historyMode = 1
                    showHistory = false
                })
            }
            .onAppear {
                // Populate from current ghost state
                if let g = vm.manualGhost {
                    manualEnabled = true
                    if case .manual(let fpm, let name) = g.source {
                        ghostName = name
                        ghostPace = fpm
                    }
                }
                if vm.historyGhost != nil {
                    historyEnabled = true
                    historyMode = 1
                }
            }
        }
    }

    private func applyGhosts() {
        // Manual ghost
        if manualEnabled {
            vm.setManualGhost(name: ghostName, feetPerMin: ghostPace)
        } else {
            vm.clearManualGhost()
        }

        // History ghost
        if historyEnabled {
            if historyMode == 0 {
                vm.setBestPaceGhost()
            }
            // historyMode == 1 already set via sheet selection
        } else {
            vm.clearHistoryGhost()
        }
    }
}

// MARK: - Ride History

struct RideHistoryView: View {
    @ObservedObject var vm: RideViewModel
    let onSelect: (RideRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    private let navy = Color(red: 0.043, green: 0.071, blue: 0.125)

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
                                    Text("\(String(format: "%.1f", ride.avgFeetPerMin)) ft/min avg")
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
            .navigationTitle("Ride History")
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
