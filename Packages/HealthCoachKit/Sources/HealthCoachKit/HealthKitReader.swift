#if canImport(HealthKit)
import Foundation
import HealthKit

public struct HealthKitImportResult: Sendable {
    public var summaries: [HealthSummary]
    public var measurements: [Measurement]

    public init(summaries: [HealthSummary], measurements: [Measurement]) {
        self.summaries = summaries
        self.measurements = measurements
    }
}

/// iPhone-only HealthKit reader. It performs reads and normalization; the
/// shared store remains the only durable writer and never receives raw sample
/// streams or a fabricated zero when access is denied.
public final class HealthKitReader: NSObject, @unchecked Sendable {
    private final class CompletionBox: @unchecked Sendable {
        let handler: HKObserverQueryCompletionHandler

        init(_ handler: @escaping HKObserverQueryCompletionHandler) {
            self.handler = handler
        }

        func call() {
            handler()
        }
    }

    public let healthStore: HKHealthStore
    private let calendar: Calendar

    public init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        var calendar = calendar
        calendar.timeZone = calendar.timeZone
        self.calendar = calendar
    }

    public static var readableTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .activeEnergyBurned, .restingHeartRate,
            .heartRateVariabilitySDNN, .bodyMass, .bodyFatPercentage
        ]
        for identifier in quantities {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    private static var readableSampleTypes: [HKSampleType] {
        var types: [HKSampleType] = []
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .activeEnergyBurned, .restingHeartRate,
            .heartRateVariabilitySDNN, .bodyMass, .bodyFatPercentage
        ]
        types.append(contentsOf: quantities.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }
        types.append(HKObjectType.workoutType())
        return types
    }

    public func requestReadAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: Self.readableTypes) { success, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: success) }
            }
        }
    }

    public func importRecent(days: Int = HealthCoachConstants.maximumHistoryDays) async throws -> HealthKitImportResult {
        let dayCount = min(max(days, 1), HealthCoachConstants.maximumHistoryDays)
        let today = calendar.startOfDay(for: Date())
        var summaries: [HealthSummary] = []
        var measurements: [Measurement] = []
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let localDate = localDate(for: start)
            let values = try await readDailyValues(start: start, end: end)
            summaries.append(HealthKitNormalizer.summary(localDate: localDate, dayStart: start, dayEnd: end, timeZone: calendar.timeZone, values: values))
            measurements.append(contentsOf: values.measurements)
        }
        return HealthKitImportResult(summaries: summaries, measurements: measurements)
    }

    public func importAndPersist(days: Int = HealthCoachConstants.maximumHistoryDays, store: HealthCoachStore) async throws -> HealthKitImportResult {
        let result = try await importRecent(days: days)
        try store.persistHealthKitBatch(summaries: result.summaries, measurements: result.measurements, anchors: [])
        return result
    }

    /// Registers observers and finishes each HealthKit delivery only after the
    /// affected normalized rows, tombstones, sample-day map, and anchor have
    /// committed locally. It never waits for a LAN socket or a Codex turn.
    public func registerBackgroundObservers(store: HealthCoachStore) {
        for type in Self.readableSampleTypes {
            healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
            let identifier = type.identifier
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                let completionBox = CompletionBox(completion)
                guard let self, error == nil else {
                    completionBox.call()
                    return
                }
                Task {
                    await self.ingestAnchoredUpdate(sampleType: type, identifier: identifier, store: store, completion: completionBox)
                }
            }
            healthStore.execute(query)
        }
    }

    private func ingestAnchoredUpdate(sampleType: HKSampleType, identifier: String, store: HealthCoachStore, completion: CompletionBox) async {
        do {
            let oldAnchor = try store.healthKitAnchor(sampleType: identifier).flatMap(decodeAnchor)
            let query = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: oldAnchor, limit: HKObjectQueryNoLimit) { [weak self] _, samples, deleted, anchor, error in
                guard let self else {
                    completion.call()
                    return
                }
                Task {
                    await self.persistAnchoredSamples(samples: samples ?? [], deleted: deleted ?? [], anchor: anchor, identifier: identifier, store: store, completion: completion, queryError: error)
                }
            }
            healthStore.execute(query)
        } catch {
            completion.call()
        }
    }

    private func persistAnchoredSamples(
        samples: [HKSample],
        deleted: [HKDeletedObject],
        anchor: HKQueryAnchor?,
        identifier: String,
        store: HealthCoachStore,
        completion: CompletionBox,
        queryError: Error?
    ) async {
        guard queryError == nil, let anchor else {
            completion.call()
            return
        }
        do {
            let previousMap = try store.healthKitSampleLocalDates(sampleType: identifier)
            let deletedIDs = deleted.map { $0.uuid.uuidString }
            let affectedDates = Set(samples.flatMap { affectedLocalDates(for: $0) } + deletedIDs.flatMap { previousMap[$0]?.split(separator: ",").map(String.init) ?? [] })
            let deletedMeasurements = try store.measurements(includeDeleted: true).filter { measurement in
                guard let externalID = measurement.externalID else { return false }
                return deletedIDs.contains(externalID)
            }.map { measurement -> Measurement in
                var tombstone = measurement
                tombstone.deletedAt = Date()
                return tombstone
            }
            var summaries: [HealthSummary] = []
            for localDate in affectedDates {
                guard let range = DeterministicSummaries.dayRange(for: localDate, timeZone: calendar.timeZone) else { continue }
                let values = try await readDailyValues(start: range.lowerBound, end: range.upperBound)
                summaries.append(HealthKitNormalizer.summary(localDate: localDate, dayStart: range.lowerBound, dayEnd: range.upperBound, timeZone: calendar.timeZone, values: values))
            }
            let importedMeasurements = samples.compactMap { self.measurement(from: $0) }
            let sampleDates = Dictionary(uniqueKeysWithValues: samples.map { ($0.uuid.uuidString, affectedLocalDates(for: $0).sorted().joined(separator: ",")) })
            let anchorData = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            try store.persistHealthKitBatch(
                summaries: summaries,
                measurements: importedMeasurements,
                deletedMeasurements: deletedMeasurements,
                anchors: [HealthKitAnchorUpdate(sampleType: identifier, anchorData: anchorData, affectedLocalDates: Array(affectedDates), sampleLocalDates: sampleDates, removedSampleIDs: deletedIDs)]
            )
        } catch {
            // The observer contract still requires prompt completion on a
            // handled ingestion error; a later observer delivery will retry.
        }
        completion.call()
    }

    private func readDailyValues(start: Date, end: Date) async throws -> HealthKitDailyValues {
        async let steps = quantityValue(identifier: .stepCount, start: start, end: end, options: .cumulativeSum, unit: .count())
        async let energy = quantityValue(identifier: .activeEnergyBurned, start: start, end: end, options: .cumulativeSum, unit: .kilocalorie())
        async let resting = quantityValue(identifier: .restingHeartRate, start: start, end: end, options: .discreteAverage, unit: HKUnit.count().unitDivided(by: .minute()))
        async let hrv = quantityValue(identifier: .heartRateVariabilitySDNN, start: start, end: end, options: .discreteAverage, unit: .secondUnit(with: .milli))
        let sleep = try await sleepSamples(start: start, end: end)
        let measurements = try await measurements(start: start, end: end)
        let workoutSummary = try await workoutSummary(start: start, end: end)
        return HealthKitDailyValues(steps: try await steps, activeEnergyKcal: try await energy, restingHeartRateBpm: try await resting, hrvSDNNMilliseconds: try await hrv, importedWorkoutCount: workoutSummary.count, measurements: measurements, sleepSamples: sleep, sampleIDs: sleep.map(\.id) + measurements.compactMap(\.externalID) + workoutSummary.ids)
    }

    private func quantityValue(identifier: HKQuantityTypeIdentifier, start: Date, end: Date, options: HKStatisticsOptions, unit: HKUnit) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: options, anchorDate: start, intervalComponents: DateComponents(day: 1))
        return try await withCheckedThrowingContinuation { continuation in
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                let statistics = collection?.statistics().first
                let quantity = options.contains(.cumulativeSum) ? statistics?.sumQuantity() : statistics?.averageQuantity()
                continuation.resume(returning: quantity?.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    private func sleepSamples(start: Date, end: Date) async throws -> [HealthKitSleepSample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKSample] = try await sampleQuery(type: type, predicate: predicate)
        return samples.compactMap { sample in
            guard let category = sample as? HKCategorySample else { return nil }
            let stage: SleepInterval.Stage = category.value == HKCategoryValueSleepAnalysis.inBed.rawValue ? .inBed : category.value == HKCategoryValueSleepAnalysis.awake.rawValue ? .awake : .asleep
            return HealthKitSleepSample(id: category.uuid.uuidString, start: category.startDate, end: category.endDate, stage: stage)
        }
    }

    private func measurements(start: Date, end: Date) async throws -> [Measurement] {
        var output: [Measurement] = []
        if let type = HKObjectType.quantityType(forIdentifier: .bodyMass) {
            let samples: [HKSample] = try await sampleQuery(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []))
            output.append(contentsOf: samples.compactMap { sample in
                guard let quantity = (sample as? HKQuantitySample)?.quantity else { return nil }
                return Measurement(id: sample.uuid, kind: .weight, value: quantity.doubleValue(for: .gramUnit(with: .kilo)), unit: "kg", measuredAt: sample.startDate, localDate: localDate(for: sample.startDate), source: .healthKit, externalID: sample.uuid.uuidString)
            })
        }
        if let type = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage) {
            let samples: [HKSample] = try await sampleQuery(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []))
            output.append(contentsOf: samples.compactMap { sample in
                guard let quantity = (sample as? HKQuantitySample)?.quantity else { return nil }
                return Measurement(id: sample.uuid, kind: .bodyFat, value: quantity.doubleValue(for: .percent()) * 100, unit: "percent", measuredAt: sample.startDate, localDate: localDate(for: sample.startDate), source: .healthKit, externalID: sample.uuid.uuidString)
            })
        }
        return output
    }

    private func measurement(from sample: HKSample) -> Measurement? {
        guard let quantitySample = sample as? HKQuantitySample else { return nil }
        switch quantitySample.quantityType.identifier {
        case HKQuantityTypeIdentifier.bodyMass.rawValue:
            return Measurement(id: sample.uuid, kind: .weight, value: quantitySample.quantity.doubleValue(for: .gramUnit(with: .kilo)), unit: "kg", measuredAt: sample.startDate, localDate: localDate(for: sample.startDate), source: .healthKit, externalID: sample.uuid.uuidString)
        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return Measurement(id: sample.uuid, kind: .bodyFat, value: quantitySample.quantity.doubleValue(for: .percent()) * 100, unit: "percent", measuredAt: sample.startDate, localDate: localDate(for: sample.startDate), source: .healthKit, externalID: sample.uuid.uuidString)
        default:
            return nil
        }
    }

    private func workoutSummary(start: Date, end: Date) async throws -> (count: Int, ids: [String]) {
        let samples: [HKSample] = try await sampleQuery(type: HKObjectType.workoutType(), predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []))
        return (samples.count, samples.map { $0.uuid.uuidString })
    }

    private func sampleQuery(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            healthStore.execute(query)
        }
    }

    private func decodeAnchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func localDate(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func affectedLocalDates(for sample: HKSample) -> Set<String> {
        var dates = Set([localDate(for: sample.startDate)])
        guard sample.endDate > sample.startDate else { return dates }
        var cursor = calendar.startOfDay(for: sample.startDate)
        let lastDate = calendar.startOfDay(for: sample.endDate.addingTimeInterval(-0.001))
        while cursor < lastDate {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            dates.insert(localDate(for: cursor))
        }
        return dates
    }
}
#endif
