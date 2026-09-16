import Foundation
import HealthCoachKit
import HealthKit

enum WatchHealthWorkoutPhase: Equatable {
    case prepared
    case running
    case paused
    case stopped
    case ended
}

/// Owns the real Watch-side HealthKit workout session. The controller keeps
/// HealthKit objects on the main actor and forwards only small, validated
/// summaries to the SwiftUI model. Raw samples stay in HealthKit.
@MainActor
final class WatchWorkoutSessionController: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var lastMetrics: LiveWorkoutMetrics?
    private var finishContinuation: CheckedContinuation<LiveWorkoutMetrics?, Error>?
    private var isFinishing = false

    var onPhaseChanged: ((WatchHealthWorkoutPhase) -> Void)?
    var onMetrics: ((LiveWorkoutMetrics) -> Void)?
    var onError: ((String) -> Void)?

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        super.init()
    }

    var hasActiveSession: Bool {
        guard let session else { return false }
        return session.state != .ended
    }

    func start() async throws {
        guard !hasActiveSession else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WatchWorkoutError.healthDataUnavailable
        }

        let workoutType = HKObjectType.workoutType()
        var readTypes = Set<HKObjectType>()
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
            readTypes.insert(heartRate)
        }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            readTypes.insert(energy)
        }
        try await healthStore.requestAuthorization(toShare: [workoutType], read: readTypes)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let newBuilder = newSession.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
            dataSource.enableCollection(for: heartRate, predicate: nil)
        }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            dataSource.enableCollection(for: energy, predicate: nil)
        }
        newBuilder.dataSource = dataSource
        newSession.delegate = self
        newBuilder.delegate = self
        session = newSession
        builder = newBuilder
        isFinishing = false
        onPhaseChanged?(.prepared)

        let startDate = Date()
        newSession.startActivity(with: startDate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            newBuilder.beginCollection(withStart: startDate) { [weak self] success, error in
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(throwing: WatchWorkoutError.sessionUnavailable)
                        return
                    }
                    guard success else {
                        self.endWithoutSaving()
                        continuation.resume(throwing: WatchWorkoutError.startFailed(message ?? "HealthKit could not start the workout."))
                        return
                    }
                    self.publishMetrics()
                    continuation.resume()
                }
            }
        }
    }

    func stopAndSave() async throws -> LiveWorkoutMetrics? {
        guard let session else { throw WatchWorkoutError.sessionUnavailable }
        if session.state == .ended {
            return lastMetrics
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LiveWorkoutMetrics?, Error>) in
            finishContinuation = continuation
            isFinishing = false
            publishMetrics()
            switch session.state {
            case .stopped:
                finishBuilder(at: Date())
            case .ended:
                finishContinuation = nil
                continuation.resume(returning: lastMetrics)
            default:
                session.stopActivity(with: Date())
            }
        }
    }

    /// Terminates a session if the local durable command could not be saved.
    /// The builder is deliberately not finished, so a HealthCoach session is
    /// never advertised to the phone without a persisted Watch command.
    func discardWithoutSaving() {
        finishContinuation = nil
        isFinishing = true
        session?.delegate = nil
        builder?.delegate = nil
        session?.end()
        session = nil
        builder = nil
        isFinishing = false
        onPhaseChanged?(.ended)
    }

    /// Reattaches delegates after watchOS calls handleActiveWorkoutRecovery.
    func recover(_ recoveredSession: HKWorkoutSession) {
        session = recoveredSession
        let recoveredBuilder = recoveredSession.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: recoveredSession.workoutConfiguration
        )
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
            dataSource.enableCollection(for: heartRate, predicate: nil)
        }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            dataSource.enableCollection(for: energy, predicate: nil)
        }
        recoveredBuilder.dataSource = dataSource
        recoveredSession.delegate = self
        recoveredBuilder.delegate = self
        builder = recoveredBuilder
        isFinishing = false
        onPhaseChanged?(phase(for: recoveredSession.state))
        publishMetrics()
    }

    private func publishMetrics() {
        guard let builder else { return }
        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)
        let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        let heartRateStatistics = heartRateType.flatMap { builder.statistics(for: $0) }
        let energyStatistics = energyType.flatMap { builder.statistics(for: $0) }
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let metrics = LiveWorkoutMetrics(
            heartRateBpm: heartRateStatistics?.mostRecentQuantity()?.doubleValue(for: heartRateUnit),
            averageHeartRateBpm: heartRateStatistics?.averageQuantity()?.doubleValue(for: heartRateUnit),
            peakHeartRateBpm: heartRateStatistics?.maximumQuantity()?.doubleValue(for: heartRateUnit),
            activeEnergyKcal: energyStatistics?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            elapsedSeconds: max(0, builder.elapsedTime),
            capturedAt: Date()
        )
        guard (try? metrics.validate()) != nil else { return }
        lastMetrics = metrics
        onMetrics?(metrics)
    }

    private func finishBuilder(at date: Date) {
        guard !isFinishing, let builder else { return }
        isFinishing = true
        publishMetrics()
        builder.endCollection(withEnd: date) { [weak self] success, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard success else {
                    self.completeFinish(error: WatchWorkoutError.finishFailed(message ?? "HealthKit could not end the workout."))
                    return
                }
                do {
                    _ = try await builder.finishWorkout()
                    self.completeFinish(error: nil)
                } catch {
                    self.completeFinish(error: WatchWorkoutError.finishFailed(error.localizedDescription))
                }
            }
        }
    }

    private func completeFinish(error: Error?) {
        let continuation = finishContinuation
        finishContinuation = nil
        isFinishing = false
        session?.end()
        session = nil
        builder = nil
        onPhaseChanged?(.ended)
        if let error {
            onError?(error.localizedDescription)
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: lastMetrics)
        }
    }

    private func endWithoutSaving() {
        session?.end()
        session = nil
        builder = nil
        onPhaseChanged?(.ended)
    }

    private func phase(for state: HKWorkoutSessionState) -> WatchHealthWorkoutPhase {
        switch state {
        case .running: return .running
        case .paused: return .paused
        case .stopped: return .stopped
        case .ended: return .ended
        default: return .prepared
        }
    }

    private func handleState(_ state: HKWorkoutSessionState) {
        onPhaseChanged?(phase(for: state))
        if state == .stopped {
            finishBuilder(at: Date())
        }
    }

    private func handleFailure(_ message: String) {
        if let continuation = finishContinuation {
            finishContinuation = nil
            isFinishing = false
            continuation.resume(throwing: WatchWorkoutError.sessionFailed(message))
        }
        onError?(message)
        onPhaseChanged?(.ended)
    }

    @objc nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            self?.handleState(toState)
        }
    }

    @objc nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleFailure(message)
        }
    }

    @objc nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor [weak self] in
            self?.publishMetrics()
        }
    }

    @objc nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        Task { @MainActor [weak self] in
            self?.publishMetrics()
        }
    }
}

private enum WatchWorkoutError: LocalizedError {
    case healthDataUnavailable
    case sessionUnavailable
    case startFailed(String)
    case finishFailed(String)
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable: return "Health data is unavailable on this Apple Watch."
        case .sessionUnavailable: return "The HealthKit workout session became unavailable."
        case .startFailed(let message), .finishFailed(let message), .sessionFailed(let message): return message
        }
    }
}
