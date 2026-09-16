import Foundation
import SwiftUI
import HealthCoachKit

enum PhoneSyncStatus: Equatable {
    case unpaired
    case pairing
    case disconnected
    case syncing
    case synced(Date)
    case failed(String)

    var title: String {
        switch self {
        case .unpaired: return "Not paired"
        case .pairing: return "Pairing…"
        case .disconnected: return "Mac disconnected"
        case .syncing: return "Syncing…"
        case .synced: return "Synced"
        case .failed: return "Sync error"
        }
    }
}

@MainActor
final class iOSAppModel: ObservableObject {
    let store: HealthCoachStore?
    let localPeerID: UUID
    private let pairingStore: PairingCredentialStore
    private var watchBridge: PhoneWatchConnectivityBridge?
    private var syncTask: Task<Void, Never>?
    #if canImport(HealthKit)
    private var healthKitReader: HealthKitReader?
    #endif

    @Published private(set) var meals: [Meal] = []
    @Published private(set) var measurements: [HealthCoachKit.Measurement] = []
    @Published private(set) var healthSummaries: [HealthSummary] = []
    @Published private(set) var workouts: [WorkoutSession] = []
    @Published private(set) var trainingSets: [TrainingSet] = []
    @Published private(set) var programs: [TrainingProgram] = []
    @Published private(set) var jobs: [CoachJob] = []
    @Published private(set) var corrections: [UserCorrection] = []
    @Published private(set) var profile = UserProfile()
    @Published private(set) var goals = Goals()
    @Published private(set) var equipment = EquipmentProfile()
    @Published private(set) var syncStatus: PhoneSyncStatus
    @Published private(set) var lastError: String?
    @Published private(set) var watchLastError: String?
    @Published private(set) var healthKitMessage: String?
    @Published var showingPairingScanner = false

    init() {
        let peerKey = "HealthCoach.phonePeerID"
        if let stored = UserDefaults.standard.string(forKey: peerKey), let id = UUID(uuidString: stored) {
            localPeerID = id
        } else {
            let id = UUID()
            localPeerID = id
            UserDefaults.standard.set(id.uuidString, forKey: peerKey)
        }
        pairingStore = KeychainPairingCredentialStore()

        do {
            let path = try HealthCoachStore.applicationSupportURL()
            store = try HealthCoachStore(path: path)
        } catch {
            store = nil
        }

        if let store, let pairID = store.activePairID, (try? pairingStore.load(pairID: pairID)) != nil {
            syncStatus = .disconnected
        } else {
            syncStatus = .unpaired
        }

        let bridge = PhoneWatchConnectivityBridge()
        watchBridge = bridge
        bridge.onTransfer = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.receiveWatchTransfer(data)
            }
        }
        bridge.onActivated = { [weak self] in
            Task { @MainActor [weak self] in self?.publishWatchSnapshot() }
        }
        #if canImport(HealthKit)
        if let store {
            let reader = HealthKitReader()
            healthKitReader = reader
            reader.registerBackgroundObservers(store: store)
        }
        #endif
        refresh()
        publishWatchSnapshot()
    }

    deinit {
        syncTask?.cancel()
    }

    var today: String {
        localDate(for: Date())
    }

    var todayNutrition: DailyNutritionSummary {
        DeterministicSummaries.nutrition(for: today, meals: meals)
    }

    var todayHealthSummary: HealthSummary? {
        healthSummaries.first(where: { $0.localDate == today })
    }

    /// HealthKit is the automatic source shown on Today. A manual weight is
    /// only a fallback when no imported HealthKit weight exists at all.
    var currentWeightMeasurement: HealthCoachKit.Measurement? {
        let weights = measurements
            .filter { $0.kind == .weight && $0.deletedAt == nil }
            .sorted { $0.measuredAt > $1.measuredAt }
        return weights.first(where: { $0.source == .healthKit }) ?? weights.first
    }

    var weightTrend: WeightTrend {
        DeterministicSummaries.sevenDayWeightTrend(endingOn: today, measurements: measurements)
    }

    var currentProgram: TrainingProgram? {
        programs.first(where: { $0.status == .current })
    }

    var displayedTrainingProgram: TrainingProgram? {
        if let session = activeSession,
           let programID = session.programID,
           let programRevision = session.programRevision,
           let original = programs.first(where: { $0.id == programID && $0.revision == programRevision }) {
            return original
        }
        return currentProgram
    }

    var proposedPrograms: [TrainingProgram] {
        programs.filter { $0.status == .proposed }
    }

    var activeSession: WorkoutSession? {
        workouts.first(where: { $0.status == .active })
    }

    func progressionSession(for exerciseID: String) -> WorkoutSession? {
        let sessionsWithExercise = workouts.filter { session in
            trainingSets.contains { $0.sessionID == session.id && $0.exerciseID == exerciseID }
        }
        return sessionsWithExercise.first(where: { $0.status == .completed }) ?? sessionsWithExercise.first
    }

    var pendingJobCount: Int {
        jobs.filter { $0.status == .queued || $0.status == .running }.count
    }

    var analysisEnabled: Bool {
        (try? store?.analysisPolicy().enabled) ?? true
    }

    func dismissError() {
        lastError = nil
    }

    func refresh() {
        guard let store else {
            lastError = "HealthCoach storage could not be opened."
            return
        }
        do {
            meals = try store.meals()
            measurements = try store.measurements()
            healthSummaries = try store.healthSummaries()
            workouts = try store.workouts()
            trainingSets = try store.trainingSets()
            programs = try store.programs()
            jobs = try store.jobs()
            corrections = try store.corrections()
            profile = try store.profile() ?? UserProfile()
            goals = try store.goals() ?? Goals()
            equipment = try store.equipment() ?? EquipmentProfile()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        publishWatchSnapshot()
    }

    func addMeal(text: String) {
        guard let store else { return }
        do {
            _ = try store.saveMeal(Meal(localDate: today, originalText: text))
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func updateMeal(_ meal: Meal, text: String) {
        guard let store else { return }
        var updated = meal
        updated.originalText = text
        updated.revisions.append(MealTextRevision(revision: meal.revision + 1, text: text))
        do {
            _ = try store.saveMeal(updated)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func deleteMeal(_ meal: Meal) {
        do {
            try store?.deleteMeal(id: meal.id)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func reanalyze(_ meal: Meal) {
        guard let store else { return }
        do {
            _ = try store.requestMealAnalysis(id: meal.id)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func correctMealNutrition(_ meal: Meal, kcal: Double, protein: Double?, carbohydrates: Double?, fat: Double?) {
        let optionalValues = [protein, carbohydrates, fat].compactMap { $0 }
        guard let store, kcal.isFinite, kcal >= 0,
              optionalValues.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        do {
            let oldTotals = meal.analysis?.totals ?? .zero
            let correctedRevision = meal.revision + 1
            let correctedTotals = MacroTotals(
                kcal: kcal,
                proteinGrams: protein ?? oldTotals.proteinGrams,
                carbohydratesGrams: carbohydrates ?? oldTotals.carbohydratesGrams,
                fatGrams: fat ?? oldTotals.fatGrams
            )
            var corrected = meal
            corrected.revision = correctedRevision
            corrected.analysis = MealAnalysis(
                sourceMealID: meal.id,
                sourceMealRevision: correctedRevision,
                components: [],
                totals: correctedTotals,
                kcalRange: NutritionRange(lowKcal: kcal, centralKcal: kcal, highKcal: kcal),
                assumptions: ["Nutrition totals entered by the user; this is not a Codex estimate."],
                sourceJobID: UUID(),
                sourceModel: "user"
            )
            corrected.analysisStatus = .succeeded
            corrected.corrected = true
            let saved = try store.saveMeal(corrected, enqueueAnalysis: false)
            let corrections: [(String, String, String)] = [
                ("kcal", oldTotals.kcal.description, correctedTotals.kcal.description),
                ("proteinGrams", oldTotals.proteinGrams.description, correctedTotals.proteinGrams.description),
                ("carbohydratesGrams", oldTotals.carbohydratesGrams.description, correctedTotals.carbohydratesGrams.description),
                ("fatGrams", oldTotals.fatGrams.description, correctedTotals.fatGrams.description)
            ]
            for (field, original, value) in corrections where original != value {
                try store.saveCorrection(UserCorrection(recordType: .meal, recordID: meal.id.uuidString, field: field, originalValue: original, correctedValue: value, sourceRevision: saved.revision, reusablePreference: false))
            }
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func saveMeasurement(kind: MeasurementKind, value: Double, measuredAt: Date = Date()) {
        guard let store, value.isFinite, value >= 0 else { return }
        let unit: String = kind == .waist ? "cm" : kind == .bodyFat ? "percent" : "kg"
        do {
            try store.saveMeasurement(Measurement(kind: kind, value: value, unit: unit, measuredAt: measuredAt, localDate: localDate(for: measuredAt)))
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func deleteMeasurement(_ measurement: HealthCoachKit.Measurement) {
        guard measurement.source == .manual else { return }
        do {
            try store?.deleteMeasurement(id: measurement.id)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func saveProfile(displayName: String, experience: ExperienceLevel, daysPerWeek: Int, duration: Int, constraints: String, preferences: [String]) {
        guard let store else { return }
        do {
            var value = profile
            value.displayName = displayName
            value.experience = experience
            value.daysPerWeek = daysPerWeek
            value.sessionDurationMinutes = duration
            value.scheduleConstraints = constraints
            value.exercisePreferences = preferences
            try store.saveProfile(value)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func saveGoals(currentWeight: Double?, targetWeight: Double?, bodyFat: Double?, waist: Double?) {
        guard let store else { return }
        do {
            var value = goals
            value.currentWeightKg = currentWeight
            value.targetWeightKg = targetWeight
            value.targetBodyFatPercent = bodyFat
            value.targetWaistCm = waist
            try store.saveGoals(value)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func saveEquipment(available: [String], excluded: [String]) {
        guard let store else { return }
        do {
            var value = equipment
            value.available = available
            value.excluded = excluded
            try store.saveEquipment(value)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func toggleAnalysis(_ enabled: Bool) {
        do { _ = try store?.setAnalysisEnabled(enabled); refresh() }
        catch { lastError = error.localizedDescription }
    }

    func importHealthKit() async {
        #if canImport(HealthKit)
        guard let store else { return }
        do {
            let reader = HealthKitReader()
            guard try await reader.requestReadAuthorization() else {
                healthKitMessage = "HealthKit access is unavailable or was not granted. Manual capture remains available."
                return
            }
            let result = try await reader.importRecent()
            try store.persistHealthKitBatch(summaries: result.summaries, measurements: result.measurements, anchors: [])
            healthKitMessage = "Imported the last 90 days of available HealthKit summaries."
            refresh()
        } catch {
            healthKitMessage = "HealthKit is unavailable or permission was not granted: \(error.localizedDescription)"
        }
        #else
        healthKitMessage = "HealthKit is unavailable on this build."
        #endif
    }

    func startWorkout() {
        guard let store else { return }
        do {
            _ = try store.startSession(program: currentProgram, localDate: today)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func recordSet(exercise: ProgramExercise, reps: Int, loadKg: Double, rir: Double?) {
        guard let store, let session = activeSession else { return }
        do {
            let ordinal = trainingSets.filter { $0.sessionID == session.id }.count + 1
            _ = try store.recordSet(TrainingSet(sessionID: session.id, exerciseID: exercise.exerciseID, ordinal: ordinal, reps: reps, loadKg: loadKg, rir: rir, programID: session.programID, programRevision: session.programRevision))
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func finishWorkout() {
        guard let session = activeSession else { return }
        do { _ = try store?.finishSession(id: session.id); refresh() }
        catch { lastError = error.localizedDescription }
    }

    func requestProgram() {
        guard let store else { return }
        do {
            _ = try store.createJob(kind: .generateProgram, request: JobRequest(), inputRevision: max(profile.revision, goals.revision), sourceRevision: currentProgram?.revision)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func acceptProgram(_ program: TrainingProgram) {
        do { _ = try store?.acceptProgram(program); refresh() }
        catch { lastError = "Program changed before acceptance: \(error.localizedDescription)" }
    }

    func requestProgression(for exerciseID: String, session: WorkoutSession) {
        guard let store else { return }
        do {
            _ = try store.createJob(kind: .suggestProgression, request: JobRequest(exerciseID: exerciseID, sessionID: session.id), inputRevision: session.revision, sourceRevision: session.revision)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func askCoach(question: String, from: String, to: String) {
        guard let store, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            _ = try store.createJob(kind: .answerQuestion, request: JobRequest(question: question, localDateFrom: from.isEmpty ? nil : from, localDateTo: to.isEmpty ? nil : to), inputRevision: max(profile.revision, goals.revision), sourceRevision: currentProgram?.revision)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func cancel(_ job: CoachJob) {
        do { try store?.cancelJob(id: job.id); refresh() }
        catch { lastError = error.localizedDescription }
    }

    func retry(_ job: CoachJob) {
        do { _ = try store?.retryJob(id: job.id); refresh() }
        catch { lastError = error.localizedDescription }
    }

    func pair(with data: Data) async {
        syncStatus = .pairing
        do {
            let payload = try PairingCredentialFactory.decodeQRPayload(data)
            let credential = PairingCredential(pairID: payload.pairID, peerID: payload.macPeerID, secret: payload.credential, expiresAt: payload.expiresAt)
            guard let store else { throw HealthCoachError.unavailable("Phone storage is unavailable.") }
            try await PhoneSyncService.synchronize(store: store, localPeerID: self.localPeerID, credential: credential, duration: 2.0)
            let activatedCredential = PairingCredentialFactory.activated(credential)
            try pairingStore.save(activatedCredential)
            try store.setActivePair(credential.pairID)
            syncStatus = .synced(Date())
            refresh()
        } catch {
            syncStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func syncNow() {
        guard syncTask == nil else { return }
        guard let store, let pairID = store.activePairID else {
            syncStatus = .unpaired
            return
        }
        do {
            guard let credential = try pairingStore.load(pairID: pairID), credential.isUsable else {
                syncStatus = .unpaired
                return
            }
            syncStatus = .syncing
            let peerID = localPeerID
            syncTask = Task { [weak self] in
                do {
                    try await PhoneSyncService.synchronize(store: store, localPeerID: peerID, credential: credential, duration: 2.0)
                    await MainActor.run {
                        self?.syncStatus = .synced(Date())
                        self?.syncTask = nil
                        self?.refresh()
                    }
                } catch {
                    await MainActor.run {
                        self?.syncStatus = .failed(error.localizedDescription)
                        self?.lastError = error.localizedDescription
                        self?.syncTask = nil
                    }
                }
            }
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
    }

    func unpair() {
        do {
            if let pairID = store?.activePairID { try pairingStore.delete(pairID: pairID) }
            try store?.setActivePair(nil)
            syncStatus = .unpaired
        } catch { lastError = error.localizedDescription }
    }

    func receiveWatchTransfer(_ data: Data) {
        guard let store else { return }
        do {
            let transfer = try HealthCoachJSON.decode(WatchTransfer.self, from: data)
            if let command = transfer.command {
                applyWatchCommand(command, in: store)
                drainPendingWatchCommands(in: store)
            }
        } catch {
            watchLastError = "Watch payload could not be decoded."
        }
    }

    private func applyWatchCommand(_ command: WatchCommand, in store: HealthCoachStore) {
        do {
            let ack = try store.applyWatchCommand(command)
            watchBridge?.send(WatchTransfer(kind: "acknowledgment", acknowledgment: ack))
            watchLastError = ack.status == .rejected ? ack.message : nil
            refresh()
        } catch HealthCoachError.sequenceGap {
            watchLastError = "Watch command is waiting for an earlier command."
        } catch {
            _ = try? store.markWatchCommandTerminal(command, message: error.localizedDescription)
            let ack = WatchCommandAck(commandID: command.id, sessionID: command.sessionID, sequence: command.sequence, status: .rejected, message: error.localizedDescription, phoneRevision: (try? store.currentWatermark()) ?? 0)
            watchBridge?.send(WatchTransfer(kind: "acknowledgment", acknowledgment: ack))
            watchLastError = error.localizedDescription
            refresh()
        }
    }

    private func drainPendingWatchCommands(in store: HealthCoachStore) {
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            guard let pending = try? store.pendingWatchCommands() else { return }
            for command in pending.sorted(by: { lhs, rhs in
                if lhs.sessionID != rhs.sessionID { return lhs.sessionID.uuidString < rhs.sessionID.uuidString }
                return lhs.sequence < rhs.sequence
            }) {
                do {
                    let ack = try store.applyWatchCommand(command)
                    watchBridge?.send(WatchTransfer(kind: "acknowledgment", acknowledgment: ack))
                    watchLastError = ack.status == .rejected ? ack.message : nil
                    madeProgress = true
                } catch HealthCoachError.sequenceGap {
                    continue
                } catch {
                    _ = try? store.markWatchCommandTerminal(command, message: error.localizedDescription)
                    let ack = WatchCommandAck(commandID: command.id, sessionID: command.sessionID, sequence: command.sequence, status: .rejected, message: error.localizedDescription, phoneRevision: (try? store.currentWatermark()) ?? 0)
                    watchBridge?.send(WatchTransfer(kind: "acknowledgment", acknowledgment: ack))
                    watchLastError = error.localizedDescription
                    madeProgress = true
                }
            }
        }
        refresh()
    }

    private func publishWatchSnapshot() {
        guard let store, let snapshot = try? store.latestWatchSnapshot() else { return }
        watchBridge?.send(snapshot: snapshot)
    }

    private func localDate(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
