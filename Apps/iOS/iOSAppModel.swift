import Foundation
import SwiftUI
import HealthCoachKit

func healthCoachDecimal(_ value: Double, fractionDigits: Int = 1) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: NSNumber(value: value)) ?? value.description
}

func healthCoachDouble(_ text: String) -> Double? {
    Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
}

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
    private var automaticSyncTask: Task<Void, Never>?
    #if canImport(HealthKit)
    private var healthKitReader: HealthKitReader?
    private var healthKitNutritionWriter: HealthKitNutritionWriter?
    private var healthKitWorkoutWriter: HealthKitWorkoutWriter?
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
    @Published private(set) var healthKitNutritionMessage: String?
    @Published private(set) var healthKitWorkoutMessage: String?
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
            healthKitNutritionWriter = HealthKitNutritionWriter(healthStore: reader.healthStore)
            healthKitWorkoutWriter = HealthKitWorkoutWriter(healthStore: reader.healthStore)
            reader.registerBackgroundObservers(store: store)
        }
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("--reset-program-requests") {
            do { _ = try store?.resetProgramRequests() }
            catch { lastError = error.localizedDescription }
        }
        #endif
        do { _ = try store?.deduplicateActiveProgramJobs() }
        catch { lastError = error.localizedDescription }
        refresh()
        publishWatchSnapshot()
    }

    deinit {
        syncTask?.cancel()
        automaticSyncTask?.cancel()
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

    var todayWorkoutSetCount: Int {
        workouts
            .filter { $0.localDate == today }
            .reduce(0) { $0 + $1.setCount }
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

    var programSetupMissingFields: [String] {
        var missing: [String] = []
        if goals.primaryGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            missing.append("primary goal")
        }
        if !(currentMeasurementValue(for: .weight)?.isFinite ?? false) || (currentMeasurementValue(for: .weight) ?? 0) <= 0 {
            missing.append("current weight")
        }
        if !(currentMeasurementValue(for: .bodyFat)?.isFinite ?? false) || !(0...100).contains(currentMeasurementValue(for: .bodyFat) ?? -1) {
            missing.append("current body-fat percentage")
        }
        if !(currentMeasurementValue(for: .waist)?.isFinite ?? false) || (currentMeasurementValue(for: .waist) ?? 0) <= 0 {
            missing.append("current waist")
        }
        if !(goals.targetWeightKg?.isFinite ?? false) || (goals.targetWeightKg ?? 0) <= 0 {
            missing.append("target weight")
        }
        if !(goals.targetBodyFatPercent?.isFinite ?? false) || !(0...100).contains(goals.targetBodyFatPercent ?? -1) {
            missing.append("target body-fat percentage")
        }
        if !(goals.targetTimeframeWeeks.map({ (1...520).contains($0) }) ?? false) {
            missing.append("target timeframe")
        }
        if !(profile.trainingExperienceMonths.map({ $0 >= 0 }) ?? false) {
            missing.append("training experience")
        }
        if !(profile.recentBreakWeeks.map({ $0 >= 0 }) ?? false) {
            missing.append("recent training break")
        }
        if equipment.facilityType == nil {
            missing.append("facility type")
        }
        return missing
    }

    func currentMeasurementValue(for kind: MeasurementKind) -> Double? {
        measurements
            .filter { $0.kind == kind && $0.value.isFinite && $0.value > 0 }
            .max { $0.measuredAt < $1.measuredAt }?
            .value
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
        Array(
            programs
                .filter { $0.status == .proposed }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(1)
        )
    }

    var programJobs: [CoachJob] {
        jobs
            .filter { $0.kind == .generateProgram }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeProgramJob: CoachJob? {
        programJobs.first(where: { $0.status == .queued || $0.status == .running })
    }

    var activeEquipmentDiscoveryJob: CoachJob? {
        jobs
            .filter { $0.kind == .discoverEquipment }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first(where: { $0.status == .queued || $0.status == .running })
    }

    var latestProgramJob: CoachJob? {
        activeProgramJob ?? programJobs.first
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

    func startAutomaticSync() {
        guard automaticSyncTask == nil else {
            syncNow()
            return
        }
        syncNow()
        automaticSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.syncNow()
            }
        }
    }

    func stopAutomaticSync() {
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
    }

    func analysisJob(for meal: Meal) -> CoachJob? {
        jobs
            .filter { $0.kind == .analyzeMeal && $0.request.mealID == meal.id }
            .sorted { $0.requestGeneration > $1.requestGeneration }
            .first
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

    func saveProfile(displayName: String, experience: ExperienceLevel, daysPerWeek: Int, duration: Int, constraints: String, preferences: [String], trainingExperienceMonths: Int? = nil, recentBreakWeeks: Int? = nil) {
        guard let store else { return }
        do {
            var value = profile
            value.displayName = displayName
            value.experience = experience
            value.trainingExperienceMonths = trainingExperienceMonths
            value.recentBreakWeeks = recentBreakWeeks
            value.daysPerWeek = daysPerWeek
            value.sessionDurationMinutes = duration
            value.scheduleConstraints = constraints
            value.exercisePreferences = preferences
            try store.saveProfile(value)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func saveGoals(currentWeight: Double?, targetWeight: Double?, bodyFat: Double?, waist: Double?, primaryGoal: String? = nil, timeframeWeeks: Int? = nil) {
        guard let store else { return }
        do {
            var value = goals
            value.primaryGoal = primaryGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
            value.currentWeightKg = currentWeight
            value.targetWeightKg = targetWeight
            value.targetBodyFatPercent = bodyFat
            value.targetWaistCm = waist
            value.targetTimeframeWeeks = timeframeWeeks
            try store.saveGoals(value)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func saveEquipment(available: [String], excluded: [String], facilityType: EquipmentFacilityType? = nil, facilityName: String? = nil, referencePhotos: [Data]? = nil, onlineLookupAllowed: Bool? = nil) {
        guard let store else { return }
        do {
            var value = equipment
            value.available = available
            value.excluded = excluded
            if let facilityType { value.facilityType = facilityType }
            if let facilityName { value.facilityName = facilityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : facilityName.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let referencePhotos { value.referencePhotos = referencePhotos }
            if let onlineLookupAllowed { value.onlineLookupAllowed = onlineLookupAllowed }
            try store.saveEquipment(value)
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func requestEquipmentDiscovery(facilityType: EquipmentFacilityType, facilityName: String?, referencePhotos: [Data], allowsOnlineLookup: Bool) {
        guard let store else { return }
        let trimmedName = facilityName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !referencePhotos.isEmpty || (allowsOnlineLookup && !(trimmedName?.isEmpty ?? true)) else { return }
        do {
            _ = try store.createJob(
                kind: .discoverEquipment,
                request: JobRequest(
                    facilityType: facilityType,
                    facilityName: trimmedName?.isEmpty == true ? nil : trimmedName,
                    referenceImageData: referencePhotos,
                    allowsOnlineLookup: allowsOnlineLookup
                ),
                inputRevision: max(profile.revision, goals.revision),
                sourceRevision: equipment.revision
            )
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

    func exportMealNutritionToHealthKit(_ meal: Meal) {
        #if canImport(HealthKit)
        guard let analysis = meal.analysis else {
            healthKitNutritionMessage = "This meal does not have a nutrition estimate yet."
            return
        }
        let writer = healthKitNutritionWriter ?? HealthKitNutritionWriter()
        healthKitNutritionWriter = writer
        healthKitNutritionMessage = "Requesting Apple Health permission…"
        Task { @MainActor [weak self] in
            do {
                try await writer.writeNutrition(for: meal, analysis: analysis)
                self?.healthKitNutritionMessage = "Added this meal's calories and macros to Apple Health."
            } catch {
                self?.healthKitNutritionMessage = error.localizedDescription
            }
        }
        #else
        healthKitNutritionMessage = "Apple Health is unavailable on this build."
        #endif
    }

    func exportWorkoutToHealthKit(_ session: WorkoutSession) {
        #if canImport(HealthKit)
        if session.liveMetrics != nil {
            healthKitWorkoutMessage = "This session was recorded by Apple Watch; no duplicate iPhone workout was added."
            return
        }
        let writer = healthKitWorkoutWriter ?? HealthKitWorkoutWriter()
        healthKitWorkoutWriter = writer
        healthKitWorkoutMessage = "Requesting Apple Health permission…"
        Task { @MainActor [weak self] in
            do {
                _ = try await writer.writeManualWorkout(for: session)
                self?.healthKitWorkoutMessage = "Added this strength workout to Apple Health. Active energy was unavailable on iPhone."
            } catch {
                self?.healthKitWorkoutMessage = error.localizedDescription
            }
        }
        #else
        healthKitWorkoutMessage = "Apple Health is unavailable on this build."
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
        guard programSetupMissingFields.isEmpty else {
            lastError = "Complete the program setup before requesting a plan."
            return
        }
        do {
            _ = try store.createJob(
                kind: .generateProgram,
                request: JobRequest(
                    facilityType: equipment.facilityType,
                    facilityName: equipment.facilityName,
                    referenceImageData: equipment.referencePhotos,
                    allowsOnlineLookup: false
                ),
                inputRevision: max(profile.revision, goals.revision),
                sourceRevision: currentProgram?.revision
            )
            refresh()
        } catch { lastError = error.localizedDescription }
    }

    func acceptProgram(_ program: TrainingProgram) {
        do { _ = try store?.acceptProgram(program); refresh() }
        catch { lastError = "Program changed before acceptance: \(error.localizedDescription)" }
    }

    func rejectProgram(_ program: TrainingProgram) {
        do { _ = try store?.rejectProgram(program); refresh() }
        catch { lastError = "Program changed before rejection: \(error.localizedDescription)" }
    }

    func removeCurrentProgram() {
        do { _ = try store?.archiveCurrentProgram(); refresh() }
        catch { lastError = error.localizedDescription }
    }

    func programJob(for program: TrainingProgram) -> CoachJob? {
        guard let sourceJobID = program.sourceJobID else { return nil }
        return jobs.first(where: { $0.id == sourceJobID })
    }

    func requestProgramModification(for program: TrainingProgram, question: String, referencePhotos: [Data] = []) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty else { return }
        do {
            _ = try store.createJob(
                kind: .generateProgram,
                request: JobRequest(
                    programID: program.id,
                    question: trimmed,
                    facilityType: equipment.facilityType,
                    facilityName: equipment.facilityName,
                    referenceImageData: referencePhotos,
                    allowsOnlineLookup: false
                ),
                inputRevision: max(profile.revision, goals.revision),
                sourceRevision: program.revision
            )
            refresh()
        } catch { lastError = error.localizedDescription }
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

    func resetProgramRequests() {
        do {
            _ = try store?.resetProgramRequests()
            refresh()
        } catch { lastError = error.localizedDescription }
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
