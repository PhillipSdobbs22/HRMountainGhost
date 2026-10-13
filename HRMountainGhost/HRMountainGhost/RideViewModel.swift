import Foundation
import Combine

struct Mountain {
    let name: String
    /// Approximate trailhead-to-summit gain. Verify before relying on it.
    let totalGainFt: Double
    static let whitney = Mountain(name: "Mt Whitney", totalGainFt: 6100)
}

enum ClimbMath {
    /// Fraction of food energy turned into mechanical work on a bike (about 22%).
    static let efficiency = 0.22

    /// Vertical feet climbed for a given amount of active kilocalories.
    static func feet(kcal: Double, massKg: Double) -> Double {
        guard massKg > 0 else { return 0 }
        let joules = kcal * 4184.0
        let meters = joules * efficiency / (massKg * 9.81)
        return meters * 3.28084
    }
}

@MainActor
final class RideViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var elapsed: TimeInterval = 0
    @Published var heartRate: Int? = nil
    @Published var activeKcal: Double = 0
    @Published var displayedFt: Double = 0
    @Published var lastDelay: Double? = nil
    @Published var avgDelay: Double? = nil
    @Published var statusMessage: String = ""

    // Ghosts (manual + history can run simultaneously)
    @Published var ghosts: [Ghost] = []

    var weightLb: Double = 180 {
        didSet { recomputeTarget() }
    }

    private let reader = HealthReader()
    private var startDate = Date()
    private var targetFt: Double = 0
    private var delaySamples: [Double] = []
    private let mountain = Mountain.whitney

    // Ride recording: sample elevation every 5 seconds.
    private var recordedSamples: [ElevationSample] = []
    private var lastSampleTime: TimeInterval = 0
    private let sampleInterval: TimeInterval = 5.0

    func requestAccess() async {
        do {
            try await reader.requestAccess()
        } catch {
            statusMessage = "Health access error: \(error.localizedDescription)"
        }
    }

    func start(weightLb: Double) {
        self.weightLb = weightLb
        startDate = Date()
        elapsed = 0
        heartRate = nil
        activeKcal = 0
        displayedFt = 0
        targetFt = 0
        lastDelay = nil
        avgDelay = nil
        delaySamples = []
        recordedSamples = []
        lastSampleTime = 0
        for g in ghosts { g.reset() }
        isRunning = true

        reader.onHeartRate = { [weak self] bpm, date in
            Task { @MainActor in self?.receiveHeartRate(bpm, date) }
        }
        reader.onEnergy = { [weak self] kcal, date in
            Task { @MainActor in self?.receiveEnergy(kcal, date) }
        }
        reader.onError = { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }
        reader.start(from: startDate)
    }

    func stop() {
        reader.stop()
        isRunning = false
        saveRide()
    }

    /// Called twice a second by the screen.
    func tick() {
        if isRunning {
            elapsed = Date().timeIntervalSince(startDate)

            // Record elevation sample periodically.
            if elapsed - lastSampleTime >= sampleInterval {
                recordedSamples.append(ElevationSample(elapsed: elapsed, feet: targetFt))
                lastSampleTime = elapsed
            }

            // Update ghost positions.
            for g in ghosts {
                g.update(elapsed: elapsed, mountainGainFt: mountain.totalGainFt)
            }
        }

        // Ease the shown climb toward the target so calorie jumps look smooth.
        let diff = targetFt - displayedFt
        if abs(diff) < 0.5 {
            displayedFt = targetFt
        } else {
            displayedFt += diff * 0.25
        }
    }

    // MARK: - Ghost setup

    /// Set a manual ghost with a target pace.
    func setManualGhost(name: String, feetPerMin: Double) {
        removeGhost(where: { if case .manual = $0.source { return true }; return false })
        ghosts.append(Ghost(name: name, feetPerMin: feetPerMin))
    }

    /// Set a ghost from a saved ride (or best pace).
    func setHistoryGhost(_ record: RideRecord) {
        removeGhost(where: { if case .history = $0.source { return true }; return false })
        ghosts.append(Ghost(record: record))
    }

    /// Set a ghost from the best pace in ride history.
    func setBestPaceGhost() {
        guard let best = RideStore.shared.rides.max(by: { $0.avgFeetPerMin < $1.avgFeetPerMin }) else { return }
        removeGhost(where: { if case .history = $0.source { return true }; return false })
        let g = Ghost(record: best)
        ghosts.append(g)
    }

    /// Remove the manual ghost.
    func clearManualGhost() {
        removeGhost(where: { if case .manual = $0.source { return true }; return false })
    }

    /// Remove the history ghost.
    func clearHistoryGhost() {
        removeGhost(where: { if case .history = $0.source { return true }; return false })
    }

    /// Remove all ghosts.
    func clearAllGhosts() {
        ghosts.removeAll()
    }

    /// The current manual ghost, if any.
    var manualGhost: Ghost? {
        ghosts.first(where: { if case .manual = $0.source { return true }; return false })
    }

    /// The current history ghost, if any.
    var historyGhost: Ghost? {
        ghosts.first(where: { if case .history = $0.source { return true }; return false })
    }

    private func removeGhost(where pred: (Ghost) -> Bool) {
        ghosts.removeAll(where: pred)
    }

    // MARK: - Private

    private func receiveHeartRate(_ bpm: Double, _ sampleDate: Date) {
        heartRate = Int(bpm.rounded())
        let delay = max(0, Date().timeIntervalSince(sampleDate))
        lastDelay = delay
        delaySamples.append(delay)
        avgDelay = delaySamples.reduce(0, +) / Double(delaySamples.count)
    }

    private func receiveEnergy(_ kcal: Double, _ sampleDate: Date) {
        activeKcal += kcal
        recomputeTarget()
    }

    private func recomputeTarget() {
        targetFt = ClimbMath.feet(kcal: activeKcal, massKg: weightLb * 0.45359237)
    }

    private func saveRide() {
        // Only save rides longer than 30 seconds with some elevation.
        guard elapsed > 30, targetFt > 0 else { return }

        // Add a final sample at the end.
        recordedSamples.append(ElevationSample(elapsed: elapsed, feet: targetFt))

        let record = RideRecord(
            id: UUID(),
            date: startDate,
            mountainName: mountain.name,
            mountainGainFt: mountain.totalGainFt,
            duration: elapsed,
            activeKcal: activeKcal,
            peakFeet: targetFt,
            samples: recordedSamples
        )
        RideStore.shared.save(record)
    }
}
