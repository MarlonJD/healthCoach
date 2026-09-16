import Foundation
import HealthKit
import WatchKit

/// Receives watchOS workout recovery callbacks and reconnects them to the
/// cached HealthCoach session. The phone is still the only canonical store.
@MainActor
final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    private let healthStore = HKHealthStore()
    private weak var model: WatchAppModel?
    private var pendingRecoveredSession: HKWorkoutSession?

    func attach(model: WatchAppModel) {
        self.model = model
        if let pendingRecoveredSession {
            self.pendingRecoveredSession = nil
            model.recoverActiveWorkout(pendingRecoveredSession)
        }
    }

    func handleActiveWorkoutRecovery() {
        guard HKHealthStore.isHealthDataAvailable() else {
            model?.recordLiveError("HealthKit is unavailable while recovering the workout.")
            return
        }
        healthStore.recoverActiveWorkoutSession { [weak self] session, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let session {
                    if let model = self.model {
                        model.recoverActiveWorkout(session)
                    } else {
                        self.pendingRecoveredSession = session
                    }
                } else if let message {
                    self.model?.recordLiveError("HealthKit workout recovery failed: \(message)")
                }
            }
        }
    }
}
