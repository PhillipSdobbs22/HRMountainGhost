import Foundation
import Combine

struct Mountain {
    let name: String
    /// Configurable climb distance in feet. Default 1,000.
    let totalGainFt: Double
    static func climb(distanceFt: Double = 1000) -> Mountain {
        Mountain(name: "YourClimb", totalGainFt: distanceFt)
    }
    static let whitney = climb()   // backward compat alias
}

// MARK: - Climb Engines

enum ClimbMode: Int {
    case calorie = 0
    case hrZone = 1
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

enum HRZone: Int, CaseIterable {
    case zone1 = 1   // < 60% max HR
    case zone2 = 2   // 60–70%
    case zone3 = 3   // 70–80%
    case zone4 = 4   // 80–90%
    case zone5 = 5   // 90%+

    /// Climbing rate in feet per minute for this zone.
    var feetPerMin: Double {
        switch self {
        case .zone1: return 3
        case .zone2: return 8
        case .zone3: return 18
        case .zone4: return 30
        case .zone5: return 45
        }
    }

    var label: String {
        switch self {
        case .zone1: return "Recovery"
        case .zone2: return "Easy"
        case .zone3: return "Moderate"
        case .zone4: return "Hard"
        case .zone5: return "Max"
        }
    }

    /// HR range description as percentage of max.
    var rangeLabel: String {
        switch self {
        case .zone1: return "< 60%"
        case .zone2: return "60\u{2013}70%"
        case .zone3: return "70\u{2013}80%"
        case .zone4: return "80\u{2013}90%"
        case .zone5: return "90%+"
        }
    }

    /// Determine the zone for a given HR and max HR.
    static func zone(hr: Double, maxHR: Double) -> HRZone {
        guard maxHR > 0 else { return .zone1 }
        let pct = hr / maxHR
        if pct >= 0.9 { return .zone5 }
        if pct >= 0.8 { return .zone4 }
        if pct >= 0.7 { return .zone3 }
        if pct >= 0.6 { return .zone2 }
        return .zone1
    }
}

// MARK: - Max HR Formulas

enum MaxHRFormula {
    /// Tanaka (2001): 208 − 0.7 × age. Best validated for adults,
    /// especially over 40. Used for males and unspecified sex.
    static func tanaka(age: Int) -> Int {
        Int(208.0 - (0.7 * Double(age)))
    }

    /// Gulati (2010): 206 − 0.88 × age. Developed specifically for
    /// women from a study of 5,437 subjects.
    static func gulati(age: Int) -> Int {
        Int(206.0 - (0.88 * Double(age)))
    }

    /// Pick the right formula based on sex (0 = not set, 1 = male, 2 = female).
    static func calculate(age: Int, sex: Int) -> Int {
        guard age > 0 else { return 0 }
        if sex == 2 { return gulati(age: age) }
        return tanaka(age: age)
    }

    static func formulaName(sex: Int) -> String {
        sex == 2 ? "Gulati" : "Tanaka"
    }
}

// MARK: - View Model

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
    @Published var rpe: Int = 0
    @Published var feeling: String? = nil
    @Published var showRideSummary = false

    // Ghosts (manual + history can run simultaneously)
    @Published var ghosts: [Ghost] = []

    // HR Zone mode state
    @Published var currentZone: HRZone? = nil

    // Sprint / Rest state
    @Published var isSprinting = false
    @Published var sprintTimeRemaining: Double = 0
    @Published var isResting = false
    @Published var restStartTime: Date? = nil
    @Published var sprintCount: Int = 0
    @Published var restCount: Int = 0
    @Published var totalRestTime: TimeInterval = 0

    private(set) var recordedSprintMarkers: [SprintMarker] = []
    private(set) var recordedRestMarkers: [RestMarker] = []
    private var currentRestStartElapsed: TimeInterval = 0
    private var currentRestStartElevation: Double = 0
    private static let sprintDuration: Double = 20.0

    var weightLb: Double = 180 {
        didSet { recomputeTarget() }
    }

    var climbDistanceFt: Double = 1000 {
        didSet { mountain = Mountain.climb(distanceFt: climbDistanceFt) }
    }

    /// Current climb mode: calorie-based or HR-zone-based.
    var climbMode: ClimbMode = .calorie

    /// Effective max HR used for zone calculations.
    var maxHR: Int = 0

    private let reader = HealthReader()
    private var startDate = Date()
    private var targetFt: Double = 0
    private var delaySamples: [Double] = []
    private(set) var mountain = Mountain.climb()

    // Ride recording: sample elevation every 5 seconds.
    private var recordedSamples: [ElevationSample] = []
    private var lastSampleTime: TimeInterval = 0
    private let sampleInterval: TimeInterval = 5.0

    // For accurate HR zone accumulation between ticks.
    private var lastTickDate: Date?

    func requestAccess() async {
        do {
            try await reader.requestAccess()
        } catch {
            statusMessage = "Health access error: \(error.localizedDescription)"
        }
    }

    /// Read age and biological sex from Apple Health.
    /// Returns (age, isFemale) — either may be nil if not available.
    func loadHealthProfile() async -> (age: Int?, isFemale: Bool?) {
        // Re-request access to ensure DOB/sex permissions are included.
        do {
            try await reader.requestAccess()
        } catch {}
        let age = reader.readAge()
        let sex = reader.readBiologicalSex()
        let isFemale: Bool? = sex.map { $0 == 2 }  // 2 = female
        return (age, isFemale)
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
        rpe = 0
        feeling = nil
        showRideSummary = false
        recordedSamples = []
        lastSampleTime = 0
        lastTickDate = nil
        currentZone = nil
        isSprinting = false
        sprintTimeRemaining = 0
        isResting = false
        restStartTime = nil
        sprintCount = 0
        restCount = 0
        totalRestTime = 0
        recordedSprintMarkers = []
        recordedRestMarkers = []
        currentRestStartElapsed = 0
        currentRestStartElevation = 0
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
        currentZone = nil
        isSprinting = false
        sprintTimeRemaining = 0
        if isResting { resumeExercise() }
        // Show summary so the user can adjust RPE before saving.
        if elapsed > 30, targetFt > 0 {
            showRideSummary = true
        }
    }

    /// Called when the user taps SAVE on the ride summary.
    func confirmSave() {
        saveRide()
        showRideSummary = false
    }

    /// Called when the user discards the ride from the summary.
    func discardRide() {
        showRideSummary = false
    }

    /// Called twice a second by the screen.
    func tick() {
        if isRunning {
            let now = Date()
            elapsed = now.timeIntervalSince(startDate)

            // HR Zone climb: accumulate feet based on current zone.
            if climbMode == .hrZone,
               let hr = heartRate, hr > 0, maxHR > 0
            {
                let zone = HRZone.zone(
                    hr: Double(hr), maxHR: Double(maxHR)
                )
                currentZone = zone
                if let lastTick = lastTickDate {
                    let dt = now.timeIntervalSince(lastTick)
                    targetFt += zone.feetPerMin * dt / 60.0
                }
            } else if climbMode == .hrZone {
                currentZone = nil
            }
            lastTickDate = now

            // Sprint countdown.
            if isSprinting {
                sprintTimeRemaining = max(0, sprintTimeRemaining - (lastTickDate.map { now.timeIntervalSince($0) } ?? 0.5))
                if sprintTimeRemaining <= 0 {
                    isSprinting = false
                    sprintTimeRemaining = 0
                }
            }

            // Accumulate rest time while resting.
            if isResting, let restStart = restStartTime {
                totalRestTime += now.timeIntervalSince(restStart)
                restStartTime = now
            }

            // Record elevation sample periodically.
            if elapsed - lastSampleTime >= sampleInterval {
                recordedSamples.append(
                    ElevationSample(elapsed: elapsed, feet: targetFt)
                )
                lastSampleTime = elapsed
            }

            // Update ghost positions.
            for g in ghosts {
                g.update(elapsed: elapsed, mountainGainFt: climbDistanceFt)
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

    // MARK: - Sprint / Rest actions

    /// Rider taps the Sprint button — start a 20-second sprint.
    func startSprint() {
        guard isRunning, !isSprinting, !isResting else { return }
        isSprinting = true
        sprintTimeRemaining = Self.sprintDuration
        sprintCount += 1
        recordedSprintMarkers.append(
            SprintMarker(
                elevationFt: targetFt,
                elapsedStart: elapsed,
                duration: Self.sprintDuration
            )
        )
    }

    /// Rider taps Begin Rest — pause climbing effort and record position.
    func startRest() {
        guard isRunning, !isSprinting, !isResting else { return }
        isResting = true
        restStartTime = Date()
        restCount += 1
        currentRestStartElapsed = elapsed
        currentRestStartElevation = targetFt
    }

    /// Rider taps Resume Exercise — end rest and record the rest marker.
    func resumeExercise() {
        guard isResting else { return }
        let duration = elapsed - currentRestStartElapsed
        recordedRestMarkers.append(
            RestMarker(
                elevationFt: currentRestStartElevation,
                elapsedStart: currentRestStartElapsed,
                duration: duration
            )
        )
        isResting = false
        restStartTime = nil
    }

    /// Current rest duration if actively resting.
    var currentRestDuration: TimeInterval {
        guard isResting else { return 0 }
        return elapsed - currentRestStartElapsed
    }

    // MARK: - Ghost setup

    /// Set a manual ghost with a target pace.
    func setManualGhost(name: String, feetPerMin: Double) {
        removeGhost(where: {
            if case .manual = $0.source { return true }; return false
        })
        ghosts.append(Ghost(name: name, feetPerMin: feetPerMin))
    }

    /// Set a ghost from a saved ride (or best pace).
    func setHistoryGhost(_ record: RideRecord) {
        removeGhost(where: {
            if case .history = $0.source { return true }; return false
        })
        ghosts.append(Ghost(record: record))
    }

    /// Set a ghost from the best pace in ride history.
    func setBestPaceGhost() {
        guard let best = RideStore.shared.rides.max(by: {
            $0.avgFeetPerMin < $1.avgFeetPerMin
        }) else { return }
        removeGhost(where: {
            if case .history = $0.source { return true }; return false
        })
        let g = Ghost(record: best)
        ghosts.append(g)
    }

    /// Remove the manual ghost.
    func clearManualGhost() {
        removeGhost(where: {
            if case .manual = $0.source { return true }; return false
        })
    }

    /// Remove the history ghost.
    func clearHistoryGhost() {
        removeGhost(where: {
            if case .history = $0.source { return true }; return false
        })
    }

    /// Remove all ghosts.
    func clearAllGhosts() {
        ghosts.removeAll()
    }

    /// The current manual ghost, if any.
    var manualGhost: Ghost? {
        ghosts.first(where: {
            if case .manual = $0.source { return true }; return false
        })
    }

    /// The current history ghost, if any.
    var historyGhost: Ghost? {
        ghosts.first(where: {
            if case .history = $0.source { return true }; return false
        })
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
        if climbMode == .calorie {
            recomputeTarget()
        }
    }

    private func recomputeTarget() {
        if climbMode == .calorie {
            targetFt = ClimbMath.feet(
                kcal: activeKcal, massKg: weightLb * 0.45359237
            )
        }
        // In HR zone mode, targetFt is accumulated in tick().
    }

    private func saveRide() {
        // Only save rides longer than 30 seconds with some elevation.
        guard elapsed > 30, targetFt > 0 else { return }

        // Close any open rest period before saving.
        if isResting { resumeExercise() }

        // Add a final sample at the end.
        recordedSamples.append(
            ElevationSample(elapsed: elapsed, feet: targetFt)
        )

        var record = RideRecord(
            id: UUID(),
            date: startDate,
            mountainName: mountain.name,
            mountainGainFt: mountain.totalGainFt,
            duration: elapsed,
            activeKcal: activeKcal,
            peakFeet: targetFt,
            samples: recordedSamples
        )
        record.rpe = rpe
        record.feeling = feeling
        record.sprintMarkers = recordedSprintMarkers.isEmpty ? nil : recordedSprintMarkers
        record.restMarkers = recordedRestMarkers.isEmpty ? nil : recordedRestMarkers
        RideStore.shared.save(record)
    }
}
