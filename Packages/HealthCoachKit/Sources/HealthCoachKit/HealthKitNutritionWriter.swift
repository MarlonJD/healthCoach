#if canImport(HealthKit)
import Foundation
import HealthKit

public final class HealthKitNutritionWriter: NSObject, @unchecked Sendable {
    public static let mealIDMetadataKey = "com.marlonjd.HealthCoach.mealID"
    public static let mealRevisionMetadataKey = "com.marlonjd.HealthCoach.mealRevision"

    public let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public static var nutritionTypes: [HKQuantityType] {
        [
            HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed),
            HKQuantityType.quantityType(forIdentifier: .dietaryProtein),
            HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates),
            HKQuantityType.quantityType(forIdentifier: .dietaryFatTotal)
        ].compactMap { $0 }
    }

    public func writeNutrition(for meal: Meal, analysis: MealAnalysis) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthCoachError.unavailable("Apple Health nutrition data is unavailable on this device.")
        }
        try validate(analysis)
        let shareTypes = Set(Self.nutritionTypes.map { $0 as HKSampleType })
        let readTypes = Set(Self.nutritionTypes.map { $0 as HKObjectType })
        let authorized = try await requestAuthorization(toShare: shareTypes, read: readTypes)
        guard authorized else {
            throw HealthCoachError.unavailable("Apple Health nutrition permission was not granted.")
        }

        let oldSamples = try await existingSamples(for: meal.id)
        if !oldSamples.isEmpty {
            try await delete(oldSamples)
        }
        try await save(samples(for: meal, analysis: analysis))
    }

    private func samples(for meal: Meal, analysis: MealAnalysis) -> [HKQuantitySample] {
        let start = meal.capturedAt
        let end = start.addingTimeInterval(1)
        let baseMetadata: [String: Any] = [
            Self.mealIDMetadataKey: meal.id.uuidString,
            Self.mealRevisionMetadataKey: meal.revision,
            HKMetadataKeySyncIdentifier: "com.marlonjd.HealthCoach.meal.\(meal.id.uuidString).nutrition",
            HKMetadataKeySyncVersion: meal.revision,
            HKMetadataKeyFoodType: meal.originalText
        ]
        let values: [(HKQuantityTypeIdentifier, HKQuantity, String)] = [
            (.dietaryEnergyConsumed, HKQuantity(unit: .kilocalorie(), doubleValue: analysis.totals.kcal), "kcal"),
            (.dietaryProtein, HKQuantity(unit: .gram(), doubleValue: analysis.totals.proteinGrams), "g"),
            (.dietaryCarbohydrates, HKQuantity(unit: .gram(), doubleValue: analysis.totals.carbohydratesGrams), "g"),
            (.dietaryFatTotal, HKQuantity(unit: .gram(), doubleValue: analysis.totals.fatGrams), "g")
        ]
        return values.compactMap { identifier, quantity, _ in
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
            return HKQuantitySample(type: type, quantity: quantity, start: start, end: end, metadata: baseMetadata)
        }
    }

    private func validate(_ analysis: MealAnalysis) throws {
        let values = [
            analysis.totals.kcal,
            analysis.totals.proteinGrams,
            analysis.totals.carbohydratesGrams,
            analysis.totals.fatGrams
        ]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw HealthCoachError.invalidInput("Nutrition values must be finite and non-negative.")
        }
    }

    private func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            healthStore.requestAuthorization(toShare: toShare, read: read) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func existingSamples(for mealID: UUID) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: Self.mealIDMetadataKey,
            operatorType: .equalTo,
            value: mealID.uuidString
        )
        var samples: [HKSample] = []
        for type in Self.nutritionTypes {
            samples.append(contentsOf: try await query(type: type, predicate: predicate))
        }
        return samples
    }

    private func query(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private func delete(_ samples: [HKSample]) async throws {
        try await healthStore.delete(samples)
    }

    private func save(_ samples: [HKQuantitySample]) async throws {
        try await healthStore.save(samples)
    }
}
#endif
