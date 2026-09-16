import Foundation
import GRDB

public struct JobSnapshotArtifact: Sendable, Equatable {
    public let path: URL
    public let context: JobContext

    public init(path: URL, context: JobContext) {
        self.path = path
        self.context = context
    }
}

public final class HealthCoachStore: @unchecked Sendable {
    public let databaseURL: URL?
    private let database: DatabaseQueue

    public init(path: URL) throws {
        self.databaseURL = path
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.label = "HealthCoachStore"
        configuration.journalMode = .wal
        self.database = try DatabaseQueue(path: path.path, configuration: configuration)
        try migrate()
        try recoverStagedSnapshots()
        excludeFromBackup(path)
    }

    /// Opens a mirror or per-job snapshot without obtaining a write handle.
    /// The MCP process uses this initializer so a model tool can never mutate
    /// the database even if a future tool handler is accidentally wired wrong.
    public init(readOnlyPath path: URL) throws {
        self.databaseURL = path
        var configuration = Configuration()
        configuration.label = "HealthCoachReadOnlyStore"
        configuration.readonly = true
        self.database = try DatabaseQueue(path: path.path, configuration: configuration)
    }

    public convenience init(path: String) throws {
        try self.init(path: URL(fileURLWithPath: path))
    }

    public init(inMemory: Bool) throws {
        guard inMemory else {
            throw HealthCoachError.invalidInput("Use init(path:) for a persistent database.")
        }
        self.databaseURL = nil
        let configuration = Configuration()
        self.database = try DatabaseQueue(configuration: configuration)
        try migrate()
    }

    public static func applicationSupportURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("HealthCoach", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("healthcoach.sqlite")
    }

    public func transactionForTesting<T>(_ body: (HealthCoachStore) throws -> T) rethrows -> T {
        try body(self)
    }

    public var activePairID: UUID? {
        try? database.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'active_pair_id'") else { return nil }
            return UUID(uuidString: value)
        }
    }

    public func setActivePair(_ pairID: UUID?) throws {
        return try database.write { db in
            if let pairID {
                let previousPair = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'active_pair_id'")
                try setMetadata(db, key: "active_pair_id", value: pairID.uuidString)
                try db.execute(
                    sql: "UPDATE sync_outbox SET pair_id = ? WHERE sender = 'phone' AND (pair_id = 'unpaired' OR pair_id = ?)",
                    arguments: [pairID.uuidString, previousPair ?? "unpaired"]
                )
                if previousPair != pairID.uuidString {
                    // A replacement Mac receives the complete phone snapshot;
                    // old pair-scoped deliveries are not replayed as current.
                    // The current records and job intents are in that
                    // snapshot, so outbox rows from any older pair are no
                    // longer needed.
                    try db.execute(sql: "DELETE FROM sync_outbox WHERE sender = 'phone' AND pair_id != ?", arguments: [pairID.uuidString])
                    try db.execute(sql: "DELETE FROM sync_outbox WHERE sender = 'mac' AND pair_id != ?", arguments: [pairID.uuidString])
                }
            } else {
                try setMetadata(db, key: "active_pair_id", value: "")
            }
        }
    }

    public func analysisPolicy() throws -> AnalysisPolicy {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'analysis_policy'") else {
                return AnalysisPolicy()
            }
            return try HealthCoachJSON.decode(AnalysisPolicy.self, from: data)
        }
    }

    /// The phone keeps this separate from the policy itself so the UI can
    /// distinguish a local pause from a pause the Mac has durably received.
    public func analysisPolicyAcknowledgedRevision() throws -> Int? {
        try database.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'analysis_policy_ack_revision'") else { return nil }
            return Int(value)
        }
    }

    public func recordAnalysisPolicyAcknowledgment(revision: Int) throws {
        try database.write { db in
            let current = try readPolicy(db)
            guard revision <= current.revision else { return }
            try setMetadata(db, key: "analysis_policy_ack_revision", value: String(revision))
        }
    }

    /// Applies the phone-owned analysis policy on the Mac mirror without
    /// creating a reverse mutation. The coordinator has already authenticated
    /// the sender and the Mac must not originate a competing phone policy.
    public func applyRemoteAnalysisPolicy(_ policy: AnalysisPolicy) throws {
        try database.write { db in
            let current = try readPolicy(db)
            guard policy.revision >= current.revision else { return }
            try setPolicy(db, policy)
        }
    }

    @discardableResult
    public func setAnalysisEnabled(_ enabled: Bool) throws -> AnalysisPolicy {
        try database.write { db in
            var policy = try readPolicy(db)
            policy.enabled = enabled
            policy.revision += 1
            policy.updatedAt = Date()
            try setPolicy(db, policy)
            try db.execute(sql: "DELETE FROM app_metadata WHERE key = 'analysis_policy_ack_revision'")
            let watermark = try incrementWatermark(db)
            let payload = try HealthCoachJSON.encode(policy)
            try enqueueMutation(
                db,
                sender: .phone,
                kind: .policy,
                entityType: .preference,
                recordID: "analysis_policy",
                owner: .phone,
                sourceRevision: policy.revision,
                payload: payload,
                sourceWatermark: watermark
            )

            if !enabled {
                let rows = try Row.fetchAll(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ?", arguments: [EntityType.job.rawValue])
                for row in rows {
                    var job = try decodeRow(CoachJob.self, row: row)
                    guard job.intent == .active, job.status == .queued || job.status == .running else { continue }
                    job.intent = .cancelRequested
                    if job.status == .queued { job.status = .cancelled }
                    job.errorMessage = "Analysis is paused on the iPhone."
                    job.updatedAt = Date()
                    _ = try putEntity(
                        db: db,
                        entityType: .job,
                        recordID: job.id.uuidString,
                        owner: .phone,
                        revision: job.inputRevision,
                        updatedAt: job.updatedAt,
                        deletedAt: nil,
                        payload: try HealthCoachJSON.encode(job),
                        requireNewer: false
                    )
                    let jobWatermark = try incrementWatermark(db)
                    try enqueueMutation(
                        db,
                        sender: .phone,
                        kind: .jobCommand,
                        entityType: .job,
                        recordID: job.id.uuidString,
                        owner: .phone,
                        sourceRevision: job.inputRevision,
                        payload: try HealthCoachJSON.encode(job),
                        sourceWatermark: jobWatermark
                    )
                }
            }
            return policy
        }
    }

    public func profile() throws -> UserProfile? {
        try read(.profile, id: "profile")
    }

    public func saveProfile(_ profile: UserProfile) throws {
        guard (1...7).contains(profile.daysPerWeek), profile.sessionDurationMinutes > 0 else {
            throw HealthCoachError.invalidInput("Training days must be between 1 and 7 and session duration must be positive.")
        }
        var profile = profile
        if let current = try self.profile(), current.revision >= profile.revision {
            profile.revision = current.revision + 1
            profile.updatedAt = Date()
        }
        try saveLocal(profile, entityType: .profile, recordID: "profile", revision: profile.revision)
    }

    public func goals() throws -> Goals? {
        try read(.goals, id: "goals")
    }

    public func saveGoals(_ goals: Goals) throws {
        let values = [goals.currentWeightKg, goals.targetWeightKg, goals.targetBodyFatPercent, goals.targetWaistCm].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw HealthCoachError.invalidInput("Goal values must be finite and non-negative.")
        }
        var goals = goals
        if let current = try self.goals(), current.revision >= goals.revision {
            goals.revision = current.revision + 1
            goals.updatedAt = Date()
        }
        try saveLocal(goals, entityType: .goals, recordID: "goals", revision: goals.revision)
    }

    public func measurements(includeDeleted: Bool = false) throws -> [Measurement] {
        try list(.measurement, includeDeleted: includeDeleted)
    }

    public func saveMeasurement(_ measurement: Measurement) throws {
        guard measurement.value.isFinite, measurement.value >= 0 else {
            throw HealthCoachError.invalidInput("Measurement must be finite and non-negative.")
        }
        var measurement = measurement
        if let current: Measurement = try read(.measurement, id: measurement.id.uuidString), current.revision >= measurement.revision {
            measurement.revision = current.revision + 1
            measurement.updatedAt = Date()
        }
        try saveLocal(measurement, entityType: .measurement, recordID: measurement.id.uuidString, revision: measurement.revision)
    }

    public func deleteMeasurement(id: UUID) throws {
        guard var measurement: Measurement = try read(.measurement, id: id.uuidString) else { return }
        measurement.revision += 1
        measurement.deletedAt = Date()
        measurement.updatedAt = Date()
        try saveLocal(measurement, entityType: .measurement, recordID: id.uuidString, revision: measurement.revision, mutationKind: .userDelete, deletedAt: measurement.deletedAt)
    }

    public func meals(includeDeleted: Bool = false) throws -> [Meal] {
        try list(.meal, includeDeleted: includeDeleted)
    }

    public func meal(id: UUID) throws -> Meal? {
        try read(.meal, id: id.uuidString)
    }

    @discardableResult
    public func saveMeal(_ meal: Meal, enqueueAnalysis: Bool = true) throws -> Meal {
        guard !meal.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HealthCoachError.invalidInput("Meal text cannot be empty.")
        }
        return try database.write { db in
            var meal = meal
            let isExplicitCorrection = !enqueueAnalysis && meal.corrected && meal.analysis != nil
            if let current: Meal = try read(.meal, id: meal.id.uuidString, db: db) {
                if isExplicitCorrection {
                    if meal.revision <= current.revision {
                        meal.revision = current.revision + 1
                        meal.updatedAt = Date()
                    }
                    if var analysis = meal.analysis {
                        analysis.sourceMealRevision = meal.revision
                        meal.analysis = analysis
                    }
                } else if meal.revision <= current.revision {
                    meal.revision = current.revision + 1
                    meal.revisions = current.revisions + [MealTextRevision(revision: meal.revision, text: meal.originalText)]
                    meal.analysis = nil
                    meal.corrected = false
                    meal.analysisStatus = .none
                } else if meal.originalText != current.originalText {
                    // A caller may already have allocated the next revision
                    // (the iPhone editor does this). Text changes always
                    // invalidate the estimate/correction, regardless of who
                    // allocated that revision.
                    meal.analysis = nil
                    meal.corrected = false
                    meal.analysisStatus = .none
                }
            }
            var job: CoachJob?
            let policyEnabled = try readPolicy(db).enabled
            if enqueueAnalysis && meal.deletedAt == nil && policyEnabled {
                meal.analysisStatus = .queued
                meal.analysis = nil
                job = try makeJob(
                    db,
                    kind: .analyzeMeal,
                    request: JobRequest(mealID: meal.id),
                    inputRevision: meal.revision,
                    sourceRevision: meal.revision
                )
            }
            meal.updatedAt = Date()
            let payload = try HealthCoachJSON.encode(meal)
            let watermark = try incrementWatermark(db)
            _ = try putEntity(
                db: db,
                entityType: .meal,
                recordID: meal.id.uuidString,
                owner: .phone,
                revision: meal.revision,
                updatedAt: meal.updatedAt,
                deletedAt: meal.deletedAt,
                payload: payload,
                requireNewer: true
            )
            try enqueueMutation(
                db,
                sender: .phone,
                kind: meal.deletedAt == nil ? .userUpsert : .userDelete,
                entityType: .meal,
                recordID: meal.id.uuidString,
                owner: .phone,
                sourceRevision: meal.revision,
                payload: payload,
                sourceWatermark: watermark
            )
            _ = job
            return meal
        }
    }

    public func deleteMeal(id: UUID) throws {
        try database.write { db in
            guard var meal: Meal = try read(.meal, id: id.uuidString, db: db) else { return }
            meal.revision += 1
            meal.deletedAt = Date()
            meal.updatedAt = Date()
            meal.analysis = nil
            meal.analysisStatus = .cancelled
            let mealPayload = try HealthCoachJSON.encode(meal)
            let mealWatermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: .meal, recordID: id.uuidString, owner: .phone, revision: meal.revision, updatedAt: meal.updatedAt, deletedAt: meal.deletedAt, payload: mealPayload, requireNewer: true)
            try enqueueMutation(db, sender: .phone, kind: .userDelete, entityType: .meal, recordID: id.uuidString, owner: .phone, sourceRevision: meal.revision, payload: mealPayload, sourceWatermark: mealWatermark)
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ?", arguments: [EntityType.job.rawValue])
            for row in rows {
                var job = try decodeRow(CoachJob.self, row: row)
                guard job.request.mealID == id, job.status == .queued || job.status == .running else { continue }
                job.intent = .cancelRequested
                if job.status == .queued { job.status = .cancelled }
                job.errorMessage = "The source meal was deleted."
                job.updatedAt = Date()
                let payload = try HealthCoachJSON.encode(job)
                let watermark = try incrementWatermark(db)
                _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .phone, revision: job.inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: payload, requireNewer: false)
                try enqueueMutation(db, sender: .phone, kind: .jobCommand, entityType: .job, recordID: job.id.uuidString, owner: .phone, sourceRevision: job.sourceRevision, payload: payload, sourceWatermark: watermark)
            }
        }
    }

    public func saveCorrection(_ correction: UserCorrection) throws {
        var correction = correction
        if let current: UserCorrection = try read(.correction, id: correction.id.uuidString), current.revision >= correction.revision {
            correction.revision = current.revision + 1
        }
        try saveLocal(correction, entityType: .correction, recordID: correction.id.uuidString, revision: correction.revision)
    }

    public func corrections() throws -> [UserCorrection] {
        try list(.correction)
    }

    public func workouts(includeDeleted: Bool = false) throws -> [WorkoutSession] {
        try list(.workoutSession, includeDeleted: includeDeleted)
    }

    public func trainingSets(includeDeleted: Bool = false) throws -> [TrainingSet] {
        try list(.trainingSet, includeDeleted: includeDeleted)
    }

    @discardableResult
    public func startSession(program: TrainingProgram? = nil, localDate: String) throws -> WorkoutSession {
        let session = WorkoutSession(
            localDate: localDate,
            programID: program?.id,
            programRevision: program?.revision,
            status: .active
        )
        try saveLocal(session, entityType: .workoutSession, recordID: session.id.uuidString, revision: session.revision)
        return session
    }

    @discardableResult
    public func recordSet(_ set: TrainingSet) throws -> TrainingSet {
        guard set.reps > 0, set.loadKg.isFinite, set.loadKg >= 0 else {
            throw HealthCoachError.invalidInput("Reps must be positive and load must be finite and non-negative.")
        }
        return try database.write { db in
            guard let session: WorkoutSession = try read(.workoutSession, id: set.sessionID.uuidString, db: db), session.status == .active else {
                throw HealthCoachError.invalidInput("The session is not available.")
            }
            guard set.programID == session.programID, set.programRevision == session.programRevision else {
                throw HealthCoachError.invalidInput("The set belongs to another program revision.")
            }
            if let programID = session.programID, let originalRevision = session.programRevision {
                guard let program: TrainingProgram = try read(.trainingProgram, id: programID.uuidString, db: db),
                      program.revision == originalRevision,
                      program.days.flatMap(\.exercises).contains(where: { $0.exerciseID == set.exerciseID }) else {
                    throw HealthCoachError.invalidInput("The exercise is not available in the session's program revision.")
                }
            } else {
                guard set.exerciseID.matchesStableExerciseID else {
                    throw HealthCoachError.invalidInput("The exercise id is invalid.")
                }
            }
            if let existing: TrainingSet = try read(.trainingSet, id: set.id.uuidString, db: db) { return existing }
            let payload = try HealthCoachJSON.encode(set)
            let watermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: .trainingSet, recordID: set.id.uuidString, owner: .phone, revision: set.revision, updatedAt: set.updatedAt, deletedAt: nil, payload: payload, requireNewer: true)
            try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .trainingSet, recordID: set.id.uuidString, owner: .phone, sourceRevision: set.revision, payload: payload, sourceWatermark: watermark)
            var updatedSession = session
            updatedSession.setCount += 1
            updatedSession.revision += 1
            updatedSession.updatedAt = Date()
            let sessionPayload = try HealthCoachJSON.encode(updatedSession)
            let sessionWatermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: .workoutSession, recordID: updatedSession.id.uuidString, owner: .phone, revision: updatedSession.revision, updatedAt: updatedSession.updatedAt, deletedAt: nil, payload: sessionPayload, requireNewer: false)
            try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .workoutSession, recordID: updatedSession.id.uuidString, owner: .phone, sourceRevision: updatedSession.revision, payload: sessionPayload, sourceWatermark: sessionWatermark)
            return set
        }
    }

    @discardableResult
    public func finishSession(id: UUID, endedAt: Date = Date()) throws -> WorkoutSession {
        guard var session: WorkoutSession = try read(.workoutSession, id: id.uuidString) else {
            throw HealthCoachError.invalidInput("The session does not exist.")
        }
        if session.status == .completed { return session }
        guard session.status == .active else { throw HealthCoachError.invalidInput("The session is deleted.") }
        session.status = .completed
        session.endedAt = endedAt
        session.revision += 1
        session.updatedAt = Date()
        try saveLocal(session, entityType: .workoutSession, recordID: id.uuidString, revision: session.revision)
        return session
    }

    public func currentProgram() throws -> TrainingProgram? {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ? AND deleted_at IS NULL ORDER BY updated_at DESC", arguments: [EntityType.trainingProgram.rawValue])
            let programs = try rows.map { try decodeRow(TrainingProgram.self, row: $0) }
            return programs.first(where: { $0.status == .current })
        }
    }

    public func programs(includeDeleted: Bool = false) throws -> [TrainingProgram] {
        try list(.trainingProgram, includeDeleted: includeDeleted)
    }

    public func saveProgram(_ program: TrainingProgram) throws {
        let equipment = try self.equipment()
        try program.validate(excludedEquipment: Set(equipment?.excluded ?? []))
        try database.write { db in
            var program = program
            if let current: TrainingProgram = try read(.trainingProgram, id: program.id.uuidString, db: db), current.revision >= program.revision {
                program.revision = current.revision + 1
                program.updatedAt = Date()
            }
            let payload = try HealthCoachJSON.encode(program)
            let watermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: .trainingProgram, recordID: program.id.uuidString, owner: .phone, revision: program.revision, updatedAt: program.updatedAt, deletedAt: nil, payload: payload, requireNewer: true)
            try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .trainingProgram, recordID: program.id.uuidString, owner: .phone, sourceRevision: program.revision, payload: payload, sourceWatermark: watermark)
            try upsertExerciseLibrary(db: db, program: program, enqueue: true)
        }
    }

    @discardableResult
    public func acceptProgram(_ proposed: TrainingProgram) throws -> TrainingProgram {
        let equipment = try self.equipment()
        try proposed.validate(excludedEquipment: Set(equipment?.excluded ?? []))
        return try database.write { db in
            guard let stored: TrainingProgram = try read(.trainingProgram, id: proposed.id.uuidString, db: db),
                  sameTrainingProgramContent(stored, proposed),
                  stored.status == .proposed || stored.status == .current else {
                throw HealthCoachError.staleRevision
            }
            let profileRevision = (try read(.profile, id: "profile", db: db) as UserProfile?)?.revision ?? 1
            let goalsRevision = (try read(.goals, id: "goals", db: db) as Goals?)?.revision ?? 1
            guard proposed.inputRevision == max(profileRevision, goalsRevision) else {
                throw HealthCoachError.staleRevision
            }
            if let sourceJobID = stored.sourceJobID,
               let sourceJob: CoachJob = try read(.job, id: sourceJobID.uuidString, db: db),
               let sourceRevision = sourceJob.sourceRevision {
                let currentProgram = try Row.fetchAll(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ? AND deleted_at IS NULL", arguments: [EntityType.trainingProgram.rawValue])
                    .compactMap { try? decodeRow(TrainingProgram.self, row: $0) }
                    .first(where: { $0.status == .current && $0.id != stored.id })
                guard currentProgram?.revision == sourceRevision else { throw HealthCoachError.staleRevision }
            }
            let currentRows = try Row.fetchAll(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ? AND deleted_at IS NULL", arguments: [EntityType.trainingProgram.rawValue])
            for row in currentRows {
                guard var current = try? decodeRow(TrainingProgram.self, row: row), current.status == .current, current.id != proposed.id else { continue }
                current.status = .archived
                current.updatedAt = Date()
                let payload = try HealthCoachJSON.encode(current)
                let watermark = try incrementWatermark(db)
                _ = try putEntity(db: db, entityType: .trainingProgram, recordID: current.id.uuidString, owner: .phone, revision: current.revision, updatedAt: current.updatedAt, deletedAt: nil, payload: payload, requireNewer: false)
                try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .trainingProgram, recordID: current.id.uuidString, owner: .phone, sourceRevision: current.revision, payload: payload, sourceWatermark: watermark)
            }
            var accepted = proposed
            accepted.status = .current
            accepted.acceptedAt = Date()
            accepted.updatedAt = Date()
            let payload = try HealthCoachJSON.encode(accepted)
            let watermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: .trainingProgram, recordID: accepted.id.uuidString, owner: .phone, revision: accepted.revision, updatedAt: accepted.updatedAt, deletedAt: nil, payload: payload, requireNewer: false)
            try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .trainingProgram, recordID: accepted.id.uuidString, owner: .phone, sourceRevision: accepted.revision, payload: payload, sourceWatermark: watermark)
            try upsertExerciseLibrary(db: db, program: accepted, enqueue: true)
            return accepted
        }
    }

    public func equipment() throws -> EquipmentProfile? {
        try read(.equipment, id: "equipment")
    }

    public func saveEquipment(_ equipment: EquipmentProfile) throws {
        var equipment = equipment
        if let current = try self.equipment(), current.revision >= equipment.revision {
            equipment.revision = current.revision + 1
            equipment.updatedAt = Date()
        }
        try saveLocal(equipment, entityType: .equipment, recordID: "equipment", revision: equipment.revision)
    }

    public func exercises() throws -> [Exercise] {
        try list(.exercise)
    }

    public func healthSummaries() throws -> [HealthSummary] {
        try list(.healthSummary)
    }

    public func saveHealthSummary(_ summary: HealthSummary, enqueue: Bool = true) throws {
        try saveLocal(summary, entityType: .healthSummary, recordID: summary.id.uuidString, revision: summary.revision, enqueue: enqueue)
    }

    public func healthKitAnchor(sampleType: String) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: ["healthkit.anchor." + sampleType])
        }
    }

    public func healthKitAffectedLocalDates(sampleType: String) throws -> [String] {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: ["healthkit.days." + sampleType]) else { return [] }
            return (try? HealthCoachJSON.decode([String].self, from: data)) ?? []
        }
    }

    public func healthKitSampleLocalDates(sampleType: String) throws -> [String: String] {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: ["healthkit.samples." + sampleType]) else { return [:] }
            return (try? HealthCoachJSON.decode([String: String].self, from: data)) ?? [:]
        }
    }

    /// Commits normalized HealthKit replacements/tombstones, sample anchors,
    /// and the phone outbox as one transaction. LAN sync and Codex are never
    /// called from this method or from an observer delivery completion block.
    public func persistHealthKitBatch(
        summaries: [HealthSummary],
        measurements: [Measurement] = [],
        deletedMeasurements: [Measurement] = [],
        anchors: [HealthKitAnchorUpdate]
    ) throws {
        try database.write { db in
            for summary in summaries {
                var summary = summary
                if let existing: HealthSummary = try read(.healthSummary, id: summary.id.uuidString, db: db), existing.revision >= summary.revision {
                    summary.revision = existing.revision + 1
                    summary.updatedAt = Date()
                }
                try putPhoneHealthRecord(db: db, entityType: .healthSummary, recordID: summary.id.uuidString, revision: summary.revision, deletedAt: nil, payload: try HealthCoachJSON.encode(summary))
            }
            let existingMeasurements = try list(Measurement.self, entityType: .measurement, db: db, includeDeleted: true)
            let existingExternalIDs = Set(existingMeasurements.compactMap(\.externalID))
            for measurement in measurements {
                if let externalID = measurement.externalID,
                   let existing = existingMeasurements.first(where: { $0.externalID == externalID }) {
                    guard existing.value != measurement.value || existing.measuredAt != measurement.measuredAt || existing.deletedAt != measurement.deletedAt else { continue }
                    var replacement = measurement
                    replacement.revision = max(measurement.revision, existing.revision + 1)
                    try putPhoneHealthRecord(db: db, entityType: .measurement, recordID: replacement.id.uuidString, revision: replacement.revision, deletedAt: replacement.deletedAt, payload: try HealthCoachJSON.encode(replacement))
                } else if measurement.externalID == nil || !existingExternalIDs.contains(measurement.externalID!) {
                    try putPhoneHealthRecord(db: db, entityType: .measurement, recordID: measurement.id.uuidString, revision: measurement.revision, deletedAt: measurement.deletedAt, payload: try HealthCoachJSON.encode(measurement))
                }
            }
            for measurement in deletedMeasurements {
                var tombstone = measurement
                tombstone.deletedAt = tombstone.deletedAt ?? Date()
                tombstone.revision = max(tombstone.revision, (existingMeasurements.first(where: { $0.externalID == tombstone.externalID })?.revision ?? 0) + 1)
                try putPhoneHealthRecord(db: db, entityType: .measurement, recordID: tombstone.id.uuidString, revision: tombstone.revision, deletedAt: tombstone.deletedAt, payload: try HealthCoachJSON.encode(tombstone))
            }
            for anchor in anchors {
                try setMetadata(db, key: "healthkit.anchor." + anchor.sampleType, data: anchor.anchorData)
                let existingDays = (try? HealthCoachJSON.decode([String].self, from: Data.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: ["healthkit.days." + anchor.sampleType]) ?? Data())) ?? []
                let mergedDays = Array(Set(existingDays + anchor.affectedLocalDates)).sorted().suffix(HealthCoachConstants.maximumHistoryDays)
                try setMetadata(db, key: "healthkit.days." + anchor.sampleType, data: try HealthCoachJSON.encode(Array(mergedDays)))
                let oldMap = (try? HealthCoachJSON.decode([String: String].self, from: Data.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: ["healthkit.samples." + anchor.sampleType]) ?? Data())) ?? [:]
                var mergedMap = oldMap
                for removedID in anchor.removedSampleIDs { mergedMap.removeValue(forKey: removedID) }
                mergedMap.merge(anchor.sampleLocalDates) { _, new in new }
                mergedMap = Dictionary(mergedMap.sorted { $0.key < $1.key }.suffix(2_000), uniquingKeysWith: { first, _ in first })
                try setMetadata(db, key: "healthkit.samples." + anchor.sampleType, data: try HealthCoachJSON.encode(mergedMap))
            }
        }
    }

    public func jobs() throws -> [CoachJob] {
        try list(.job)
    }

    public func job(id: UUID) throws -> CoachJob? {
        try read(.job, id: id.uuidString)
    }

    public func recordMacExecutionUpdate(_ update: JobExecutionUpdate) throws {
        try database.write { db in
            try applyJobExecutionUpdate(update, db: db, enqueue: true)
        }
    }

    public func recordMacResult(_ result: JobResultEnvelope) throws {
        try database.write { db in
            try applyJobResult(result, db: db, enqueue: true)
        }
    }

    public func pendingJobs() throws -> [CoachJob] {
        try jobs().filter { $0.status == .queued || $0.status == .running }
    }

    @discardableResult
    public func createJob(kind: JobKind, request: JobRequest, inputRevision: Int, sourceRevision: Int? = nil) throws -> CoachJob {
        guard try analysisPolicy().enabled else { throw HealthCoachError.unavailable("Analysis is paused on the iPhone.") }
        return try database.write { db in
            try makeJob(db, kind: kind, request: request, inputRevision: inputRevision, sourceRevision: sourceRevision)
        }
    }

    /// Invalidates the current estimate and queues one fresh meal analysis in
    /// the same transaction as the visible meal status. This keeps daily
    /// totals from presenting an older estimate while a retry is pending.
    @discardableResult
    public func requestMealAnalysis(id: UUID) throws -> CoachJob {
        try database.write { db in
            guard var meal: Meal = try read(.meal, id: id.uuidString, db: db), meal.deletedAt == nil else {
                throw HealthCoachError.invalidInput("The meal is not available for analysis.")
            }
            guard try readPolicy(db).enabled else {
                throw HealthCoachError.unavailable("Analysis is paused on the iPhone.")
            }
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ?", arguments: [EntityType.job.rawValue])
            let existingJobs: [CoachJob] = rows.compactMap { row in
                try? decodeRow(CoachJob.self, row: row)
            }
            let activeMealJobs = existingJobs.filter { job in
                job.kind == .analyzeMeal && job.request.mealID == id && (job.status == .queued || job.status == .running)
            }
            if let existing = activeMealJobs.first {
                return existing
            }
            // Analysis state is part of the replicated meal record. Allocate
            // a new source revision so a Mac mirror cannot discard this
            // invalidation as an equal-revision update.
            meal.revision += 1
            meal.revisions.append(MealTextRevision(revision: meal.revision, text: meal.originalText))
            meal.analysis = nil
            meal.corrected = false
            meal.analysisStatus = .queued
            meal.updatedAt = Date()
            let mealPayload = try HealthCoachJSON.encode(meal)
            let watermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: .meal, recordID: meal.id.uuidString, owner: .phone, revision: meal.revision, updatedAt: meal.updatedAt, deletedAt: nil, payload: mealPayload, requireNewer: false)
            try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .meal, recordID: meal.id.uuidString, owner: .phone, sourceRevision: meal.revision, payload: mealPayload, sourceWatermark: watermark)
            return try makeJob(db, kind: .analyzeMeal, request: JobRequest(mealID: id), inputRevision: meal.revision, sourceRevision: meal.revision)
        }
    }

    public func cancelJob(id: UUID) throws {
        guard var job = try job(id: id) else { return }
        if job.status == .succeeded || job.status == .cancelled { return }
        job.intent = .cancelRequested
        job.status = .cancelled
        job.errorMessage = "Cancellation requested on the iPhone."
        job.updatedAt = Date()
        try writePhoneJobCommand(job)
    }

    @discardableResult
    public func retryJob(id: UUID) throws -> CoachJob {
        guard var job = try job(id: id) else { throw HealthCoachError.invalidInput("The job does not exist.") }
        job.requestGeneration += 1
        job.intent = .active
        job.status = .queued
        job.executionStatus = .notDelivered
        job.attempts = 0
        job.errorMessage = nil
        job.threadID = nil
        job.turnID = nil
        job.updatedAt = Date()
        try writePhoneJobCommand(job)
        return job
    }

    public func captureJobSnapshot(for job: CoachJob, at path: URL) throws -> JobSnapshotArtifact {
        guard databaseURL != nil else { throw HealthCoachError.unavailable("In-memory stores cannot create process snapshots.") }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        let destination = try DatabaseQueue(path: path.path)
        let context = try database.read { sourceDB in
            let context = try jobContext(db: sourceDB, job: job)
            try destination.barrierWriteWithoutTransaction { destinationDB in
                try sourceDB.backup(to: destinationDB)
                _ = try String.fetchOne(destinationDB, sql: "PRAGMA journal_mode = DELETE")
            }
            return context
        }
        try destination.close()
        excludeFromBackup(path)
        return JobSnapshotArtifact(path: path, context: context)
    }

    public func jobContext(for job: CoachJob) throws -> JobContext {
        try database.read { db in try jobContext(db: db, job: job) }
    }

    public func snapshotRecords(limit: Int = 10_000) throws -> [SnapshotRecord] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT entity_type, id, owner, revision, updated_at, deleted_at, payload FROM entity_records ORDER BY entity_type, id LIMIT ?", arguments: [limit])
            return rows.map { row in
                SnapshotRecord(
                    entityType: EntityType(rawValue: row["entity_type"] as String)!,
                    recordID: row["id"] as String,
                    owner: RecordOwner(rawValue: row["owner"] as String)!,
                    revision: row["revision"] as Int,
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double),
                    deletedAt: (row["deleted_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    payload: row["payload"] as Data
                )
            }
        }
    }

    public func currentWatermark() throws -> Int64 {
        try database.read { db in try Int64.fetchOne(db, sql: "SELECT value FROM app_counters WHERE key = 'watermark'") ?? 0 }
    }

    public func appliedSequence(pairID: UUID, sender: SyncSender) throws -> Int64 {
        try database.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT last_sequence FROM sync_cursors WHERE pair_id = ? AND sender = ?",
                arguments: [pairID.uuidString, sender.rawValue]
            ) ?? 0
        }
    }

    public func latestOutboxSequence(sender: SyncSender) throws -> Int64 {
        try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(sequence) FROM sync_outbox WHERE sender = ?", arguments: [sender.rawValue]) ?? 0
        }
    }

    public func makeSnapshotDescriptor(pairID: UUID, sourceSender: SyncSender) throws -> SnapshotDescriptor {
        SnapshotDescriptor(
            pairID: pairID,
            sourceSender: sourceSender,
            sourceWatermark: try currentWatermark(),
            sourceSequence: try latestOutboxSequence(sender: sourceSender),
            recordCount: try snapshotRecords().count
        )
    }

    public func beginSnapshot(_ descriptor: SnapshotDescriptor) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM snapshot_transfers WHERE pair_id = ?", arguments: [descriptor.pairID.uuidString])
            try db.execute(sql: "DELETE FROM snapshot_staging WHERE pair_id = ?", arguments: [descriptor.pairID.uuidString])
            try db.execute(sql: "INSERT INTO snapshot_transfers (pair_id, snapshot_id, source_sender, source_watermark, source_sequence, expected_count, staged_count, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?)", arguments: [descriptor.pairID.uuidString, descriptor.snapshotID.uuidString, descriptor.sourceSender.rawValue, descriptor.sourceWatermark, descriptor.sourceSequence, descriptor.recordCount, Date().timeIntervalSince1970])
        }
    }

    public func stageSnapshotBatch(pairID: UUID, snapshotID: UUID, records: [SnapshotRecord]) throws {
        guard records.count <= HealthCoachConstants.maximumBatchRecords else { throw HealthCoachError.invalidInput("Snapshot batch is too large.") }
        try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM snapshot_transfers WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString]) != nil else { throw HealthCoachError.snapshotIncomplete }
            for record in records {
                try validateSnapshotRecord(record)
                try db.execute(sql: "INSERT OR REPLACE INTO snapshot_staging (pair_id, snapshot_id, entity_type, record_id, owner, revision, updated_at, deleted_at, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [pairID.uuidString, snapshotID.uuidString, record.entityType.rawValue, record.recordID, record.owner.rawValue, record.revision, record.updatedAt.timeIntervalSince1970, record.deletedAt?.timeIntervalSince1970, record.payload])
            }
            try db.execute(sql: "UPDATE snapshot_transfers SET staged_count = (SELECT COUNT(*) FROM snapshot_staging WHERE pair_id = ? AND snapshot_id = ?) WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString, pairID.uuidString, snapshotID.uuidString])
        }
    }

    public func completeSnapshot(pairID: UUID, snapshotID: UUID) throws {
        try database.write { db in
            guard let descriptor = try Row.fetchOne(db, sql: "SELECT source_sender, source_watermark, source_sequence, expected_count, staged_count FROM snapshot_transfers WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString]),
                  (descriptor["expected_count"] as Int) == (descriptor["staged_count"] as Int) else { throw HealthCoachError.snapshotIncomplete }
            let rows = try Row.fetchAll(db, sql: "SELECT entity_type, record_id, owner, revision, updated_at, deleted_at, payload FROM snapshot_staging WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString])
            for row in rows {
                let staged = SnapshotRecord(
                    entityType: EntityType(rawValue: row["entity_type"] as String)!,
                    recordID: row["record_id"] as String,
                    owner: RecordOwner(rawValue: row["owner"] as String)!,
                    revision: row["revision"] as Int,
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double),
                    deletedAt: (row["deleted_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    payload: row["payload"] as Data
                )
                try validateSnapshotRecord(staged)
                _ = try putEntity(
                    db: db,
                    entityType: staged.entityType,
                    recordID: staged.recordID,
                    owner: staged.owner,
                    revision: staged.revision,
                    updatedAt: staged.updatedAt,
                    deletedAt: staged.deletedAt,
                    payload: staged.payload,
                    requireNewer: false
                )
            }
            let sender = SyncSender(rawValue: descriptor["source_sender"] as String)!
            try db.execute(sql: "INSERT INTO sync_cursors (pair_id, sender, last_sequence) VALUES (?, ?, ?) ON CONFLICT(pair_id, sender) DO UPDATE SET last_sequence = excluded.last_sequence", arguments: [pairID.uuidString, sender.rawValue, descriptor["source_sequence"] as Int64])
            try db.execute(sql: "DELETE FROM snapshot_staging WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString])
            try db.execute(sql: "DELETE FROM snapshot_transfers WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString])
        }
    }

    public func discardSnapshot(pairID: UUID, snapshotID: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM snapshot_staging WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString])
            try db.execute(sql: "DELETE FROM snapshot_transfers WHERE pair_id = ? AND snapshot_id = ?", arguments: [pairID.uuidString, snapshotID.uuidString])
        }
    }

    public func pendingOutbox(sender: SyncSender, after sequence: Int64 = 0, limit: Int = HealthCoachConstants.maximumBatchRecords) throws -> [SyncMutation] {
        try database.read { db in
            let activePair = activePairIDString(db)
            let pair = UUID(uuidString: activePair) == nil ? "unpaired" : activePair
            let rows = try Row.fetchAll(db, sql: "SELECT mutation_id, pair_id, sender, sequence, mutation_kind, entity_type, record_id, owner, source_revision, payload, source_watermark, created_at FROM sync_outbox WHERE sender = ? AND pair_id = ? AND sequence > ? ORDER BY sequence LIMIT ?", arguments: [sender.rawValue, pair, sequence, min(limit, HealthCoachConstants.maximumBatchRecords)])
            return rows.map { row in
                SyncMutation(
                    id: UUID(uuidString: row["mutation_id"] as String)!,
                    pairID: UUID(uuidString: row["pair_id"] as String) ?? UUID(),
                    sender: SyncSender(rawValue: row["sender"] as String)!,
                    sequence: row["sequence"] as Int64,
                    mutationKind: SyncMutationKind(rawValue: row["mutation_kind"] as String)!,
                    entityType: (row["entity_type"] as String?).flatMap(EntityType.init(rawValue:)),
                    recordID: row["record_id"] as String?,
                    owner: RecordOwner(rawValue: row["owner"] as String)!,
                    sourceRevision: row["source_revision"] as Int?,
                    payload: row["payload"] as Data,
                    sourceWatermark: row["source_watermark"] as Int64,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
                )
            }
        }
    }

    public func acknowledgeOutbox(pairID: UUID, sender: SyncSender, through sequence: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM sync_outbox WHERE pair_id = ? AND sender = ? AND sequence <= ?", arguments: [pairID.uuidString, sender.rawValue, sequence])
        }
    }

    public func applyIncoming(_ batch: SyncBatch, authenticatedPeerID: UUID, pairID: UUID) throws -> SyncAcknowledgment {
        guard batch.mutations.count <= HealthCoachConstants.maximumBatchRecords,
              batch.mutations.count == 0 || batch.firstSequence <= batch.lastSequence else { throw HealthCoachError.malformedFrame }
        guard authenticatedPeerID != UUID(), batch.mutations.allSatisfy({ $0.pairID == pairID && $0.sender == batch.sender && $0.payload.count <= HealthCoachConstants.maximumFrameBytes }) else { throw HealthCoachError.wrongOwner }
        return try database.write { db in
            let cursor = try Int64.fetchOne(db, sql: "SELECT last_sequence FROM sync_cursors WHERE pair_id = ? AND sender = ?", arguments: [pairID.uuidString, batch.sender.rawValue]) ?? 0
            if batch.lastSequence <= cursor {
                return SyncAcknowledgment(sender: batch.sender, lastSequence: cursor, appliedMutationIDs: [])
            }
            guard batch.firstSequence == cursor + 1 else { throw HealthCoachError.sequenceGap(expected: cursor + 1, received: batch.firstSequence) }
            guard batch.mutations.count == Int(batch.lastSequence - batch.firstSequence + 1) else { throw HealthCoachError.malformedFrame }
            guard batch.mutations.enumerated().allSatisfy({ index, mutation in
                mutation.sequence == batch.firstSequence + Int64(index)
            }) else { throw HealthCoachError.malformedFrame }
            guard Set(batch.mutations.map(\.id)).count == batch.mutations.count else { throw HealthCoachError.malformedFrame }

            var applied: [UUID] = []
            for mutation in batch.mutations {
                try validateRemoteMutation(mutation)
                let alreadyApplied = try Int.fetchOne(db, sql: "SELECT 1 FROM inbox_mutations WHERE pair_id = ? AND sender = ? AND mutation_id = ?", arguments: [pairID.uuidString, mutation.sender.rawValue, mutation.id.uuidString]) != nil
                if !alreadyApplied {
                    try applyRemoteMutation(mutation, db: db)
                    try db.execute(sql: "INSERT INTO inbox_mutations (pair_id, sender, sequence, mutation_id, applied_at) VALUES (?, ?, ?, ?, ?)", arguments: [pairID.uuidString, mutation.sender.rawValue, mutation.sequence, mutation.id.uuidString, Date().timeIntervalSince1970])
                    applied.append(mutation.id)
                }
            }
            try db.execute(sql: "INSERT INTO sync_cursors (pair_id, sender, last_sequence) VALUES (?, ?, ?) ON CONFLICT(pair_id, sender) DO UPDATE SET last_sequence = excluded.last_sequence", arguments: [pairID.uuidString, batch.sender.rawValue, batch.lastSequence])
            return SyncAcknowledgment(sender: batch.sender, lastSequence: batch.lastSequence, appliedMutationIDs: applied)
        }
    }

    public func pendingWatchCommands() throws -> [WatchCommand] {
        try list(.watchCommand).filter { $0.status == .queued }
    }

    public func watchCommands(includeTerminal: Bool = true) throws -> [WatchCommand] {
        let commands: [WatchCommand] = try list(.watchCommand)
        return includeTerminal ? commands : commands.filter { $0.status == .queued }
    }

    public func watchAcks() throws -> [WatchCommandAck] {
        try list(.watchAck)
    }

    public func applyWatchCommand(_ command: WatchCommand) throws -> WatchCommandAck {
        // Persist the incoming queued command outside the application
        // transaction. If validation finds a sequence gap, the command and
        // its entered values survive for a later retry and remain visible.
        var received = command
        received.status = .queued
        received.terminalMessage = nil
        try saveWatchCommand(received)
        return try database.write { db in
            if let existing: WatchCommandAck = try read(.watchAck, id: command.id.uuidString, db: db) {
                switch existing.status {
                case .applied, .duplicate:
                    try saveWatchCommandRecord(db: db, command: command, status: existing.status, terminalMessage: existing.message)
                    return existing
                case .rejected:
                    // A terminal rejection is retryable after the local
                    // condition is repaired. The sequence was not advanced
                    // for a rejected command, so the same UUID can be
                    // re-applied without creating a second logical set.
                    try db.execute(sql: "DELETE FROM entity_records WHERE entity_type = ? AND id = ?", arguments: [EntityType.watchAck.rawValue, command.id.uuidString])
                case .queued:
                    try db.execute(sql: "DELETE FROM entity_records WHERE entity_type = ? AND id = ?", arguments: [EntityType.watchAck.rawValue, command.id.uuidString])
                }
            }
            guard command.sequence > 0 else { return try rejectWatchCommand(db: db, command: command, message: "The Watch sequence is invalid.") }
            if let liveMetrics = command.liveMetrics {
                guard command.kind == .finishSession else {
                    return try rejectWatchCommand(db: db, command: command, message: "Live workout metrics are only valid when finishing a session.")
                }
                do {
                    try liveMetrics.validate()
                } catch {
                    return try rejectWatchCommand(db: db, command: command, message: error.localizedDescription)
                }
            }
            let lastSequence = try Int64.fetchOne(db, sql: "SELECT last_sequence FROM watch_session_sequences WHERE session_id = ?", arguments: [command.sessionID.uuidString]) ?? 0
            guard command.sequence == lastSequence + 1 else {
                // Keep the command queued and unacknowledged. A later retry can
                // fill the gap without turning an ordering problem into a
                // terminal data loss event.
                throw HealthCoachError.sequenceGap(expected: lastSequence + 1, received: command.sequence)
            }
            switch command.kind {
            case .startSession:
                guard let programID = command.programID, let revision = command.programRevision,
                      let program: TrainingProgram = try read(.trainingProgram, id: programID.uuidString, db: db),
                      program.revision == revision else {
                    return try rejectWatchCommand(db: db, command: command, message: "The referenced program revision is unavailable.")
                }
                if let session: WorkoutSession = try read(.workoutSession, id: command.sessionID.uuidString, db: db) {
                    guard session.status != .deleted else { return try rejectWatchCommand(db: db, command: command, message: "The session was deleted.") }
                    guard session.programID == programID, session.programRevision == revision else {
                        return try rejectWatchCommand(db: db, command: command, message: "The session already belongs to another program revision.")
                    }
                } else {
                    let session = WorkoutSession(id: command.sessionID, localDate: localDateString(), programID: programID, programRevision: revision, status: .active)
                    try putWatchPhoneRecord(db: db, session: session)
                }
            case .recordSet:
                guard let exerciseID = command.exerciseID, let reps = command.reps, let load = command.loadKg,
                      exerciseID.matchesStableExerciseID, reps > 0, load.isFinite, load >= 0,
                      let session: WorkoutSession = try read(.workoutSession, id: command.sessionID.uuidString, db: db),
                      session.status == .active,
                      command.programID == session.programID,
                      command.programRevision == session.programRevision else {
                    return try rejectWatchCommand(db: db, command: command, message: "The session or set values are invalid.")
                }
                guard let programID = session.programID,
                      let originalRevision = session.programRevision,
                      let program: TrainingProgram = try read(.trainingProgram, id: programID.uuidString, db: db),
                      program.revision == originalRevision else {
                    return try rejectWatchCommand(db: db, command: command, message: "The original program revision is no longer available.")
                }
                guard program.days.flatMap(\.exercises).contains(where: { $0.exerciseID == exerciseID }) else {
                    return try rejectWatchCommand(db: db, command: command, message: "The exercise is not part of the original program revision.")
                }
                if let rir = command.rir, (!rir.isFinite || rir < 0) {
                    return try rejectWatchCommand(db: db, command: command, message: "The RIR value is invalid.")
                }
                let existingSets = try list(TrainingSet.self, entityType: .trainingSet, db: db).filter { $0.sessionID == command.sessionID }
                let set = TrainingSet(id: UUID(), sessionID: command.sessionID, exerciseID: exerciseID, ordinal: existingSets.count + 1, reps: reps, loadKg: load, rir: command.rir, programID: session.programID, programRevision: session.programRevision)
                try putWatchPhoneRecord(db: db, set: set)
                var updatedSession = session
                updatedSession.setCount += 1
                updatedSession.revision += 1
                updatedSession.updatedAt = Date()
                try putWatchPhoneRecord(db: db, session: updatedSession)
            case .finishSession:
                guard let session: WorkoutSession = try read(.workoutSession, id: command.sessionID.uuidString, db: db), session.status != .deleted else {
                    return try rejectWatchCommand(db: db, command: command, message: "The session does not exist or was deleted.")
                }
                guard command.programID == session.programID, command.programRevision == session.programRevision else {
                    return try rejectWatchCommand(db: db, command: command, message: "The session belongs to another program revision.")
                }
                if session.status == .active {
                    var completed = session
                    completed.status = .completed
                    completed.endedAt = Date()
                    completed.liveMetrics = command.liveMetrics
                    completed.revision += 1
                    completed.updatedAt = Date()
                    try putWatchPhoneRecord(db: db, session: completed)
                }
            }
            try db.execute(
                sql: "INSERT INTO watch_session_sequences (session_id, last_sequence) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET last_sequence = excluded.last_sequence",
                arguments: [command.sessionID.uuidString, command.sequence]
            )
            try saveWatchCommandRecord(db: db, command: command, status: .applied, terminalMessage: nil)
            let ack = try makeWatchAck(db: db, command: command, status: .applied, message: nil)
            try saveWatchAck(db: db, ack: ack)
            return ack
        }
    }

    public func saveWatchCommand(_ command: WatchCommand) throws {
        try database.write { db in
            try saveWatchCommandRecord(db: db, command: command, status: command.status, terminalMessage: command.terminalMessage)
        }
    }

    /// Converts a non-ordering failure into a durable terminal command. The
    /// original typed values remain in the command record for user resolution.
    @discardableResult
    public func markWatchCommandTerminal(_ command: WatchCommand, message: String) throws -> WatchCommandAck {
        try database.write { db in
            try saveWatchCommandRecord(db: db, command: command, status: .rejected, terminalMessage: message)
            let ack = try makeWatchAck(db: db, command: command, status: .rejected, message: message)
            try saveWatchAck(db: db, ack: ack)
            return ack
        }
    }

    public func latestWatchSnapshot() throws -> WatchWorkoutSnapshot {
        let session = try workouts().first(where: { $0.status == .active })
        let allPrograms = try programs()
        let program: TrainingProgram?
        if let session, let programID = session.programID, let programRevision = session.programRevision {
            // An active session keeps displaying and logging against its
            // original immutable revision even after a newer program is
            // accepted on the phone.
            program = allPrograms.first { $0.id == programID && $0.revision == programRevision }
        } else {
            program = allPrograms.first(where: { $0.status == .current })
        }
        let day = program?.days.sorted { $0.order < $1.order }.first
        let exercises = day?.exercises.sorted { $0.order < $1.order }.map {
            WatchExerciseSnapshot(exerciseID: $0.exerciseID, displayName: $0.displayName, order: $0.order, sets: $0.sets, minimumReps: $0.minimumReps, maximumReps: $0.maximumReps, targetRIR: $0.targetRIR, equipment: $0.equipment)
        } ?? []
        return WatchWorkoutSnapshot(
            phoneRevision: try currentWatermark(),
            localDate: localDateString(),
            programID: program?.id,
            programRevision: program?.revision,
            programName: program?.name,
            dayName: day?.name,
            exercises: exercises,
            activeSessionID: session?.id,
            activeSessionSetCount: session?.setCount ?? 0,
            liveMetrics: session?.liveMetrics
        )
    }

    public func recoverStagedSnapshots() throws {
        try database.write { db in
            let snapshots = try Row.fetchAll(db, sql: "SELECT pair_id, snapshot_id FROM snapshot_transfers")
            for row in snapshots {
                let pair = row["pair_id"] as String
                let snapshot = row["snapshot_id"] as String
                try db.execute(sql: "DELETE FROM snapshot_staging WHERE pair_id = ? AND snapshot_id = ?", arguments: [pair, snapshot])
                try db.execute(sql: "DELETE FROM snapshot_transfers WHERE pair_id = ? AND snapshot_id = ?", arguments: [pair, snapshot])
            }
        }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("initial") { db in
            try db.execute(sql: """
                CREATE TABLE app_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL
                );
                CREATE TABLE app_counters (
                    key TEXT PRIMARY KEY NOT NULL,
                    value INTEGER NOT NULL
                );
                INSERT INTO app_counters (key, value) VALUES ('watermark', 0);
                CREATE TABLE entity_records (
                    entity_type TEXT NOT NULL,
                    id TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    updated_at REAL NOT NULL,
                    deleted_at REAL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (entity_type, id)
                );
                CREATE INDEX entity_records_date_index ON entity_records (entity_type, updated_at);
                CREATE TABLE sequence_counters (
                    sender TEXT PRIMARY KEY NOT NULL,
                    value INTEGER NOT NULL
                );
                INSERT INTO sequence_counters (sender, value) VALUES ('phone', 0);
                INSERT INTO sequence_counters (sender, value) VALUES ('mac', 0);
                CREATE TABLE sync_outbox (
                    sender TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    pair_id TEXT NOT NULL,
                    mutation_id TEXT NOT NULL UNIQUE,
                    mutation_kind TEXT NOT NULL,
                    entity_type TEXT,
                    record_id TEXT,
                    owner TEXT NOT NULL,
                    source_revision INTEGER,
                    payload BLOB NOT NULL,
                    source_watermark INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (sender, sequence)
                );
                CREATE TABLE sync_cursors (
                    pair_id TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    last_sequence INTEGER NOT NULL,
                    PRIMARY KEY (pair_id, sender)
                );
                CREATE TABLE inbox_mutations (
                    pair_id TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    mutation_id TEXT NOT NULL,
                    applied_at REAL NOT NULL,
                    PRIMARY KEY (pair_id, sender, mutation_id)
                );
                CREATE TABLE snapshot_transfers (
                    pair_id TEXT NOT NULL,
                    snapshot_id TEXT NOT NULL,
                    source_sender TEXT NOT NULL,
                    source_watermark INTEGER NOT NULL,
                    source_sequence INTEGER NOT NULL,
                    expected_count INTEGER NOT NULL,
                    staged_count INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (pair_id, snapshot_id)
                );
                CREATE TABLE snapshot_staging (
                    pair_id TEXT NOT NULL,
                    snapshot_id TEXT NOT NULL,
                    entity_type TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    updated_at REAL NOT NULL,
                    deleted_at REAL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (pair_id, snapshot_id, entity_type, record_id)
                );
                CREATE TABLE watch_session_sequences (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    last_sequence INTEGER NOT NULL
                );
                """)
        }
        try migrator.migrate(database)
    }

    private func saveLocal<T: Encodable>(_ value: T, entityType: EntityType, recordID: String, revision: Int, mutationKind: SyncMutationKind = .userUpsert, enqueue: Bool = true, deletedAt: Date? = nil) throws {
        try database.write { db in
            let payload = try HealthCoachJSON.encode(value)
            let now = Date()
            let watermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: entityType, recordID: recordID, owner: .phone, revision: revision, updatedAt: now, deletedAt: deletedAt, payload: payload, requireNewer: true)
            if enqueue {
                try enqueueMutation(db, sender: .phone, kind: mutationKind, entityType: entityType, recordID: recordID, owner: .phone, sourceRevision: revision, payload: payload, sourceWatermark: watermark)
            }
        }
    }

    private func putPhoneHealthRecord(db: Database, entityType: EntityType, recordID: String, revision: Int, deletedAt: Date?, payload: Data) throws {
        let watermark = try incrementWatermark(db)
        _ = try putEntity(db: db, entityType: entityType, recordID: recordID, owner: .phone, revision: revision, updatedAt: Date(), deletedAt: deletedAt, payload: payload, requireNewer: true)
        try enqueueMutation(db, sender: .phone, kind: deletedAt == nil ? .userUpsert : .userDelete, entityType: entityType, recordID: recordID, owner: .phone, sourceRevision: revision, payload: payload, sourceWatermark: watermark)
    }

    private func writePhoneJobCommand(_ job: CoachJob) throws {
        try database.write { db in
            let payload = try HealthCoachJSON.encode(job)
            let watermark = try incrementWatermark(db)
            _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .phone, revision: job.inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: payload, requireNewer: false)
            try enqueueMutation(db, sender: .phone, kind: .jobCommand, entityType: .job, recordID: job.id.uuidString, owner: .phone, sourceRevision: job.sourceRevision, payload: payload, sourceWatermark: watermark)
        }
    }

    private func makeJob(_ db: Database, kind: JobKind, request: JobRequest, inputRevision: Int, sourceRevision: Int?) throws -> CoachJob {
        let job = CoachJob(kind: kind, request: request, inputRevision: inputRevision, sourceRevision: sourceRevision)
        let payload = try HealthCoachJSON.encode(job)
        let watermark = try incrementWatermark(db)
        _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .phone, revision: inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: payload, requireNewer: true)
        try enqueueMutation(db, sender: .phone, kind: .jobCommand, entityType: .job, recordID: job.id.uuidString, owner: .phone, sourceRevision: sourceRevision, payload: payload, sourceWatermark: watermark)
        return job
    }

    private func jobContext(db: Database, job: CoachJob) throws -> JobContext {
        var revisions: [String: Int] = [:]
        let rows = try Row.fetchAll(db, sql: "SELECT entity_type, id, revision FROM entity_records WHERE deleted_at IS NULL")
        for row in rows {
            revisions["\(row["entity_type"] as String):\(row["id"] as String)"] = row["revision"] as Int
        }
        revisions["job:\(job.id.uuidString)"] = job.inputRevision
        return JobContext(capturedWatermark: try Int64.fetchOne(db, sql: "SELECT value FROM app_counters WHERE key = 'watermark'") ?? 0, prerequisiteRevisions: revisions)
    }

    private func readPolicy(_ db: Database) throws -> AnalysisPolicy {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'analysis_policy'") else { return AnalysisPolicy() }
        return try HealthCoachJSON.decode(AnalysisPolicy.self, from: data)
    }

    private func setPolicy(_ db: Database, _ policy: AnalysisPolicy) throws {
        try setMetadata(db, key: "analysis_policy", data: try HealthCoachJSON.encode(policy))
    }

    private func setMetadata(_ db: Database, key: String, value: String) throws {
        try setMetadata(db, key: key, data: Data(value.utf8))
    }

    private func setMetadata(_ db: Database, key: String, data: Data) throws {
        try db.execute(sql: "INSERT INTO app_metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, data])
    }

    private func incrementWatermark(_ db: Database) throws -> Int64 {
        let next = (try Int64.fetchOne(db, sql: "SELECT value FROM app_counters WHERE key = 'watermark'") ?? 0) + 1
        try db.execute(sql: "UPDATE app_counters SET value = ? WHERE key = 'watermark'", arguments: [next])
        return next
    }

    private func enqueueMutation(_ db: Database, sender: SyncSender, kind: SyncMutationKind, entityType: EntityType?, recordID: String?, owner: RecordOwner, sourceRevision: Int?, payload: Data, sourceWatermark: Int64) throws {
        guard payload.count <= HealthCoachConstants.maximumFrameBytes else { throw HealthCoachError.frameTooLarge(payload.count) }
        let sequence = (try Int64.fetchOne(db, sql: "SELECT value FROM sequence_counters WHERE sender = ?", arguments: [sender.rawValue]) ?? 0) + 1
        try db.execute(sql: "UPDATE sequence_counters SET value = ? WHERE sender = ?", arguments: [sequence, sender.rawValue])
        let pairID = activePairIDString(db)
        try db.execute(sql: "INSERT INTO sync_outbox (sender, sequence, pair_id, mutation_id, mutation_kind, entity_type, record_id, owner, source_revision, payload, source_watermark, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [sender.rawValue, sequence, pairID, UUID().uuidString, kind.rawValue, entityType?.rawValue, recordID, owner.rawValue, sourceRevision, payload, sourceWatermark, Date().timeIntervalSince1970])
    }

    private func activePairIDString(_ db: Database) -> String {
        (try? String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'active_pair_id'")) ?? "unpaired"
    }

    private func putEntity(db: Database, entityType: EntityType, recordID: String, owner: RecordOwner, revision: Int, updatedAt: Date, deletedAt: Date?, payload: Data, requireNewer: Bool) throws -> Bool {
        let existing = try Int.fetchOne(db, sql: "SELECT revision FROM entity_records WHERE entity_type = ? AND id = ?", arguments: [entityType.rawValue, recordID])
        if let existing, requireNewer && revision <= existing { return false }
        try db.execute(sql: "INSERT INTO entity_records (entity_type, id, owner, revision, updated_at, deleted_at, payload) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(entity_type, id) DO UPDATE SET owner = excluded.owner, revision = excluded.revision, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at, payload = excluded.payload", arguments: [entityType.rawValue, recordID, owner.rawValue, revision, updatedAt.timeIntervalSince1970, deletedAt?.timeIntervalSince1970, payload])
        return true
    }

    private func read<T: Decodable>(_ entityType: EntityType, id: String, db: Database? = nil) throws -> T? {
        if let db {
            guard let row = try Row.fetchOne(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ? AND id = ? AND deleted_at IS NULL", arguments: [entityType.rawValue, id]) else { return nil }
            return try decodeRow(T.self, row: row)
        }
        return try database.read { db in try read(entityType, id: id, db: db) }
    }

    private func list<T: Decodable>(_ entityType: EntityType, includeDeleted: Bool = false) throws -> [T] {
        try database.read { db in try list(T.self, entityType: entityType, db: db, includeDeleted: includeDeleted) }
    }

    private func list<T: Decodable>(_ type: T.Type, entityType: EntityType, db: Database, includeDeleted: Bool = false) throws -> [T] {
        let whereClause = includeDeleted ? "" : " AND deleted_at IS NULL"
        let rows = try Row.fetchAll(db, sql: "SELECT payload FROM entity_records WHERE entity_type = ?\(whereClause) ORDER BY updated_at DESC", arguments: [entityType.rawValue])
        return try rows.map { try decodeRow(type, row: $0) }
    }

    private func decodeRow<T: Decodable>(_ type: T.Type, row: Row) throws -> T {
        try HealthCoachJSON.decode(type, from: row["payload"] as Data)
    }

    private func sameTrainingProgramContent(_ lhs: TrainingProgram, _ rhs: TrainingProgram) -> Bool {
        lhs.id == rhs.id &&
        lhs.revision == rhs.revision &&
        lhs.name == rhs.name &&
        lhs.goalSummary == rhs.goalSummary &&
        lhs.days == rhs.days &&
        lhs.equipment == rhs.equipment &&
        lhs.sourceJobID == rhs.sourceJobID &&
        lhs.sourceModel == rhs.sourceModel &&
        lhs.inputRevision == rhs.inputRevision
    }

    private func validateRemoteMutation(_ mutation: SyncMutation) throws {
        switch mutation.sender {
        case .phone:
            guard mutation.owner == .phone, mutation.mutationKind == .userUpsert || mutation.mutationKind == .userDelete || mutation.mutationKind == .jobCommand || mutation.mutationKind == .policy else { throw HealthCoachError.wrongOwner }
        case .mac:
            guard mutation.owner == .mac, mutation.mutationKind == .jobStatus || mutation.mutationKind == .jobResult else { throw HealthCoachError.wrongOwner }
        }
        guard mutation.payload.count <= HealthCoachConstants.maximumFrameBytes else { throw HealthCoachError.frameTooLarge(mutation.payload.count) }
        if let type = mutation.entityType, EntityType(rawValue: type.rawValue) == nil { throw HealthCoachError.malformedFrame }
    }

    private func applyRemoteMutation(_ mutation: SyncMutation, db: Database) throws {
        switch mutation.mutationKind {
        case .userUpsert, .userDelete:
            guard let type = mutation.entityType, let recordID = mutation.recordID else { throw HealthCoachError.malformedFrame }
            switch type {
            case .profile:
                guard recordID == "profile" else { throw HealthCoachError.malformedFrame }
            case .goals:
                guard recordID == "goals" else { throw HealthCoachError.malformedFrame }
            case .measurement:
                guard try HealthCoachJSON.decode(Measurement.self, from: mutation.payload).id.uuidString == recordID else { throw HealthCoachError.malformedFrame }
            case .meal:
                guard try HealthCoachJSON.decode(Meal.self, from: mutation.payload).id.uuidString == recordID else { throw HealthCoachError.malformedFrame }
            case .workoutSession:
                guard try HealthCoachJSON.decode(WorkoutSession.self, from: mutation.payload).id.uuidString == recordID else { throw HealthCoachError.malformedFrame }
            case .trainingSet:
                guard try HealthCoachJSON.decode(TrainingSet.self, from: mutation.payload).id.uuidString == recordID else { throw HealthCoachError.malformedFrame }
            case .trainingProgram:
                guard try HealthCoachJSON.decode(TrainingProgram.self, from: mutation.payload).id.uuidString == recordID else { throw HealthCoachError.malformedFrame }
            case .exercise:
                guard try HealthCoachJSON.decode(Exercise.self, from: mutation.payload).exerciseID == recordID else { throw HealthCoachError.malformedFrame }
            case .equipment:
                guard recordID == "equipment" else { throw HealthCoachError.malformedFrame }
            case .healthSummary:
                guard try HealthCoachJSON.decode(HealthSummary.self, from: mutation.payload).id.uuidString == recordID else { throw HealthCoachError.malformedFrame }
            case .correction:
                guard try HealthCoachJSON.decode(UserCorrection.self, from: mutation.payload).id.uuidString == recordID else { throw HealthCoachError.malformedFrame }
            default: throw HealthCoachError.wrongOwner
            }
            let revision = mutation.sourceRevision ?? 1
            if type == .trainingProgram,
               let existing: TrainingProgram = try read(.trainingProgram, id: recordID, db: db),
               let incoming = try? HealthCoachJSON.decode(TrainingProgram.self, from: mutation.payload) {
                guard revision >= existing.revision else { return }
                if revision == existing.revision {
                    // Status transitions (proposed/current/archived) may
                    // legitimately reuse an immutable program revision, but
                    // its content must remain byte-for-byte equivalent by
                    // domain value.
                    guard sameTrainingProgramContent(existing, incoming) else {
                        throw HealthCoachError.staleRevision
                    }
                }
            }
            _ = try putEntity(
                db: db,
                entityType: type,
                recordID: recordID,
                owner: mutation.owner,
                revision: revision,
                updatedAt: Date(),
                deletedAt: mutation.mutationKind == .userDelete ? Date() : nil,
                payload: mutation.payload,
                requireNewer: type != .trainingProgram
            )
        case .jobCommand:
            let job = try HealthCoachJSON.decode(CoachJob.self, from: mutation.payload)
            guard mutation.entityType == .job, mutation.recordID == job.id.uuidString, mutation.owner == .phone else { throw HealthCoachError.wrongOwner }
            if let current: CoachJob = try read(.job, id: job.id.uuidString, db: db) {
                guard job.requestGeneration >= current.requestGeneration else { return }
                if job.requestGeneration == current.requestGeneration,
                   current.intent == .cancelRequested,
                   job.intent != .cancelRequested {
                    return
                }
            }
            _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .phone, revision: job.inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: mutation.payload, requireNewer: false)
        case .jobStatus:
            let update = try HealthCoachJSON.decode(JobExecutionUpdate.self, from: mutation.payload)
            guard mutation.entityType == .job, mutation.recordID == update.jobID.uuidString, mutation.owner == .mac else { throw HealthCoachError.wrongOwner }
            try applyJobExecutionUpdate(update, db: db, enqueue: false)
        case .jobResult:
            let result = try HealthCoachJSON.decode(JobResultEnvelope.self, from: mutation.payload)
            guard mutation.entityType == .job, mutation.recordID == result.jobID.uuidString, mutation.owner == .mac else { throw HealthCoachError.wrongOwner }
            try applyJobResult(result, db: db, enqueue: false)
        case .policy:
            let policy = try HealthCoachJSON.decode(AnalysisPolicy.self, from: mutation.payload)
            guard mutation.entityType == .preference, mutation.recordID == "analysis_policy", mutation.owner == .phone else { throw HealthCoachError.wrongOwner }
            try setPolicy(db, policy)
        }
    }

    private func applyJobExecutionUpdate(_ update: JobExecutionUpdate, db: Database, enqueue: Bool) throws {
        guard var job: CoachJob = try read(.job, id: update.jobID.uuidString, db: db) else { return }
        guard job.sourceRevision == update.sourceRevision || job.sourceRevision == nil || update.sourceRevision == nil else { return }
        guard job.requestGeneration == update.generation, job.intent == .active else {
            job.executionStatus = .stale
            job.errorMessage = "A late Mac execution update was retained as stale data."
            job.updatedAt = Date()
            _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .mac, revision: job.inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: try HealthCoachJSON.encode(job), requireNewer: false)
            return
        }
        job.status = update.status
        job.executionStatus = .delivered
        job.attempts = max(job.attempts, update.attempts)
        job.threadID = update.threadID ?? job.threadID
        job.turnID = update.turnID ?? job.turnID
        job.errorMessage = update.errorMessage
        job.updatedAt = update.updatedAt
        let payload = try HealthCoachJSON.encode(job)
        _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .mac, revision: job.inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: payload, requireNewer: false)
        if enqueue {
            let watermark = try incrementWatermark(db)
            try enqueueMutation(db, sender: .mac, kind: .jobStatus, entityType: .job, recordID: job.id.uuidString, owner: .mac, sourceRevision: job.sourceRevision, payload: try HealthCoachJSON.encode(update), sourceWatermark: watermark)
        }
    }

    private func applyJobResult(_ result: JobResultEnvelope, db: Database, enqueue: Bool) throws {
        guard var job: CoachJob = try read(.job, id: result.jobID.uuidString, db: db) else { return }
        guard job.kind == result.kind, job.inputRevision == result.inputRevision else { return }
        try result.output.validate(excludedEquipment: Set((try read( .equipment, id: "equipment", db: db) as EquipmentProfile?)?.excluded ?? []))
        let generationIsCurrent = job.requestGeneration == result.generation && job.intent == .active
        let sourceIsCurrent: Bool
        switch result.output.kind {
        case .analyzeMeal:
            guard let meal = result.output.meal else { return }
            guard job.request.mealID == meal.sourceMealID else { return }
            let currentMeal: Meal? = try read(.meal, id: meal.sourceMealID.uuidString, db: db)
            sourceIsCurrent = currentMeal?.revision == meal.sourceMealRevision
        case .generateProgram:
            sourceIsCurrent = true
        case .suggestProgression:
            guard let progression = result.output.progression else { return }
            guard job.request.sessionID == progression.sourceSessionID else { return }
            let currentSession: WorkoutSession? = try read(.workoutSession, id: progression.sourceSessionID.uuidString, db: db)
            sourceIsCurrent = currentSession?.revision == progression.sourceSessionRevision
        case .answerQuestion:
            sourceIsCurrent = true
        }
        guard generationIsCurrent && sourceIsCurrent else {
            if !job.resultHistory.contains(where: { $0.generation == result.generation && $0.generatedAt == result.generatedAt }) {
                job.resultHistory.append(result)
            }
            job.executionStatus = .stale
            job.errorMessage = "A late or superseded result was retained as stale history."
            job.updatedAt = Date()
            _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .mac, revision: job.inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: try HealthCoachJSON.encode(job), requireNewer: false)
            return
        }
        if let existing = job.result, existing.generation == result.generation { return }
        if let existing = job.result { job.resultHistory.append(existing) }
        job.result = result
        job.status = .succeeded
        job.executionStatus = .acknowledged
        job.errorMessage = nil
        job.updatedAt = Date()
        let jobPayload = try HealthCoachJSON.encode(job)
        _ = try putEntity(db: db, entityType: .job, recordID: job.id.uuidString, owner: .mac, revision: job.inputRevision, updatedAt: job.updatedAt, deletedAt: nil, payload: jobPayload, requireNewer: false)
        try applyDerivedOutput(result.output, job: job, db: db)
        if enqueue {
            let watermark = try incrementWatermark(db)
            try enqueueMutation(db, sender: .mac, kind: .jobResult, entityType: .job, recordID: job.id.uuidString, owner: .mac, sourceRevision: job.sourceRevision, payload: try HealthCoachJSON.encode(result), sourceWatermark: watermark)
        }
    }

    private func applyDerivedOutput(_ output: JobOutput, job: CoachJob, db: Database) throws {
        switch output.kind {
        case .analyzeMeal:
            guard let mealID = job.request.mealID, var meal: Meal = try read(.meal, id: mealID.uuidString, db: db), let analysis = output.meal else { return }
            guard meal.revision == analysis.sourceMealRevision, meal.deletedAt == nil else {
                return
            }
            meal.analysis = analysis
            meal.analysisStatus = .succeeded
            meal.corrected = false
            meal.updatedAt = Date()
            _ = try putEntity(db: db, entityType: .meal, recordID: meal.id.uuidString, owner: .phone, revision: meal.revision, updatedAt: meal.updatedAt, deletedAt: nil, payload: try HealthCoachJSON.encode(meal), requireNewer: false)
        case .generateProgram:
            guard var program = output.program else { return }
            program.status = .proposed
            program.sourceJobID = job.id
            _ = try putEntity(db: db, entityType: .trainingProgram, recordID: program.id.uuidString, owner: .phone, revision: program.revision, updatedAt: program.updatedAt, deletedAt: nil, payload: try HealthCoachJSON.encode(program), requireNewer: false)
            try upsertExerciseLibrary(db: db, program: program, enqueue: false)
        case .suggestProgression, .answerQuestion:
            break
        }
    }

    private func upsertExerciseLibrary(db: Database, program: TrainingProgram, enqueue: Bool) throws {
        for programExercise in program.days.flatMap(\.exercises) {
            let alternatives = programExercise.alternatives.map(\.exerciseID)
            let main = Exercise(
                exerciseID: programExercise.exerciseID,
                displayName: programExercise.displayName,
                equipment: programExercise.equipment,
                alternatives: alternatives,
                sourceProgramID: program.id,
                sourceProgramRevision: program.revision
            )
            var candidates = [main]
            candidates.append(contentsOf: programExercise.alternatives.map {
                Exercise(
                    exerciseID: $0.exerciseID,
                    displayName: $0.displayName,
                    equipment: $0.equipment,
                    sourceProgramID: program.id,
                    sourceProgramRevision: program.revision
                )
            })
            for candidate in candidates {
                let existing: Exercise? = try read(.exercise, id: candidate.exerciseID, db: db)
                if let existing,
                   existing.displayName == candidate.displayName,
                   existing.equipment == candidate.equipment,
                   existing.alternatives == candidate.alternatives,
                   existing.sourceProgramID == candidate.sourceProgramID,
                   existing.sourceProgramRevision == candidate.sourceProgramRevision {
                    continue
                }
                var stored = candidate
                stored.revision = (existing?.revision ?? 0) + 1
                let payload = try HealthCoachJSON.encode(stored)
                _ = try putEntity(
                    db: db,
                    entityType: .exercise,
                    recordID: stored.exerciseID,
                    owner: .phone,
                    revision: stored.revision,
                    updatedAt: Date(),
                    deletedAt: nil,
                    payload: payload,
                    requireNewer: false
                )
                if enqueue {
                    let watermark = try incrementWatermark(db)
                    try enqueueMutation(
                        db,
                        sender: .phone,
                        kind: .userUpsert,
                        entityType: .exercise,
                        recordID: stored.exerciseID,
                        owner: .phone,
                        sourceRevision: stored.revision,
                        payload: payload,
                        sourceWatermark: watermark
                    )
                }
            }
        }
    }

    private func putWatchPhoneRecord(db: Database, session: WorkoutSession) throws {
        let payload = try HealthCoachJSON.encode(session)
        let watermark = try incrementWatermark(db)
        _ = try putEntity(db: db, entityType: .workoutSession, recordID: session.id.uuidString, owner: .phone, revision: session.revision, updatedAt: session.updatedAt, deletedAt: nil, payload: payload, requireNewer: false)
        try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .workoutSession, recordID: session.id.uuidString, owner: .phone, sourceRevision: session.revision, payload: payload, sourceWatermark: watermark)
    }

    private func putWatchPhoneRecord(db: Database, set: TrainingSet) throws {
        let payload = try HealthCoachJSON.encode(set)
        let watermark = try incrementWatermark(db)
        _ = try putEntity(db: db, entityType: .trainingSet, recordID: set.id.uuidString, owner: .phone, revision: set.revision, updatedAt: set.updatedAt, deletedAt: nil, payload: payload, requireNewer: false)
        try enqueueMutation(db, sender: .phone, kind: .userUpsert, entityType: .trainingSet, recordID: set.id.uuidString, owner: .phone, sourceRevision: set.revision, payload: payload, sourceWatermark: watermark)
    }

    private func makeWatchAck(db: Database, command: WatchCommand, status: WatchCommandStatus, message: String?) throws -> WatchCommandAck {
        WatchCommandAck(commandID: command.id, sessionID: command.sessionID, sequence: command.sequence, status: status, message: message, phoneRevision: try Int64.fetchOne(db, sql: "SELECT value FROM app_counters WHERE key = 'watermark'") ?? 0)
    }

    private func saveWatchAck(db: Database, ack: WatchCommandAck) throws {
        let payload = try HealthCoachJSON.encode(ack)
        _ = try putEntity(db: db, entityType: .watchAck, recordID: ack.commandID.uuidString, owner: .phone, revision: Int(ack.sequence), updatedAt: ack.committedAt, deletedAt: nil, payload: payload, requireNewer: false)
    }

    private func rejectWatchCommand(db: Database, command: WatchCommand, message: String) throws -> WatchCommandAck {
        try saveWatchCommandRecord(db: db, command: command, status: .rejected, terminalMessage: message)
        let ack = try makeWatchAck(db: db, command: command, status: .rejected, message: message)
        try saveWatchAck(db: db, ack: ack)
        return ack
    }

    private func saveWatchCommandRecord(db: Database, command: WatchCommand, status: WatchCommandStatus, terminalMessage: String?) throws {
        var persisted = command
        persisted.status = status
        persisted.terminalMessage = terminalMessage
        let payload = try HealthCoachJSON.encode(persisted)
        _ = try putEntity(
            db: db,
            entityType: .watchCommand,
            recordID: command.id.uuidString,
            owner: .phone,
            revision: Int(command.sequence),
            updatedAt: Date(),
            deletedAt: nil,
            payload: payload,
            requireNewer: false
        )
    }

    private func validateSnapshotRecord(_ record: SnapshotRecord) throws {
        guard record.revision > 0, record.payload.count <= HealthCoachConstants.maximumFrameBytes else {
            throw HealthCoachError.malformedFrame
        }
        switch record.entityType {
        case .profile:
            guard record.recordID == "profile" else { throw HealthCoachError.malformedFrame }
        case .goals:
            guard record.recordID == "goals" else { throw HealthCoachError.malformedFrame }
        case .measurement:
            guard try HealthCoachJSON.decode(Measurement.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .meal:
            guard try HealthCoachJSON.decode(Meal.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .workoutSession:
            guard try HealthCoachJSON.decode(WorkoutSession.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .trainingSet:
            guard try HealthCoachJSON.decode(TrainingSet.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .trainingProgram:
            guard try HealthCoachJSON.decode(TrainingProgram.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .exercise:
            guard try HealthCoachJSON.decode(Exercise.self, from: record.payload).exerciseID == record.recordID else { throw HealthCoachError.malformedFrame }
        case .equipment:
            guard record.recordID == "equipment" else { throw HealthCoachError.malformedFrame }
        case .healthSummary:
            guard try HealthCoachJSON.decode(HealthSummary.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .correction:
            guard try HealthCoachJSON.decode(UserCorrection.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .job:
            guard try HealthCoachJSON.decode(CoachJob.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .watchCommand:
            guard try HealthCoachJSON.decode(WatchCommand.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .watchAck:
            guard try HealthCoachJSON.decode(WatchCommandAck.self, from: record.payload).id.uuidString == record.recordID else { throw HealthCoachError.malformedFrame }
        case .preference:
            _ = try HealthCoachJSON.decode(AnalysisPolicy.self, from: record.payload)
        }
    }

    private func localDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func excludeFromBackup(_ url: URL) {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(resourceValues)
    }
}
