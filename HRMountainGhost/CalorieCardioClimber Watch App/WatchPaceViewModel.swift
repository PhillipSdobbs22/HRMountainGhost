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
    @Published var showSummary = false

    // MARK: - Gauge Settings (user-adjustable before start)

    @Published var tortoisePace: Double = 2.5   // mph
    @Published var harePace: Double = 5.0       // mph
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
        heartRate = 0
        currentSpeedMPH = 0
        avgSpeedMPH = 0

        startHeartRateQuery()
        locationManager.startUpdatingLocation()

        // 3-second watchdog: zero out speed if GPS goes stale
        staleTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkStaleGPS() }
        }
    }

    // MARK: - Stop

    func stop() {
        staleTimer?.invalidate()
        staleTimer = nil

        if let q = hrQuery {
            healthStore.stop(q)
            hrQuery = nil
        }

        locationManager.stopUpdatingLocation()

        workoutSession?.end()
        workoutSession = nil

        isActive = false
        showSummary = true
    }

    func dismissSummary() {
        showSummary = false
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
        Task { @MainActor in self.stop() }
    }
}
