//
//  WatchPaceViewModel.swift
//  CalorieCardioClimber Watch App
//
//  ViewModel for PaceGauge on Apple Watch.
//  Owns its own HKWorkoutSession so this app gets wrist-raise
//  priority — no need to run Apple's Workout app alongside it.
//  Records HR, GPS route, distance, speed, and calories;
//  saves the completed workout to Apple Health.
//

import Foundation
import Combine
import HealthKit
import CoreLocation

@MainActor
final class WatchPaceViewModel: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var heartRate: Double = 0
    @Published var currentSpeedMPH: Double = 0
    @Published var avgSpeedMPH: Double = 0
    @Published var isActive = false
    @Published var isPaused = false
    @Published var showSummary = false
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var activeCalories: Double = 0
    @Published var totalDistanceMiles: Double = 0

    // MARK: - Gauge Settings (user-adjustable before start)

    @Published var tortoisePace: Double = 3.0   // mph
    @Published var harePace: Double = 6.0       // mph
    @Published var goalPace: Double = 5.0       // mph
    let gaugeMax: Double = 8.0                  // mph

    // MARK: - HR Zone Settings

    @Published var maxHR: Double = 173          // user-adjustable max heart rate

    // MARK: - Workout Config

    /// Set to false for indoor (no GPS). Default true for outdoor GPS speed.
    @Published var isOutdoor: Bool = true

    // MARK: - Private — Workout

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?

    // MARK: - Private — Location

    private let locationManager = CLLocationManager()
    private var startDate: Date?
    private var totalDistanceMeters: Double = 0
    private var lastLocation: CLLocation?
    private var lastGPSUpdate: Date?
    private var staleTimer: Timer?
    private var clockTimer: Timer?
    private var pausedElapsed: TimeInterval = 0
    private var pauseDate: Date?
    private var routeLocations: [CLLocation] = []

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling)
        ]

        let share: Set<HKSampleType> = [
            HKWorkoutType.workoutType(),
            HKSeriesType.workoutRoute()
        ]

        do {
            try await healthStore.requestAuthorization(
                toShare: share, read: read)
        } catch {
            print("[WatchPace] HK auth error: \(error)")
        }

        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Start

    func start() {
        guard !isActive else { return }

        startDate = Date()
        isActive = true
        showSummary = false

        totalDistanceMeters = 0
        lastLocation = nil
        lastGPSUpdate = nil
        pausedElapsed = 0
        pauseDate = nil
        heartRate = 0
        currentSpeedMPH = 0
        avgSpeedMPH = 0
        elapsedSeconds = 0
        activeCalories = 0
        totalDistanceMiles = 0
        routeLocations = []

        startWorkoutSession()

        if isOutdoor {
            locationManager.startUpdatingLocation()
            staleTimer = Timer.scheduledTimer(
                withTimeInterval: 6.0, repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkStaleGPS() }
            }
        }

        startClockTimer()
    }

    // MARK: - Workout Session (owns the session → wrist-raise priority)

    private func startWorkoutSession() {
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = isOutdoor ? .outdoor : .indoor

        do {
            let ws = try HKWorkoutSession(
                healthStore: healthStore, configuration: config)
            ws.delegate = self

            let wb = ws.associatedWorkoutBuilder()
            wb.delegate = self
            wb.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config)

            session = ws
            builder = wb

            // Start the session — this makes us the frontmost workout app
            ws.startActivity(with: Date())

            Task {
                do {
                    try await wb.beginCollection(at: Date())
                } catch {
                    print("[WatchPace] Builder begin error: \(error)")
                }
            }

            // Route builder for GPS track (outdoor only)
            if isOutdoor {
                routeBuilder = HKWorkoutRouteBuilder(
                    healthStore: healthStore, device: nil)
            }

        } catch {
            print("[WatchPace] Session start error: \(error)")
        }
    }

    // MARK: - Pause (STOP button pressed)

    func pause() {
        session?.pause()

        staleTimer?.invalidate()
        staleTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        locationManager.stopUpdatingLocation()
        pauseDate = Date()
        currentSpeedMPH = 0
        isPaused = true
    }

    // MARK: - Resume

    func resume() {
        session?.resume()

        // Accumulate paused time so avg speed stays accurate
        if let pd = pauseDate {
            pausedElapsed += Date().timeIntervalSince(pd)
            pauseDate = nil
        }
        lastLocation = nil   // discard stale location
        lastGPSUpdate = nil

        if isOutdoor {
            locationManager.startUpdatingLocation()
            staleTimer = Timer.scheduledTimer(
                withTimeInterval: 6.0, repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkStaleGPS() }
            }
        }

        startClockTimer()
        isPaused = false
    }

    // MARK: - Save (end workout, write to Apple Health, show summary)

    func save() {
        // Accumulate any remaining paused time
        if let pd = pauseDate {
            pausedElapsed += Date().timeIntervalSince(pd)
            pauseDate = nil
        }

        staleTimer?.invalidate()
        staleTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        locationManager.stopUpdatingLocation()

        // End the workout session
        session?.end()

        Task {
            await finishAndSaveWorkout()
        }
    }

    private func finishAndSaveWorkout() async {
        guard let builder = builder else {
            isActive = false
            isPaused = false
            showSummary = true
            return
        }

        do {
            try await builder.endCollection(at: Date())
            let workout = try await builder.finishWorkout()

            // Attach the GPS route to the saved workout
            if let routeBuilder = routeBuilder,
               !routeLocations.isEmpty,
               let workout = workout {
                try await routeBuilder.finishRoute(
                    with: workout, metadata: nil)
            }

            print("[WatchPace] Workout saved to Apple Health")
        } catch {
            print("[WatchPace] Save error: \(error)")
        }

        // Clean up
        session = nil
        self.builder = nil
        routeBuilder = nil

        isActive = false
        isPaused = false
        showSummary = true
    }

    func dismissSummary() {
        showSummary = false
    }

    // MARK: - Formatted Elapsed Time

    var elapsedFormatted: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    private func startClockTimer() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickClock() }
        }
    }

    private func tickClock() {
        guard let start = startDate else { return }
        elapsedSeconds = Date().timeIntervalSince(start) - pausedElapsed
    }

    // MARK: - Stale GPS Check

    private func checkStaleGPS() {
        guard let last = lastGPSUpdate else { return }
        if Date().timeIntervalSince(last) > 3.0 {
            currentSpeedMPH = 0
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchPaceViewModel: HKWorkoutSessionDelegate {

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // State changes handled by pause()/resume()/save()
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("[WatchPace] Session error: \(error)")
        self.save()
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchPaceViewModel: HKLiveWorkoutBuilderDelegate {

    func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {
        // Pause/resume markers collected automatically
    }

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        for type in collectedTypes {
            guard let qType = type as? HKQuantityType else { continue }

            // Heart rate — from the workout builder (no separate query needed)
            if qType == HKQuantityType(.heartRate) {
                let stats = workoutBuilder.statistics(for: qType)
                let unit = HKUnit.count().unitDivided(by: .minute())
                if let bpm = stats?.mostRecentQuantity()?
                    .doubleValue(for: unit) {
                    self.heartRate = bpm
                }
            }

            // Active calories
            if qType == HKQuantityType(.activeEnergyBurned) {
                let stats = workoutBuilder.statistics(for: qType)
                let unit = HKUnit.kilocalorie()
                if let kcal = stats?.sumQuantity()?
                    .doubleValue(for: unit) {
                    self.activeCalories = kcal
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchPaceViewModel: CLLocationManagerDelegate {

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let loc = locations.last,
              loc.horizontalAccuracy >= 0,
              loc.horizontalAccuracy < 30 else { return }

        lastGPSUpdate = Date()

        let speedMS = max(0, loc.speed)
        currentSpeedMPH = speedMS * 2.23694

        if let last = lastLocation {
            let delta = loc.distance(from: last)
            if delta < 100 {
                totalDistanceMeters += delta
            }
        }
        lastLocation = loc

        // Update published distance in miles
        totalDistanceMiles = totalDistanceMeters / 1609.344

        if let start = startDate {
            let elapsed = Date().timeIntervalSince(start)
                - pausedElapsed
            if elapsed > 0 {
                avgSpeedMPH =
                    (totalDistanceMeters / elapsed) * 2.23694
            }
        }

        // Feed location to route builder for Apple Health
        routeLocations.append(loc)
        routeBuilder?.insertRouteData([loc]) { _, error in
            if let error {
                print("[WatchPace] Route insert error: \(error)")
            }
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("[WatchPace] Location error: \(error)")
    }
}
