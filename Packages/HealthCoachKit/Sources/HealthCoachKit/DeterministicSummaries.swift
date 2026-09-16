import Foundation

public struct DailyNutritionSummary: Equatable, Sendable {
    public var localDate: String
    public var mealCount: Int
    public var totals: MacroTotals

    public init(localDate: String, mealCount: Int, totals: MacroTotals) {
        self.localDate = localDate
        self.mealCount = mealCount
        self.totals = totals
    }
}

public struct WeightTrend: Equatable, Sendable {
    public var averageKg: Double?
    public var sampleDayCount: Int
    public var missingLocalDates: [String]

    public init(averageKg: Double?, sampleDayCount: Int, missingLocalDates: [String]) {
        self.averageKg = averageKg
        self.sampleDayCount = sampleDayCount
        self.missingLocalDates = missingLocalDates
    }
}

public struct SleepInterval: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case asleep
        case inBed
        case awake
    }

    public var start: Date
    public var end: Date
    public var stage: Stage

    public init(start: Date, end: Date, stage: Stage) {
        self.start = start
        self.end = end
        self.stage = stage
    }
}

public enum DeterministicSummaries {
    public static func nutrition(for localDate: String, meals: [Meal]) -> DailyNutritionSummary {
        let included = meals.filter {
            $0.localDate == localDate && $0.deletedAt == nil && $0.analysis?.sourceMealRevision == $0.revision
        }
        var totals = MacroTotals.zero
        for meal in included {
            guard let mealTotals = meal.analysis?.totals else { continue }
            totals.kcal += mealTotals.kcal
            totals.proteinGrams += mealTotals.proteinGrams
            totals.carbohydratesGrams += mealTotals.carbohydratesGrams
            totals.fatGrams += mealTotals.fatGrams
        }
        return DailyNutritionSummary(localDate: localDate, mealCount: included.count, totals: totals)
    }

    public static func sevenDayWeightTrend(
        endingOn localDate: String,
        measurements: [Measurement],
        timeZone: TimeZone = .current,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> WeightTrend {
        var calendar = calendar
        calendar.timeZone = timeZone
        guard let endDate = parseLocalDate(localDate, calendar: calendar) else {
            return WeightTrend(averageKg: nil, sampleDayCount: 0, missingLocalDates: [])
        }

        let dates = (0..<7).compactMap { offset -> Date? in
            calendar.date(byAdding: .day, value: -offset, to: endDate)
        }.reversed()
        var dailyValues: [String: Measurement] = [:]
        for measurement in measurements where measurement.kind == .weight && measurement.deletedAt == nil {
            let key = measurement.localDate
            guard dates.contains(where: { calendarString($0, calendar: calendar) == key }) else { continue }
            if let existing = dailyValues[key] {
                dailyValues[key] = preferredWeightMeasurement(existing, measurement)
            } else {
                dailyValues[key] = measurement
            }
        }

        let localDates = dates.map { calendarString($0, calendar: calendar) }
        let values = localDates.compactMap { dailyValues[$0]?.value }
        let missing = localDates.filter { dailyValues[$0] == nil }
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return WeightTrend(averageKg: average, sampleDayCount: values.count, missingLocalDates: missing)
    }

    public static func mergedAsleepDurationHours(
        intervals: [SleepInterval],
        within range: Range<Date>
    ) -> Double {
        let asleep = intervals.compactMap { interval -> Range<Date>? in
            guard interval.stage == .asleep, interval.end > interval.start else { return nil }
            let start = max(interval.start, range.lowerBound)
            let end = min(interval.end, range.upperBound)
            guard end > start else { return nil }
            return start..<end
        }.sorted { $0.lowerBound < $1.lowerBound }

        var merged: [Range<Date>] = []
        for interval in asleep {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        let seconds = merged.reduce(0.0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
        return seconds / 3_600
    }

    public static func dayRange(for localDate: String, timeZone: TimeZone = .current) -> Range<Date>? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let start = parseLocalDate(localDate, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return start..<end
    }

    private static func preferredWeightMeasurement(_ lhs: Measurement, _ rhs: Measurement) -> Measurement {
        if lhs.source != rhs.source {
            return lhs.source == .manual ? lhs : rhs
        }
        return lhs.measuredAt >= rhs.measuredAt ? lhs : rhs
    }

    private static func parseLocalDate(_ string: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private static func calendarString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
