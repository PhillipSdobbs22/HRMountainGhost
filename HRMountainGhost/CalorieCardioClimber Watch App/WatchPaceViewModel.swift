//
//  WatchPaceViewModel.swift
//  CalorieCardioClimber Watch App
//
//  Standalone ViewModel for PaceGauge on Apple Watch.
//  Manages HKWorkoutSession (HR), CoreLocation (speed),
//  and avg speed — no iPhone required. Battery-optimized.
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

    // MARK: - Gauge Settings (user-adjustable before start)

    @Published var tortoisePace: Double = 2.5   // mph
    @Published var harePace: Double = 5.0       // mph
    @Published var goalPace: Double = 3.5       // mph
    let gaugeMax: Double = 8.0                  // mph

    // MARK: - Private

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var hrQuery: HKAnchoredObjectQuery?
    private let locationManager = CLLocationManager()

    private var startDate: Date?
    private var totalDistanceMeters: Double = 0
    private var lastLocation: CLLocation?
    private var lastGPSUpdate: Date?
    private var staleTimer: Timer?
    private var clockTimer: Timer?
    private var pausedElapsed: TimeInterval = 0
    private var pauseDate: Date?

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

        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        let share: Set<HKSampleType> = [HKWorkoutType.workoutType()]

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
        guard workoutSession == nil else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(
                healthStore: healthStore, configuration: config)
            session.delegate = self
            session.startActivity(with: Date())
            workoutSession = session
        } catch {
            print("[WatchPace] Workout start error: \(error)")
            return
        }

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

        startHeartRateQuery()
        locationManager.startUpdatingLocation()
        startClockTimer()

        // 3-second watchdog: zero out speed if GPS goes stale
        staleTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkStaleGPS() }
        }
    }

    // MARK: - Pause (STOP button pressed)

    func pause() {
        staleTimer?.invalidate()
        staleTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        locationManager.stopUpdatingLocation()
        workoutSession?.pause()
        pauseDate = Date()
        currentSpeedMPH = 0
        isPaused = true
    }

    // MARK: - Resume

    func resume() {
        // Accumulate paused time so avg speed stays accurate
        if let pd = pauseDate {
            pausedElapsed += Date().timeIntervalSince(pd)
            pauseDate = nil
        }
        lastLocation = nil   // discard stale location
        lastGPSUpdate = nil
        workoutSession?.resume()
        locationManager.startUpdatingLocation()

        staleTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkStaleGPS() }
        }

        startClockTimer()
        isPaused = false
    }

    // MARK: - Save (end workout, show summary)

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

        if let q = hrQuery {
            healthStore.stop(q)
            hrQuery = nil
        }

        locationManager.stopUpdatingLocation()

        workoutSession?.end()
        workoutSession = nil

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
            Task { @MainActor in self?.tickClock() }
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

    // MARK: - Heart Rate Query

    private func startHeartRateQuery() {
        let hrType = HKQuantityType(.heartRate)
        let pred = HKQuery.predicateForSamples(
            withStart: Date(), end: nil, options: .strictStartDate)

        let query = HKAnchoredObjectQuery(
            type: hrType, predicate: pred,
            anchor: nil, limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.processHR(samples)
        }

        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.processHR(samples)
        }

        hrQuery = query
        healthStore.execute(query)
    }

    nonisolated private func processHR(_ samples: [HKSample]?) {
        guard let qs = samples as? [HKQuantitySample],
              let latest = qs.last else { return }

        let bpm = latest.quantity.doubleValue(
            for: HKUnit.count().unitDivided(by: .minute()))

        Task { @MainActor in
            self.heartRate = bpm
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchPaceViewModel: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let loc = locations.last,
              loc.horizontalAccuracy >= 0,
              loc.horizontalAccuracy < 30 else { return }

        Task { @MainActor in
            self.lastGPSUpdate = Date()

            let speedMS = max(0, loc.speed)
            self.currentSpeedMPH = speedMS * 2.23694

            if let last = self.lastLocation {
                let delta = loc.distance(from: last)
                if delta < 100 {
                    self.totalDistanceMeters += delta
                }
            }
            self.lastLocation = loc

            if let start = self.startDate {
                let elapsed = Date().timeIntervalSince(start)
                                     - self.pausedElapsed
                if elapsed > 0 {
                    self.avgSpeedMPH =
                        (self.totalDistanceMeters / elapsed) * 2.23694
                }
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("[WatchPace] Location error: \(error)")
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchPaceViewModel: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ session: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(
        _ session: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("[WatchPace] Workout error: \(error)")
        Task { @MainActor in self.save() }
    }
}
