import Foundation

public struct HealthKitSleepSample: Equatable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var stage: SleepInterval.Stage

    public init(id: String, start: Date, end: Date, stage: SleepInterval.Stage) {
        self.id = id
        self.start = start
        self.end = end
        self.stage = stage
    }
}

public struct HealthKitDailyValues: Equatable, Sendable {
    public var steps: Double?
    public var activeEnergyKcal: Double?
    public var restingHeartRateBpm: Double?
    public var hrvSDNNMilliseconds: Double?
    public var importedWorkoutCount: Int?
    public var measurements: [Measurement]
    public var sleepSamples: [HealthKitSleepSample]
    public var sampleIDs: [String]

    public init(
        steps: Double? = nil,
        activeEnergyKcal: Double? = nil,
        restingHeartRateBpm: Double? = nil,
        hrvSDNNMilliseconds: Double? = nil,
        importedWorkoutCount: Int? = nil,
        measurements: [Measurement] = [],
        sleepSamples: [HealthKitSleepSample] = [],
        sampleIDs: [String] = []
    ) {
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.restingHeartRateBpm = restingHeartRateBpm
        self.hrvSDNNMilliseconds = hrvSDNNMilliseconds
        self.importedWorkoutCount = importedWorkoutCount
        self.measurements = measurements
        self.sleepSamples = sleepSamples
        self.sampleIDs = sampleIDs
    }
}

public enum HealthKitNormalizer {
    public static func summary(
        localDate: String,
        dayStart: Date,
        dayEnd: Date,
        timeZone: TimeZone,
        values: HealthKitDailyValues,
        freshness: Date = Date()
    ) -> HealthSummary {
        let sleepHours = DeterministicSummaries.mergedAsleepDurationHours(
            intervals: values.sleepSamples.map { SleepInterval(start: $0.start, end: $0.end, stage: $0.stage) },
            within: dayStart..<dayEnd
        )
        return HealthSummary(
            id: stableSummaryID(localDate: localDate),
            localDate: localDate,
            dayStart: dayStart,
            dayEnd: dayEnd,
            aggregationTimeZone: timeZone.identifier,
            steps: values.steps,
            activeEnergyKcal: values.activeEnergyKcal,
            sleepHours: values.sleepSamples.isEmpty ? nil : sleepHours,
            restingHeartRateBpm: values.restingHeartRateBpm,
            hrvSDNNMilliseconds: values.hrvSDNNMilliseconds,
            importedWorkoutCount: values.importedWorkoutCount,
            source: .healthKit,
            freshness: freshness,
            affectedSampleIDs: Array(Set(values.sampleIDs)).sorted()
        )
    }

    public static func preferredDailyWeight(_ measurements: [Measurement], localDate: String) -> Measurement? {
        measurements
            .filter { $0.kind == .weight && $0.localDate == localDate && $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.source != rhs.source { return lhs.source == .manual }
                return lhs.measuredAt > rhs.measuredAt
            }
            .first
    }

    private static func stableSummaryID(localDate: String) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "health-summary:\(localDate)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let suffix = String(format: "%012llx", hash & 0x0000_FFFF_FFFF_FFFF)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}

public struct HealthKitAnchorUpdate: Sendable {
    public var sampleType: String
    public var anchorData: Data
    public var affectedLocalDates: [String]
    /// Values are one or more affected local dates joined with a comma. This
    /// retains every day touched by an interval crossing midnight so a later
    /// deletion can recompute all affected summaries.
    public var sampleLocalDates: [String: String]
    public var removedSampleIDs: [String]

    public init(sampleType: String, anchorData: Data, affectedLocalDates: [String], sampleLocalDates: [String: String] = [:], removedSampleIDs: [String] = []) {
        self.sampleType = sampleType
        self.anchorData = anchorData
        self.affectedLocalDates = affectedLocalDates
        self.sampleLocalDates = sampleLocalDates
        self.removedSampleIDs = removedSampleIDs
    }
}
