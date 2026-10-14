import Foundation
import HealthKit

/// Reads live heart rate and active calories from Apple Health.
///
/// Uses three layers to get Watch data reliably:
/// 1. HKObserverQuery — registers interest so HealthKit syncs from the Watch
/// 2. enableBackgroundDelivery — tells HealthKit to deliver updates frequently
/// 3. Polling every 5s via GCD timer — fallback that doesn't depend on RunLoop
nonisolated final class HealthReader: @unchecked Sendable {
    private let store = HKHealthStore()
    private var observerQueries: [HKQuery] = []
    private var pollTimer: DispatchSourceTimer?
    private var startDate: Date?
    private var lastHRDate: Date?
    private var processedEnergySamples: Set<String> = []

    var onHeartRate: (@Sendable (Double, Date) -> Void)?
    var onEnergy: (@Sendable (Double, Date) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex),
            HKWorkoutType.workoutType()
        ]
        try await store.requestAuthorization(toShare: [], read: readTypes)

        // Tell HealthKit we want frequent delivery — encourages Watch sync
        store.enableBackgroundDelivery(
            for: HKQuantityType(.heartRate),
            frequency: .immediate
        ) { _, error in
            if let error = error {
                print("BG delivery HR error: \(error.localizedDescription)")
            }
        }
        store.enableBackgroundDelivery(
            for: HKQuantityType(.activeEnergyBurned),
            frequency: .immediate
        ) { _, error in
            if let error = error {
                print("BG delivery energy error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Profile reads (characteristic types — no query needed)

    /// Read the user's age from their date of birth in Apple Health.
    /// Returns nil if DOB is not set or access was denied.
    func readAge() -> Int? {
        do {
            let dob = try store.dateOfBirthComponents()
            guard let dobDate = Calendar.current.date(from: dob) else {
                return nil
            }
            let age = Calendar.current.dateComponents(
                [.year], from: dobDate, to: Date()
            ).year
            return age
        } catch {
            return nil
        }
    }

    /// Read the user's biological sex from Apple Health.
    /// Returns raw value: 1 = male, 2 = female, 3 = other. Nil if not set.
    func readBiologicalSex() -> Int? {
        do {
            let sex = try store.biologicalSex().biologicalSex
            switch sex {
            case .male:   return 1
            case .female: return 2
            case .other:  return 3
            default:      return nil  // .notSet
            }
        } catch {
            return nil
        }
    }

    // MARK: - Workout history for auto ghost pace

    /// Query Apple Health for workouts in the last 42 days and calculate
    /// the average climbing pace (ft/min) using calorie-based conversion.
    /// Returns nil if no workouts found or HealthKit is unavailable.
    func averagePaceLast42Days(bodyMassKg: Double = 81.6) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -42, to: Date()) else {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )

        // Fetch workouts from the last 42 days
        let workouts: [HKWorkout]? = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: 200,
                sortDescriptors: [sortByDate]
            ) { _, samples, error in
                if let error = error {
                    print("Auto ghost workout query error: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: samples as? [HKWorkout])
            }
            store.execute(query)
        }

        guard let workouts = workouts, !workouts.isEmpty else { return nil }

        // Calculate average pace across all workouts
        // Use active calories and duration to derive ft/min
        var totalFeet: Double = 0
        var totalMinutes: Double = 0

        for workout in workouts {
            let kcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie()) ?? 0

            let durationMin = workout.duration / 60.0
            guard durationMin > 0 else { continue }

            if kcal > 0 {
                // Convert calories to feet using ClimbMath
                let feet = ClimbMath.feet(kcal: kcal, massKg: bodyMassKg)
                totalFeet += feet
                totalMinutes += durationMin
            }
        }

        guard totalMinutes > 0, totalFeet > 0 else { return nil }
        return totalFeet / totalMinutes
    }

    // MARK: - Live monitoring

    func start(from date: Date) {
        stop()
        startDate = date
        lastHRDate = nil
        processedEnergySamples = []

        // 1. Observer queries — register interest so HealthKit pulls from Watch
        let hrObserver = HKObserverQuery(
            sampleType: HKQuantityType(.heartRate),
            predicate: nil
        ) { [weak self] _, completionHandler, error in
            if let error = error {
                self?.onError?("HR observer error: \(error.localizedDescription)")
            }
            self?.pollHeartRate()
            completionHandler()
        }

        let energyObserver = HKObserverQuery(
            sampleType: HKQuantityType(.activeEnergyBurned),
            predicate: nil
        ) { [weak self] _, completionHandler, error in
            if let error = error {
                self?.onError?("Energy observer error: \(error.localizedDescription)")
            }
            self?.pollEnergy()
            completionHandler()
        }

        observerQueries = [hrObserver, energyObserver]
        observerQueries.forEach { store.execute($0) }

        // 2. GCD timer polls every 5s as a reliable fallback
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.pollHeartRate()
            self?.pollEnergy()
        }
        timer.resume()
        pollTimer = timer

        // 3. Immediate first poll
        pollHeartRate()
        pollEnergy()
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        observerQueries.forEach { store.stop($0) }
        observerQueries.removeAll()
    }

    // MARK: - Polling

    private func pollHeartRate() {
        guard let startDate = startDate else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate, end: nil, options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate, ascending: false
        )
        let query = HKSampleQuery(
            sampleType: HKQuantityType(.heartRate),
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sortByDate]
        ) { [weak self] _, samples, error in
            if let error = error {
                self?.onError?("HR poll error: \(error.localizedDescription)")
                return
            }
            guard let sample = samples?.first as? HKQuantitySample else { return }
            if let lastDate = self?.lastHRDate, sample.endDate <= lastDate { return }
            self?.lastHRDate = sample.endDate
            let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
            self?.onHeartRate?(
                sample.quantity.doubleValue(for: unit), sample.endDate
            )
        }
        store.execute(query)
    }

    private func pollEnergy() {
        guard let startDate = startDate else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate, end: nil, options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate, ascending: false
        )
        let query = HKSampleQuery(
            sampleType: HKQuantityType(.activeEnergyBurned),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortByDate]
        ) { [weak self] _, samples, error in
            if let error = error {
                self?.onError?("Energy poll error: \(error.localizedDescription)")
                return
            }
            guard let samples = samples as? [HKQuantitySample],
                  !samples.isEmpty else { return }
            let unit = HKUnit.kilocalorie()
            var newKcal = 0.0
            var newestDate: Date?
            for sample in samples {
                let id = sample.uuid.uuidString
                guard self?.processedEnergySamples.contains(id) == false
                else { continue }
                self?.processedEnergySamples.insert(id)
                newKcal += sample.quantity.doubleValue(for: unit)
                if let current = newestDate {
                    if sample.endDate > current { newestDate = sample.endDate }
                } else {
                    newestDate = sample.endDate
                }
            }
            if newKcal > 0, let newest = newestDate {
                self?.onEnergy?(newKcal, newest)
            }
        }
        store.execute(query)
    }
}
