#if canImport(HealthKit)
import Foundation
import HealthKit

public final class HealthKitWorkoutWriter: NSObject, @unchecked Sendable {
    public static let sessionIDMetadataKey = "com.marlonjd.HealthCoach.workoutSessionID"

    public let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public func writeManualWorkout(for session: WorkoutSession) async throws -> HKWorkout {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthCoachError.unavailable("Apple Health workouts are unavailable on this device.")
        }
        guard session.status == .completed, let end = session.endedAt, end > session.startedAt else {
            throw HealthCoachError.invalidInput("Only a completed workout can be added to Apple Health.")
        }

        let workoutType = HKObjectType.workoutType()
        try await requestAuthorization(toShare: [workoutType], read: [workoutType])
        let oldWorkouts = try await existingWorkouts(for: session.id)
        if !oldWorkouts.isEmpty {
            try await healthStore.delete(oldWorkouts)
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: nil)
        try await builder.beginCollection(at: session.startedAt)
        try await builder.addMetadata([
            Self.sessionIDMetadataKey: session.id.uuidString,
            HKMetadataKeySyncIdentifier: "com.marlonjd.HealthCoach.workout.\(session.id.uuidString)",
            HKMetadataKeySyncVersion: session.revision,
            HKMetadataKeyWorkoutBrandName: "HealthCoach"
        ])
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else {
            throw HealthCoachError.unavailable("Apple Health did not return the saved workout.")
        }
        return workout
    }

    private func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        try await healthStore.requestAuthorization(toShare: toShare, read: read)
    }

    private func existingWorkouts(for sessionID: UUID) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: Self.sessionIDMetadataKey,
            operatorType: .equalTo,
            value: sessionID.uuidString
        )
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
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
        return samples.compactMap { $0 as? HKWorkout }
    }
}
#endif
