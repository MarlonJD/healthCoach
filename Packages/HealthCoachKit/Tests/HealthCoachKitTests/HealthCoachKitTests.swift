import Foundation
import XCTest
@testable import HealthCoachKit

#if canImport(Network)
import Network
#endif

#if os(macOS)
import Darwin
#endif

final class HealthCoachKitTests: XCTestCase {
    func testCodexOutputSchemaRequiresEveryDeclaredProperty() throws {
        let schemaData = try HealthCoachOutputSchema.jobOutput()
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        try assertStrictSchemaObject(schema, at: "root")
    }

    func testSyncRunnerPushesDurableLocalChangesToAnOpenPeer() async throws {
        let pairID = UUID()
        let macID = UUID()
        let phoneID = UUID()
        let macStore = try HealthCoachStore(inMemory: true)
        let phoneStore = try HealthCoachStore(inMemory: true)
        try macStore.setActivePair(pairID)
        try phoneStore.setActivePair(pairID)

        let macCoordinator = SyncSessionCoordinator(
            store: macStore,
            pairID: pairID,
            localPeerID: macID,
            remotePeerID: phoneID,
            localSender: .mac
        )
        let phoneCoordinator = SyncSessionCoordinator(
            store: phoneStore,
            pairID: pairID,
            localPeerID: phoneID,
            remotePeerID: macID,
            localSender: .phone
        )
        let transport = RunnerTestTransport()
        var localChangeContinuation: AsyncStream<Void>.Continuation?
        let localChanges = AsyncStream<Void> { continuation in
            localChangeContinuation = continuation
        }
        let runner = Task {
            try await SyncConnectionRunner.run(
                transport: transport,
                coordinator: macCoordinator,
                localChanges: localChanges
            )
        }
        defer {
            localChangeContinuation?.finish()
            transport.finish()
            runner.cancel()
        }

        try await waitForRunnerCondition("initial hello") { transport.sent().count == 1 }
        transport.push(try await phoneCoordinator.hello())
        try await waitForRunnerCondition("authentication response") { transport.sent().count >= 2 }

        let meal = try macStore.saveMeal(
            Meal(localDate: "2026-09-16", originalText: "synthetic push meal"),
            enqueueAnalysis: false
        )
        let job = try macStore.createJob(
            kind: .analyzeMeal,
            request: JobRequest(mealID: meal.id),
            inputRevision: meal.revision,
            sourceRevision: meal.revision
        )
        try macStore.recordMacExecutionUpdate(JobExecutionUpdate(
            jobID: job.id,
            generation: job.requestGeneration,
            sourceRevision: job.sourceRevision,
            status: .running,
            attempts: 1
        ))
        localChangeContinuation?.yield(())
        try await waitForRunnerCondition("local outbox batch") { transport.sent().contains { $0.kind == .batch } }

        let outgoingBatch = try XCTUnwrap(transport.sent().first(where: { $0.kind == .batch }))
        let batch = try HealthCoachJSON.decode(SyncBatch.self, from: outgoingBatch.body)
        XCTAssertEqual(batch.sender, .mac)
        XCTAssertEqual(batch.mutations.count, 1)
        XCTAssertEqual(batch.mutations.first?.entityType, .job)
    }

    func testPersistentMealSurvivesRestartAndQueuesOnlyAfterCommit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try HealthCoachStore(path: fixture.databaseURL)
        let mealID = UUID()
        let meal = try store.saveMeal(Meal(id: mealID, localDate: "2026-09-16", originalText: "oats and yogurt"), enqueueAnalysis: false)

        XCTAssertEqual(meal.revision, 1)
        XCTAssertEqual(try store.meals().map(\.id), [mealID])
        XCTAssertTrue(try store.pendingOutbox(sender: .phone).contains { $0.recordID == mealID.uuidString })

        let restarted = try HealthCoachStore(path: fixture.databaseURL)
        XCTAssertEqual(try restarted.meal(id: mealID)?.originalText, "oats and yogurt")
        XCTAssertThrowsError(try restarted.saveMeal(Meal(localDate: "2026-09-16", originalText: "   "), enqueueAnalysis: false))
    }

    func testDeadLetteredJobPersistsAndRetryRequeuesNewGeneration() throws {
        let store = try HealthCoachStore(inMemory: true)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic dead letter meal"), enqueueAnalysis: false)
        let job = try store.createJob(
            kind: .analyzeMeal,
            request: JobRequest(mealID: meal.id),
            inputRevision: meal.revision,
            sourceRevision: meal.revision
        )
        let reason = "synthetic terminal output"
        try store.recordMacExecutionUpdate(JobExecutionUpdate(
            jobID: job.id,
            generation: job.requestGeneration,
            sourceRevision: job.sourceRevision,
            status: .deadLettered,
            attempts: CodexJobWorker.maxAttempts,
            errorMessage: reason
        ))

        let deadLettered = try XCTUnwrap(store.job(id: job.id))
        XCTAssertEqual(deadLettered.status, .deadLettered)
        XCTAssertEqual(deadLettered.executionStatus, .deadLettered)
        XCTAssertEqual(deadLettered.attempts, CodexJobWorker.maxAttempts)
        XCTAssertEqual(deadLettered.errorMessage, reason)

        let retried = try store.retryJob(id: job.id)
        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.requestGeneration, job.requestGeneration + 1)
        XCTAssertEqual(retried.attempts, 0)
        XCTAssertNil(retried.errorMessage)
        XCTAssertTrue(try store.pendingJobs().contains { $0.id == job.id })
    }

    func testDelayedPhoneJobCommandDoesNotRewindMacResult() throws {
        let store = try HealthCoachStore(inMemory: true)
        let pairID = UUID()
        let macPeerID = UUID()
        try store.setActivePair(pairID)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic stale command meal"), enqueueAnalysis: false)
        let job = try store.createJob(
            kind: .analyzeMeal,
            request: JobRequest(mealID: meal.id),
            inputRevision: meal.revision,
            sourceRevision: meal.revision
        )
        try store.recordMacExecutionUpdate(JobExecutionUpdate(
            jobID: job.id,
            generation: job.requestGeneration,
            sourceRevision: job.sourceRevision,
            status: .running,
            attempts: 1
        ))
        try store.recordMacResult(JobResultEnvelope(
            jobID: job.id,
            generation: job.requestGeneration,
            kind: job.kind,
            inputRevision: job.inputRevision,
            sourceRevision: job.sourceRevision,
            context: try store.jobContext(for: job),
            output: syntheticMealOutput(mealID: meal.id, revision: meal.revision, jobID: job.id),
            sourceModel: "synthetic"
        ))

        let delayedCommand = SyncMutation(
            pairID: pairID,
            sender: .phone,
            sequence: 1,
            mutationKind: .jobCommand,
            entityType: .job,
            recordID: job.id.uuidString,
            owner: .phone,
            sourceRevision: job.sourceRevision,
            payload: try HealthCoachJSON.encode(job),
            sourceWatermark: 1
        )
        _ = try store.applyIncoming(
            SyncBatch(sender: .phone, firstSequence: 1, lastSequence: 1, mutations: [delayedCommand]),
            authenticatedPeerID: macPeerID,
            pairID: pairID
        )

        let preserved = try XCTUnwrap(store.job(id: job.id))
        XCTAssertEqual(preserved.status, .succeeded)
        XCTAssertEqual(preserved.executionStatus, .acknowledged)
        XCTAssertEqual(preserved.attempts, 1)
        XCTAssertNotNil(preserved.result)
        XCTAssertEqual(try store.meal(id: meal.id)?.analysisStatus, .succeeded)
    }

    func testLegacyFailedJobNormalizesToDeadLetter() throws {
        let store = try HealthCoachStore(inMemory: true)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic legacy failure"), enqueueAnalysis: false)
        let job = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        try store.recordMacExecutionUpdate(JobExecutionUpdate(
            jobID: job.id,
            generation: job.requestGeneration,
            sourceRevision: job.sourceRevision,
            status: .failed,
            attempts: 1,
            errorMessage: "legacy failure"
        ))

        XCTAssertEqual(try store.normalizeFailedJobsToDeadLetters(), 1)
        let normalized = try XCTUnwrap(store.job(id: job.id))
        XCTAssertEqual(normalized.status, .deadLettered)
        XCTAssertEqual(normalized.executionStatus, .deadLettered)
        XCTAssertEqual(normalized.errorMessage, "legacy failure")
    }

    func testNewPhoneRetryGenerationStartsQueuedDespiteCopiedFailureState() throws {
        let store = try HealthCoachStore(inMemory: true)
        let pairID = UUID()
        let macPeerID = UUID()
        try store.setActivePair(pairID)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic retry generation"), enqueueAnalysis: false)
        let job = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        try store.recordMacExecutionUpdate(JobExecutionUpdate(
            jobID: job.id,
            generation: job.requestGeneration,
            sourceRevision: job.sourceRevision,
            status: .deadLettered,
            attempts: CodexJobWorker.maxAttempts,
            errorMessage: "synthetic dead letter"
        ))

        var retriedPayload = job
        retriedPayload.requestGeneration += 1
        retriedPayload.status = .failed
        retriedPayload.executionStatus = .delivered
        retriedPayload.attempts = 4
        retriedPayload.errorMessage = "copied old failure"
        let mutation = SyncMutation(
            pairID: pairID,
            sender: .phone,
            sequence: 1,
            mutationKind: .jobCommand,
            entityType: .job,
            recordID: job.id.uuidString,
            owner: .phone,
            sourceRevision: job.sourceRevision,
            payload: try HealthCoachJSON.encode(retriedPayload),
            sourceWatermark: 1
        )
        _ = try store.applyIncoming(
            SyncBatch(sender: .phone, firstSequence: 1, lastSequence: 1, mutations: [mutation]),
            authenticatedPeerID: macPeerID,
            pairID: pairID
        )

        let queued = try XCTUnwrap(store.job(id: job.id))
        XCTAssertEqual(queued.requestGeneration, job.requestGeneration + 1)
        XCTAssertEqual(queued.status, .queued)
        XCTAssertEqual(queued.executionStatus, .notDelivered)
        XCTAssertEqual(queued.attempts, 0)
        XCTAssertNil(queued.errorMessage)
    }

    func testInterruptedRunningJobIsRecoveredToQueued() throws {
        let store = try HealthCoachStore(inMemory: true)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic interrupted job"), enqueueAnalysis: false)
        let job = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        try store.recordMacExecutionUpdate(JobExecutionUpdate(
            jobID: job.id,
            generation: job.requestGeneration,
            sourceRevision: job.sourceRevision,
            status: .running,
            attempts: 2,
            threadID: "interrupted-thread",
            turnID: "interrupted-turn"
        ))

        XCTAssertEqual(try store.recoverInterruptedJobs(), 1)
        let recovered = try XCTUnwrap(store.job(id: job.id))
        XCTAssertEqual(recovered.status, .queued)
        XCTAssertEqual(recovered.executionStatus, .notDelivered)
        XCTAssertEqual(recovered.attempts, 2)
        XCTAssertNil(recovered.threadID)
        XCTAssertNil(recovered.turnID)
        XCTAssertNil(recovered.errorMessage)
    }

    func testPendingProgramRequestsAreDeduplicated() throws {
        let store = try HealthCoachStore(inMemory: true)
        let first = try store.createJob(kind: .generateProgram, request: JobRequest(), inputRevision: 1)
        let second = try store.createJob(kind: .generateProgram, request: JobRequest(), inputRevision: 1)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try store.jobs().filter { $0.kind == .generateProgram }.count, 1)
    }

    func testEquipmentDiscoveryIsDeduplicatedAndMergesDetectedEquipment() throws {
        let store = try HealthCoachStore(inMemory: true)
        try store.saveEquipment(EquipmentProfile(available: [], facilityType: .mediumGym, referencePhotos: [Data([0x01, 0x02])]))
        let request = JobRequest(facilityType: .mediumGym, facilityName: "Synthetic Gym", referenceImageData: [Data([0x01])], allowsOnlineLookup: true)
        let first = try store.createJob(kind: .discoverEquipment, request: request, inputRevision: 1, sourceRevision: 1)
        let second = try store.createJob(kind: .discoverEquipment, request: request, inputRevision: 1, sourceRevision: 1)
        XCTAssertEqual(first.id, second.id)

        try store.recordMacResult(JobResultEnvelope(
            jobID: first.id,
            generation: first.requestGeneration,
            kind: .discoverEquipment,
            inputRevision: first.inputRevision,
            sourceRevision: first.sourceRevision,
            context: try store.jobContext(for: first),
            output: JobOutput(kind: .discoverEquipment, equipment: EquipmentDiscovery(
                facilityType: .mediumGym,
                facilityName: "Synthetic Gym",
                detectedEquipment: ["cable machine", "dumbbells"],
                confidenceByEquipment: ["cable machine": 0.9, "dumbbells": 0.8],
                rationale: "Synthetic fixture",
                sources: ["https://example.com/gym"],
                limitations: []
            )),
            sourceModel: "fixture"
        ))

        let equipment = try XCTUnwrap(store.equipment())
        XCTAssertEqual(equipment.facilityType, .mediumGym)
        XCTAssertEqual(equipment.facilityName, "Synthetic Gym")
        XCTAssertTrue(equipment.available.contains("cable machine"))
        XCTAssertTrue(equipment.available.contains("dumbbells"))
    }

    func testExistingActiveProgramDuplicatesAreCancelledAndRemainRetryable() throws {
        let store = try HealthCoachStore(inMemory: true)
        let pairID = UUID()
        try store.setActivePair(pairID)
        let first = try store.createJob(kind: .generateProgram, request: JobRequest(), inputRevision: 1)
        var duplicate = CoachJob(kind: .generateProgram, request: JobRequest(), inputRevision: 1)
        duplicate.createdAt = first.createdAt.addingTimeInterval(1)
        duplicate.updatedAt = first.updatedAt.addingTimeInterval(1)

        let mutation = SyncMutation(
            pairID: pairID,
            sender: .phone,
            sequence: 1,
            mutationKind: .jobCommand,
            entityType: .job,
            recordID: duplicate.id.uuidString,
            owner: .phone,
            sourceRevision: duplicate.sourceRevision,
            payload: try HealthCoachJSON.encode(duplicate),
            sourceWatermark: 1
        )
        _ = try store.applyIncoming(
            SyncBatch(sender: .phone, firstSequence: 1, lastSequence: 1, mutations: [mutation]),
            authenticatedPeerID: UUID(),
            pairID: pairID
        )

        XCTAssertEqual(try store.deduplicateActiveProgramJobs(), 1)
        let jobs = try store.jobs().filter { $0.kind == .generateProgram }
        XCTAssertEqual(jobs.filter { $0.status == .queued || $0.status == .running }.count, 1)
        let cancelled = try XCTUnwrap(jobs.first { $0.id == duplicate.id })
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.intent, .cancelRequested)
        XCTAssertEqual(cancelled.errorMessage, "Superseded by another active program request.")

        let retried = try store.retryJob(id: duplicate.id)
        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.intent, .active)
    }

    func testResetProgramRequestsClearsJobsAndProposalsButKeepsCurrentProgram() throws {
        let store = try HealthCoachStore(inMemory: true)
        let job = try store.createJob(kind: .generateProgram, request: JobRequest(), inputRevision: 1)
        let exercise = ProgramExercise(exerciseID: "push_up", displayName: "Push-up", order: 0, sets: 2, minimumReps: 5, maximumReps: 10)
        let proposal = TrainingProgram(
            name: "Synthetic proposal",
            goalSummary: "Strength",
            days: [TrainingDay(name: "Day A", order: 0, exercises: [exercise])],
            equipment: [],
            sourceJobID: job.id
        )
        try store.saveProgram(proposal)

        XCTAssertEqual(try store.resetProgramRequests(), 2)
        XCTAssertFalse(try store.jobs().contains { $0.kind == .generateProgram })
        XCTAssertFalse(try store.programs().contains { $0.id == proposal.id })
        XCTAssertTrue(try store.pendingOutbox(sender: .phone).contains { $0.mutationKind == .jobCommand })
        XCTAssertTrue(try store.pendingOutbox(sender: .phone).contains { $0.mutationKind == .userDelete && $0.recordID == proposal.id.uuidString })
    }

    func testCurrentProgramRemovalArchivesItAndProtectsAnActiveWorkout() throws {
        let store = try HealthCoachStore(inMemory: true)
        let exercise = ProgramExercise(exerciseID: "push_up", displayName: "Push-up", order: 0, sets: 2, minimumReps: 5, maximumReps: 10)
        let proposal = TrainingProgram(
            name: "Synthetic current",
            goalSummary: "Strength",
            days: [TrainingDay(name: "Day A", order: 0, exercises: [exercise])],
            equipment: []
        )
        try store.saveProgram(proposal)
        let current = try store.acceptProgram(proposal)
        _ = try store.startSession(program: current, localDate: "2026-09-18")

        XCTAssertThrowsError(try store.archiveCurrentProgram())
        _ = try store.finishSession(id: try XCTUnwrap(store.workouts().first?.id))
        let archived = try store.archiveCurrentProgram()

        XCTAssertEqual(archived.status, .archived)
        XCTAssertNil(try store.currentProgram())
        XCTAssertEqual(try store.workouts().count, 1)
    }

    func testRejectProgramArchivesProposalWithoutChangingCurrentProgram() throws {
        let store = try HealthCoachStore(inMemory: true)
        let exercise = ProgramExercise(exerciseID: "push_up", displayName: "Push-up", order: 0, sets: 2, minimumReps: 5, maximumReps: 10)
        let proposal = TrainingProgram(
            name: "Synthetic proposal",
            goalSummary: "Strength",
            days: [TrainingDay(name: "Day A", order: 0, exercises: [exercise])],
            equipment: []
        )
        try store.saveProgram(proposal)

        let rejected = try store.rejectProgram(proposal)

        XCTAssertEqual(rejected.status, .archived)
        XCTAssertNil(try store.currentProgram())
        XCTAssertEqual(try store.programs().first?.status, .archived)
        XCTAssertTrue(try store.pendingOutbox(sender: .phone).contains { $0.mutationKind == .userUpsert && $0.recordID == proposal.id.uuidString })
    }

    func testProgramsMayReuseExerciseAcrossDaysButNotWithinOneDay() throws {
        let exercise = ProgramExercise(exerciseID: "push_up", displayName: "Push-up", order: 0, sets: 3, minimumReps: 8, maximumReps: 15)
        let program = TrainingProgram(
            name: "Repeated movement",
            goalSummary: "Strength",
            days: [
                TrainingDay(name: "Day A", order: 0, exercises: [exercise]),
                TrainingDay(name: "Day B", order: 1, exercises: [exercise])
            ],
            equipment: []
        )
        XCTAssertNoThrow(try program.validate(excludedEquipment: []))

        var duplicate = exercise
        duplicate.order = 1
        let invalid = TrainingProgram(
            name: "Duplicate movement",
            goalSummary: "Strength",
            days: [TrainingDay(name: "Day A", order: 0, exercises: [exercise, duplicate])],
            equipment: []
        )
        XCTAssertThrowsError(try invalid.validate(excludedEquipment: []))
    }

    #if os(macOS)
    func testExhaustedJobIsDeadLetteredBeforeDispatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try HealthCoachStore(path: fixture.databaseURL)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic exhausted job"), enqueueAnalysis: false)
        let job = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        let reason = "synthetic retry limit"
        try store.recordMacExecutionUpdate(JobExecutionUpdate(
            jobID: job.id,
            generation: job.requestGeneration,
            sourceRevision: job.sourceRevision,
            status: .running,
            attempts: CodexJobWorker.maxAttempts,
            errorMessage: reason
        ))
        let worker = CodexJobWorker(
            store: store,
            codexExecutableURL: URL(fileURLWithPath: "/bin/false"),
            mcpExecutableURL: URL(fileURLWithPath: "/bin/false"),
            workRoot: fixture.directoryURL
        )

        do {
            try await worker.run(jobID: job.id)
            XCTFail("An exhausted job should not dispatch a new turn.")
        } catch {
            // The durable status is the assertion; no external process should
            // be needed once the retry limit has been reached.
        }

        let deadLettered = try XCTUnwrap(store.job(id: job.id))
        XCTAssertEqual(deadLettered.status, .deadLettered)
        XCTAssertEqual(deadLettered.attempts, CodexJobWorker.maxAttempts)
        XCTAssertEqual(deadLettered.errorMessage, reason)
    }
    #endif

    func testMealTextRevisionInvalidatesOlderEstimateAndQueuesFreshAnalysis() throws {
        let store = try HealthCoachStore(inMemory: true)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "oats"), enqueueAnalysis: false)
        var edited = meal
        edited.revision = meal.revision + 1
        edited.originalText = "oats and yogurt"
        edited.revisions.append(MealTextRevision(revision: edited.revision, text: edited.originalText))
        edited.analysis = MealAnalysis(
            sourceMealID: meal.id,
            sourceMealRevision: meal.revision,
            components: [],
            totals: MacroTotals(kcal: 100),
            kcalRange: NutritionRange(lowKcal: 90, centralKcal: 100, highKcal: 110),
            assumptions: ["synthetic"],
            sourceJobID: UUID(),
            sourceModel: "fixture"
        )
        edited.corrected = true
        edited.analysisStatus = .succeeded

        let saved = try store.saveMeal(edited)
        XCTAssertNil(saved.analysis)
        XCTAssertFalse(saved.corrected)
        XCTAssertEqual(saved.analysisStatus, .queued)
        XCTAssertEqual(try store.jobs().count, 1)
        XCTAssertEqual(try store.jobs().first?.inputRevision, saved.revision)

        var corrected = saved
        corrected.analysis = MealAnalysis(
            sourceMealID: saved.id,
            sourceMealRevision: saved.revision,
            components: [],
            totals: MacroTotals(kcal: 450, proteinGrams: 30, carbohydratesGrams: 40, fatGrams: 12),
            kcalRange: NutritionRange(lowKcal: 450, centralKcal: 450, highKcal: 450),
            assumptions: ["synthetic correction"],
            sourceJobID: UUID(),
            sourceModel: "user"
        )
        corrected.corrected = true
        corrected.analysisStatus = .succeeded
        let summary = DeterministicSummaries.nutrition(for: "2026-09-16", meals: [corrected])
        XCTAssertEqual(summary.mealCount, 1)
        XCTAssertEqual(summary.totals.kcal, 450)
    }

    func testMealAnalysisIsAtomicWithJobAndDeletionCancelsPendingWork() throws {
        let store = try HealthCoachStore(inMemory: true)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "rice, tofu, greens"))
        XCTAssertEqual(meal.analysisStatus, .queued)
        XCTAssertEqual(try store.jobs().count, 1)

        try store.deleteMeal(id: meal.id)
        XCTAssertEqual(try store.meals(includeDeleted: true).first(where: { $0.id == meal.id })?.deletedAt != nil, true)
        XCTAssertEqual(try store.jobs().first?.intent, .cancelRequested)
        XCTAssertEqual(try store.jobs().first?.status, .cancelled)
    }

    func testMealAnalysisRetryClearsOlderEstimateBeforeQueueing() throws {
        let analysis = MealAnalysis(
            sourceMealID: UUID(),
            sourceMealRevision: 1,
            components: [],
            totals: MacroTotals(kcal: 300),
            kcalRange: NutritionRange(lowKcal: 250, centralKcal: 300, highKcal: 350),
            assumptions: ["synthetic"],
            sourceJobID: UUID(),
            sourceModel: "fixture"
        )
        let store = try HealthCoachStore(inMemory: true)
        let mealID = analysis.sourceMealID
        let meal = try store.saveMeal(Meal(id: mealID, localDate: "2026-09-16", originalText: "rice", analysisStatus: .succeeded, analysis: analysis, corrected: true), enqueueAnalysis: false)

        let job = try store.requestMealAnalysis(id: meal.id)
        XCTAssertEqual(job.kind, .analyzeMeal)
        XCTAssertNil(try store.meal(id: meal.id)?.analysis)
        XCTAssertEqual(try store.meal(id: meal.id)?.analysisStatus, .queued)
        XCTAssertFalse(try store.meal(id: meal.id)?.corrected ?? true)
    }

    func testOutboxAppliesOnceRejectsGapsAndProtectsPayloadIdentity() throws {
        let source = try HealthCoachStore(inMemory: true)
        let mirror = try HealthCoachStore(inMemory: true)
        let pairID = UUID()
        try source.setActivePair(pairID)
        let profileID = UUID()
        try source.saveProfile(UserProfile(id: profileID, displayName: "Synthetic Athlete"))
        let mutation = try XCTUnwrap(source.pendingOutbox(sender: .phone).first)
        let batch = SyncBatch(sender: .phone, firstSequence: mutation.sequence, lastSequence: mutation.sequence, mutations: [mutation])

        let firstAck = try mirror.applyIncoming(batch, authenticatedPeerID: UUID(), pairID: pairID)
        XCTAssertEqual(firstAck.appliedMutationIDs, [mutation.id])
        XCTAssertEqual(try mirror.profile()?.displayName, "Synthetic Athlete")

        let duplicateAck = try mirror.applyIncoming(batch, authenticatedPeerID: UUID(), pairID: pairID)
        XCTAssertEqual(duplicateAck.lastSequence, mutation.sequence)
        XCTAssertTrue(duplicateAck.appliedMutationIDs.isEmpty)

        let gap = SyncMutation(
            pairID: pairID,
            sender: .phone,
            sequence: mutation.sequence + 2,
            mutationKind: .userUpsert,
            entityType: .profile,
            recordID: profileID.uuidString,
            owner: .phone,
            sourceRevision: 2,
            payload: try HealthCoachJSON.encode(UserProfile(id: profileID, displayName: "gap")),
            sourceWatermark: 2
        )
        XCTAssertThrowsError(try mirror.applyIncoming(
            SyncBatch(sender: .phone, firstSequence: gap.sequence, lastSequence: gap.sequence, mutations: [gap]),
            authenticatedPeerID: UUID(),
            pairID: pairID
        )) { error in
            XCTAssertEqual(error as? HealthCoachError, .sequenceGap(expected: mutation.sequence + 1, received: gap.sequence))
        }

        let wrongID = SyncMutation(
            pairID: pairID,
            sender: .phone,
            sequence: mutation.sequence + 1,
            mutationKind: .userUpsert,
            entityType: .profile,
            recordID: UUID().uuidString,
            owner: .phone,
            sourceRevision: 2,
            payload: try HealthCoachJSON.encode(UserProfile(id: profileID, displayName: "spoof")),
            sourceWatermark: 2
        )
        XCTAssertThrowsError(try mirror.applyIncoming(
            SyncBatch(sender: .phone, firstSequence: wrongID.sequence, lastSequence: wrongID.sequence, mutations: [wrongID]),
            authenticatedPeerID: UUID(),
            pairID: pairID
        ))
    }

    func testInterruptedSnapshotDoesNotExposePartialStateAndCompletesWithSourceCursor() throws {
        let source = try HealthCoachStore(inMemory: true)
        let mirror = try HealthCoachStore(inMemory: true)
        let pairID = UUID()
        try source.setActivePair(pairID)
        try source.saveProfile(UserProfile(id: UUID(), displayName: "Snapshot Fixture"))
        try source.saveGoals(Goals(targetWeightKg: 80))
        let records = try source.snapshotRecords()
        let descriptor = try source.makeSnapshotDescriptor(pairID: pairID, sourceSender: .phone)
        try mirror.beginSnapshot(descriptor)
        try mirror.stageSnapshotBatch(pairID: pairID, snapshotID: descriptor.snapshotID, records: [records[0]])
        XCTAssertThrowsError(try mirror.completeSnapshot(pairID: pairID, snapshotID: descriptor.snapshotID))
        XCTAssertNil(try mirror.profile())
        XCTAssertNil(try mirror.goals())

        try mirror.stageSnapshotBatch(pairID: pairID, snapshotID: descriptor.snapshotID, records: Array(records.dropFirst()))
        try mirror.completeSnapshot(pairID: pairID, snapshotID: descriptor.snapshotID)
        XCTAssertEqual(try mirror.profile()?.displayName, "Snapshot Fixture")
        XCTAssertEqual(try mirror.goals()?.targetWeightKg, 80)
        XCTAssertEqual(try mirror.appliedSequence(pairID: pairID, sender: .phone), descriptor.sourceSequence)
    }

    func testWatchOrderingDedupOldRevisionAndTerminalErrorRetention() throws {
        let store = try HealthCoachStore(inMemory: true)
        let oldExercise = ProgramExercise(exerciseID: "goblet_squat", displayName: "Goblet squat", order: 0, sets: 3, minimumReps: 8, maximumReps: 12)
        let oldProgram = TrainingProgram(name: "Old plan", goalSummary: "Strength", days: [TrainingDay(name: "Day A", order: 0, exercises: [oldExercise])], equipment: [])
        try store.saveProgram(oldProgram)
        let acceptedOld = try store.acceptProgram(oldProgram)
        XCTAssertEqual(try store.exercises().first(where: { $0.exerciseID == "goblet_squat" })?.displayName, "Goblet squat")
        let replacement = TrainingProgram(name: "New plan", goalSummary: "Strength", days: [TrainingDay(name: "Day B", order: 0, exercises: [ProgramExercise(exerciseID: "push_up", displayName: "Push-up", order: 0, sets: 3, minimumReps: 8, maximumReps: 15)])], equipment: [])
        try store.saveProgram(replacement)
        _ = try store.acceptProgram(replacement)

        let sessionID = UUID()
        let start = WatchCommand(kind: .startSession, sessionID: sessionID, sequence: 1, programID: acceptedOld.id, programRevision: acceptedOld.revision)
        XCTAssertEqual(try store.applyWatchCommand(start).status, .applied)
        let setCommand = WatchCommand(kind: .recordSet, sessionID: sessionID, sequence: 2, programID: acceptedOld.id, programRevision: acceptedOld.revision, exerciseID: "goblet_squat", reps: 10, loadKg: 20, rir: 2)
        XCTAssertEqual(try store.applyWatchCommand(setCommand).status, .applied)
        XCTAssertEqual(try store.applyWatchCommand(setCommand).status, .applied)
        XCTAssertEqual(try store.trainingSets().count, 1)
        XCTAssertEqual(try store.trainingSets().first?.programRevision, acceptedOld.revision)
        XCTAssertEqual(try store.trainingSets().first?.programID, acceptedOld.id)

        let metrics = LiveWorkoutMetrics(
            heartRateBpm: 142,
            averageHeartRateBpm: 132,
            peakHeartRateBpm: 158,
            activeEnergyKcal: 38.5,
            elapsedSeconds: 1_800,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let finish = WatchCommand(kind: .finishSession, sessionID: sessionID, sequence: 3, programID: acceptedOld.id, programRevision: acceptedOld.revision, liveMetrics: metrics)
        XCTAssertEqual(try store.applyWatchCommand(finish).status, .applied)
        let repeatedFinish = WatchCommand(kind: .finishSession, sessionID: sessionID, sequence: 4, programID: acceptedOld.id, programRevision: acceptedOld.revision)
        XCTAssertEqual(try store.applyWatchCommand(repeatedFinish).status, .applied)
        XCTAssertEqual(try store.workouts().first?.status, .completed)
        XCTAssertEqual(try store.workouts().first?.liveMetrics, metrics)

        let invalidMetrics = WatchCommand(
            kind: .finishSession,
            sessionID: sessionID,
            sequence: 5,
            programID: acceptedOld.id,
            programRevision: acceptedOld.revision,
            liveMetrics: LiveWorkoutMetrics(heartRateBpm: 301)
        )
        XCTAssertEqual(try store.applyWatchCommand(invalidMetrics).status, .rejected)
        XCTAssertEqual(try store.watchCommands().first(where: { $0.id == invalidMetrics.id })?.liveMetrics?.heartRateBpm, 301)

        let bad = WatchCommand(kind: .recordSet, sessionID: sessionID, sequence: 5, programID: acceptedOld.id, programRevision: acceptedOld.revision, exerciseID: "not_in_program", reps: 10, loadKg: 10)
        XCTAssertEqual(try store.applyWatchCommand(bad).status, .rejected)
        let persistedBad = try XCTUnwrap(try store.watchCommands().first(where: { $0.id == bad.id }))
        XCTAssertEqual(persistedBad.status, .rejected)
        XCTAssertFalse(persistedBad.terminalMessage?.isEmpty ?? true)
    }

    func testLiveWorkoutMetricsValidateAndRoundTrip() throws {
        let valid = LiveWorkoutMetrics(
            heartRateBpm: 120,
            averageHeartRateBpm: 110,
            peakHeartRateBpm: 145,
            activeEnergyKcal: 12.25,
            elapsedSeconds: 420,
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertNoThrow(try valid.validate())
        let encoded = try HealthCoachJSON.encode(valid)
        XCTAssertEqual(try HealthCoachJSON.decode(LiveWorkoutMetrics.self, from: encoded), valid)

        XCTAssertThrowsError(try LiveWorkoutMetrics(averageHeartRateBpm: 160, peakHeartRateBpm: 150).validate())
        XCTAssertThrowsError(try LiveWorkoutMetrics(heartRateBpm: 301).validate())
        XCTAssertThrowsError(try LiveWorkoutMetrics(activeEnergyKcal: -1).validate())
    }

    func testHealthKitDeterministicDatesHandleCrossMidnightAndDST() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let firstDay = try XCTUnwrap(DeterministicSummaries.dayRange(for: "2026-09-16", timeZone: utc))
        let secondDay = try XCTUnwrap(DeterministicSummaries.dayRange(for: "2026-09-17", timeZone: utc))
        let crossing = SleepInterval(start: firstDay.upperBound.addingTimeInterval(-1_800), end: secondDay.lowerBound.addingTimeInterval(1_800), stage: .asleep)
        XCTAssertEqual(DeterministicSummaries.mergedAsleepDurationHours(intervals: [crossing], within: firstDay), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DeterministicSummaries.mergedAsleepDurationHours(intervals: [crossing], within: secondDay), 0.5, accuracy: 0.0001)

        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let spring = try XCTUnwrap(DeterministicSummaries.dayRange(for: "2026-03-08", timeZone: newYork))
        let autumn = try XCTUnwrap(DeterministicSummaries.dayRange(for: "2026-11-01", timeZone: newYork))
        XCTAssertEqual(spring.upperBound.timeIntervalSince(spring.lowerBound), 23 * 3_600, accuracy: 0.001)
        XCTAssertEqual(autumn.upperBound.timeIntervalSince(autumn.lowerBound), 25 * 3_600, accuracy: 0.001)
    }

    func testWatchGapRemainsQueuedUntilEarlierCommandCommits() throws {
        let store = try HealthCoachStore(inMemory: true)
        let exercise = ProgramExercise(exerciseID: "push_up", displayName: "Push-up", order: 0, sets: 2, minimumReps: 8, maximumReps: 15)
        let program = TrainingProgram(name: "Fixture", goalSummary: "General", days: [TrainingDay(name: "Day", order: 0, exercises: [exercise])], equipment: [])
        try store.saveProgram(program)
        let accepted = try store.acceptProgram(program)
        let sessionID = UUID()
        let second = WatchCommand(kind: .recordSet, sessionID: sessionID, sequence: 2, programID: accepted.id, programRevision: accepted.revision, exerciseID: "push_up", reps: 10, loadKg: 0)
        XCTAssertThrowsError(try store.applyWatchCommand(second))
        XCTAssertEqual(try store.pendingWatchCommands().first?.id, second.id)
        _ = try store.applyWatchCommand(WatchCommand(kind: .startSession, sessionID: sessionID, sequence: 1, programID: accepted.id, programRevision: accepted.revision))
        XCTAssertEqual(try store.applyWatchCommand(second).status, .applied)
        XCTAssertEqual(try store.trainingSets().count, 1)
    }

    func testAggregationUsesManualWeightPrecedenceMergesSleepAndKeepsMissingNullable() throws {
        let tz = TimeZone(secondsFromGMT: 0)!
        let manual = Measurement(kind: .weight, value: 80, unit: "kg", measuredAt: Date(timeIntervalSince1970: 20), localDate: "2026-09-16", source: .manual)
        let healthKit = Measurement(kind: .weight, value: 81, unit: "kg", measuredAt: Date(timeIntervalSince1970: 30), localDate: "2026-09-16", source: .healthKit)
        let trend = DeterministicSummaries.sevenDayWeightTrend(endingOn: "2026-09-16", measurements: [manual, healthKit], timeZone: tz)
        XCTAssertEqual(trend.averageKg, 80)
        XCTAssertEqual(trend.sampleDayCount, 1)
        XCTAssertEqual(trend.missingLocalDates.count, 6)

        let range = DeterministicSummaries.dayRange(for: "2026-09-16", timeZone: tz)!
        let first = SleepInterval(start: range.lowerBound.addingTimeInterval(60), end: range.lowerBound.addingTimeInterval(3_600), stage: .asleep)
        let overlap = SleepInterval(start: range.lowerBound.addingTimeInterval(1_800), end: range.lowerBound.addingTimeInterval(7_200), stage: .asleep)
        XCTAssertEqual(DeterministicSummaries.mergedAsleepDurationHours(intervals: [first, overlap], within: range), 7_140 / 3_600, accuracy: 0.0001)

        let summaryA = HealthKitNormalizer.summary(localDate: "2026-09-16", dayStart: range.lowerBound, dayEnd: range.upperBound, timeZone: tz, values: HealthKitDailyValues(steps: nil))
        let summaryB = HealthKitNormalizer.summary(localDate: "2026-09-16", dayStart: range.lowerBound, dayEnd: range.upperBound, timeZone: tz, values: HealthKitDailyValues(steps: 4_000))
        XCTAssertEqual(summaryA.id, summaryB.id)
        XCTAssertNil(summaryA.steps)
    }

    func testCodexResultGenerationAndCancellationRejectLateExecution() throws {
        let store = try HealthCoachStore(inMemory: true)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "lentils"), enqueueAnalysis: false)
        let job = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        try store.recordMacExecutionUpdate(JobExecutionUpdate(jobID: job.id, generation: job.requestGeneration, sourceRevision: job.sourceRevision, status: .running, attempts: 1))
        try store.cancelJob(id: job.id)
        try store.recordMacExecutionUpdate(JobExecutionUpdate(jobID: job.id, generation: job.requestGeneration, sourceRevision: job.sourceRevision, status: .succeeded, attempts: 1))
        XCTAssertEqual(try store.job(id: job.id)?.status, .cancelled)

        let context = try store.jobContext(for: job)
        let output = JobOutput(kind: .analyzeMeal, meal: MealAnalysis(sourceMealID: meal.id, sourceMealRevision: meal.revision, components: [], totals: MacroTotals(kcal: 300, proteinGrams: 20, carbohydratesGrams: 30, fatGrams: 5), kcalRange: NutritionRange(lowKcal: 250, centralKcal: 300, highKcal: 350), assumptions: ["synthetic fixture"], sourceJobID: job.id, sourceModel: "fixture"))
        XCTAssertNoThrow(try output.validate())
        let result = JobResultEnvelope(jobID: job.id, generation: job.requestGeneration, kind: .analyzeMeal, inputRevision: job.inputRevision, sourceRevision: job.sourceRevision, context: context, output: output, sourceModel: "fixture")
        try store.recordMacResult(result)
        XCTAssertEqual(try store.job(id: job.id)?.status, .cancelled)
    }

    func testPairingPayloadIsRandomBoundAndRejectsExpiredValues() throws {
        let peerID = UUID()
        let credential = try PairingCredentialFactory.make(peerID: peerID, lifetime: 60)
        let qr = try PairingCredentialFactory.makeQRPayload(from: credential)
        let decoded = try PairingCredentialFactory.decodeQRPayload(qr)
        XCTAssertEqual(decoded.macPeerID, peerID)
        XCTAssertEqual(decoded.credential.count, 32)
        XCTAssertNotEqual(try PairingCredentialFactory.make(peerID: peerID).secret, credential.secret)
        let activated = PairingCredentialFactory.activated(credential)
        XCTAssertTrue(activated.isUsable)
        XCTAssertEqual(activated.expiresAt, .distantFuture)

        let expired = PairingQRPayload(pairID: UUID(), macPeerID: peerID, credential: Data(repeating: 1, count: 32), expiresAt: Date().addingTimeInterval(-1))
        XCTAssertThrowsError(try PairingCredentialFactory.decodeQRPayload(try HealthCoachJSON.encode(expired)))
    }

    func testLengthPrefixedCodecHandlesPartialFramesAndBounds() throws {
        let body = Data("synthetic".utf8)
        let frame = try LengthPrefixedFrameCodec.encode(body: body, maximumBodyBytes: 64)
        var decoder = LengthPrefixedFrameDecoder(maximumBodyBytes: 64)
        XCTAssertTrue(try decoder.append(frame.prefix(2)).isEmpty)
        XCTAssertEqual(try decoder.append(frame.dropFirst(2)), [body])
        XCTAssertTrue(decoder.remainder.isEmpty)
        XCTAssertThrowsError(try LengthPrefixedFrameCodec.encode(body: Data(repeating: 0, count: 65), maximumBodyBytes: 64))
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0])))
    }

    func testLengthPrefixedDecoderHandlesMultipleFramesAndArbitraryChunks() throws {
        let bodies = [
            Data("first synthetic frame".utf8),
            Data(repeating: 0xA5, count: 257),
            Data("last synthetic frame".utf8)
        ]
        let wire = try bodies.reduce(into: Data()) { partial, body in
            partial.append(try LengthPrefixedFrameCodec.encode(body: body, maximumBodyBytes: 512))
        }
        var decoder = LengthPrefixedFrameDecoder(maximumBodyBytes: 512)
        var decoded: [Data] = []
        var offset = 0
        let chunkSizes = [1, 3, 7, 2, 19, 5, 31]
        var chunkIndex = 0
        while offset < wire.count {
            let end = min(offset + chunkSizes[chunkIndex % chunkSizes.count], wire.count)
            decoded.append(contentsOf: try decoder.append(wire[offset..<end]))
            offset = end
            chunkIndex += 1
        }
        XCTAssertEqual(decoded, bodies)
        XCTAssertTrue(decoder.remainder.isEmpty)
    }

    func testOversizedMealRollsBackRecordJobAndOutboxTogether() throws {
        let store = try HealthCoachStore(inMemory: true)
        let text = String(repeating: "x", count: HealthCoachConstants.maximumFrameBytes)

        XCTAssertThrowsError(try store.saveMeal(Meal(localDate: "2026-09-16", originalText: text), enqueueAnalysis: false))
        XCTAssertTrue(try store.meals(includeDeleted: true).isEmpty)
        XCTAssertTrue(try store.pendingOutbox(sender: .phone).isEmpty)
        XCTAssertEqual(try store.currentWatermark(), 0)
    }

    func testJobSnapshotKeepsOneConsistentReadOnlyContext() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try HealthCoachStore(path: fixture.databaseURL)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "before snapshot"), enqueueAnalysis: false)
        let job = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        let snapshotURL = fixture.directoryURL.appendingPathComponent("job/context.sqlite")

        let artifact = try store.captureJobSnapshot(for: job, at: snapshotURL)
        var changed = meal
        changed.originalText = "after snapshot"
        _ = try store.saveMeal(changed, enqueueAnalysis: false)

        let snapshot = try HealthCoachStore(readOnlyPath: artifact.path)
        XCTAssertEqual(try snapshot.meal(id: meal.id)?.originalText, "before snapshot")
        XCTAssertEqual(artifact.context.prerequisiteRevisions["meal:\(meal.id.uuidString)"], meal.revision)
        XCTAssertEqual(try store.meal(id: meal.id)?.originalText, "after snapshot")
    }

    func testCancellationRetryGenerationRetainsLateResultAsHistory() throws {
        let store = try HealthCoachStore(inMemory: true)
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "lentils"), enqueueAnalysis: false)
        let first = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        try store.cancelJob(id: first.id)
        let retried = try store.retryJob(id: first.id)
        XCTAssertEqual(retried.requestGeneration, first.requestGeneration + 1)

        let late = JobResultEnvelope(
            jobID: first.id,
            generation: first.requestGeneration,
            kind: .analyzeMeal,
            inputRevision: first.inputRevision,
            sourceRevision: first.sourceRevision,
            context: try store.jobContext(for: first),
            output: syntheticMealOutput(mealID: meal.id, revision: meal.revision, jobID: first.id),
            sourceModel: "synthetic"
        )
        try store.recordMacResult(late)
        let afterLate = try XCTUnwrap(try store.job(id: first.id))
        XCTAssertEqual(afterLate.status, .queued)
        XCTAssertNil(afterLate.result)
        XCTAssertEqual(afterLate.executionStatus, .stale)
        XCTAssertEqual(afterLate.resultHistory.count, 1)

        let current = JobResultEnvelope(
            jobID: retried.id,
            generation: retried.requestGeneration,
            kind: .analyzeMeal,
            inputRevision: retried.inputRevision,
            sourceRevision: retried.sourceRevision,
            context: try store.jobContext(for: retried),
            output: syntheticMealOutput(mealID: meal.id, revision: meal.revision, jobID: retried.id),
            sourceModel: "synthetic"
        )
        try store.recordMacResult(current)
        let completed = try XCTUnwrap(try store.job(id: first.id))
        XCTAssertEqual(completed.status, .succeeded)
        XCTAssertEqual(completed.result?.generation, retried.requestGeneration)
        XCTAssertEqual(completed.resultHistory.count, 1)
    }

    func testReplacementPairRebindsPhoneOutboxAndDropsOldMacDeliveries() throws {
        let store = try HealthCoachStore(inMemory: true)
        let firstPair = UUID()
        let replacementPair = UUID()
        try store.setActivePair(firstPair)
        try store.saveProfile(UserProfile(displayName: "Synthetic athlete"))
        let job = try store.createJob(kind: .answerQuestion, request: JobRequest(question: "How was this week?"), inputRevision: 1)
        try store.recordMacExecutionUpdate(JobExecutionUpdate(jobID: job.id, generation: job.requestGeneration, sourceRevision: job.sourceRevision, status: .running, attempts: 1))
        XCTAssertFalse(try store.pendingOutbox(sender: .mac).isEmpty)

        try store.setActivePair(replacementPair)
        XCTAssertTrue(try store.pendingOutbox(sender: .phone).allSatisfy { $0.pairID == replacementPair })
        XCTAssertTrue(try store.pendingOutbox(sender: .mac).isEmpty)
        XCTAssertEqual(try store.appliedSequence(pairID: replacementPair, sender: .phone), 0)
    }

    func testPausePolicyGetsDurableMacAcknowledgment() async throws {
        let phoneStore = try HealthCoachStore(inMemory: true)
        let macStore = try HealthCoachStore(inMemory: true)
        let pairID = UUID()
        let phoneID = UUID()
        let macID = UUID()
        try phoneStore.setActivePair(pairID)
        try macStore.setActivePair(pairID)

        let phone = SyncSessionCoordinator(store: phoneStore, pairID: pairID, localPeerID: phoneID, remotePeerID: macID, localSender: .phone)
        let mac = SyncSessionCoordinator(store: macStore, pairID: pairID, localPeerID: macID, remotePeerID: phoneID, localSender: .mac)
        let phoneHello = try await phone.hello()
        let macHandshake = try await mac.handle(phoneHello)
        XCTAssertEqual(macHandshake.count, 1)
        _ = try await phone.handle(macHandshake[0])

        let policy = try phoneStore.setAnalysisEnabled(false)
        let mutation = try XCTUnwrap(try phoneStore.pendingOutbox(sender: .phone).first { $0.mutationKind == .policy })
        let batch = SyncBatch(sender: .phone, firstSequence: mutation.sequence, lastSequence: mutation.sequence, mutations: [mutation])
        let envelope = SyncEnvelope(
            kind: .batch,
            pairID: pairID,
            authenticatedPeerID: phoneID,
            sender: .phone,
            body: try HealthCoachJSON.encode(batch)
        )
        let responses = try await mac.handle(envelope)
        for response in responses {
            _ = try await phone.handle(response)
        }
        XCTAssertEqual(try phoneStore.analysisPolicyAcknowledgedRevision(), policy.revision)
        XCTAssertEqual(try macStore.analysisPolicy().revision, policy.revision)
    }

    func testRejectedWatchCommandCanRetryWithoutChangingItsIdentity() throws {
        let store = try HealthCoachStore(inMemory: true)
        let exercise = ProgramExercise(exerciseID: "push_up", displayName: "Push-up", order: 0, sets: 2, minimumReps: 8, maximumReps: 15)
        let program = TrainingProgram(name: "Watch fixture", goalSummary: "Strength", days: [TrainingDay(name: "Day", order: 0, exercises: [exercise])], equipment: [])
        try store.saveProgram(program)
        let accepted = try store.acceptProgram(program)
        let sessionID = UUID()
        _ = try store.applyWatchCommand(WatchCommand(kind: .startSession, sessionID: sessionID, sequence: 1, programID: accepted.id, programRevision: accepted.revision))

        let commandID = UUID()
        let rejected = WatchCommand(id: commandID, kind: .recordSet, sessionID: sessionID, sequence: 2, programID: accepted.id, programRevision: accepted.revision, exerciseID: "not_in_program", reps: 10, loadKg: 10)
        XCTAssertEqual(try store.applyWatchCommand(rejected).status, .rejected)
        let repaired = WatchCommand(id: commandID, kind: .recordSet, sessionID: sessionID, sequence: 2, programID: accepted.id, programRevision: accepted.revision, exerciseID: "push_up", reps: 10, loadKg: 10)
        XCTAssertEqual(try store.applyWatchCommand(repaired).status, .applied)
        XCTAssertEqual(try store.trainingSets().count, 1)
        XCTAssertEqual(try store.watchCommands().first(where: { $0.id == commandID })?.status, .applied)
    }

    func testWatchQueueRestartRetainsRejectedDataAndRetriesSameSequence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstQueue = try WatchCommandQueue(fileURL: fixture.directoryURL.appendingPathComponent("watch.json"))
        let sessionID = UUID()
        let command = WatchCommand(kind: .recordSet, sessionID: sessionID, sequence: 1, exerciseID: "push_up", reps: 10, loadKg: 10)
        _ = try firstQueue.enqueue(command)
        let rejection = WatchCommandAck(commandID: command.id, sessionID: sessionID, sequence: 1, status: .rejected, message: "synthetic terminal error", phoneRevision: 4)
        try firstQueue.acknowledge(rejection)

        let restarted = try WatchCommandQueue(fileURL: firstQueue.fileURL)
        let persisted = try XCTUnwrap(restarted.snapshotState().commands.first)
        XCTAssertEqual(persisted.id, command.id)
        XCTAssertEqual(persisted.sequence, command.sequence)
        XCTAssertEqual(persisted.reps, 10)
        XCTAssertEqual(persisted.status, .rejected)
        let retried = try XCTUnwrap(try restarted.retry(commandID: command.id))
        XCTAssertEqual(retried.id, command.id)
        XCTAssertEqual(retried.sequence, command.sequence)
        XCTAssertEqual(retried.status, .queued)
    }

    #if canImport(Network)
    func testRealTLSConnectionAcceptsValidPSKAndRejectsWrongSecret() async throws {
        let pairID = UUID()
        let serverPeerID = UUID()
        let clientPeerID = UUID()
        let secret = Data((0..<32).map { UInt8($0) })
        let credential = PairingCredential(
            pairID: pairID,
            peerID: clientPeerID,
            secret: secret,
            expiresAt: Date().addingTimeInterval(60)
        )
        let listener = try HealthCoachNetworkListener(peerID: serverPeerID, credential: credential)
        defer { listener.stop() }

        let received = expectation(description: "server receives a framed envelope")
        let sink = EnvelopeSink()
        listener.start { connection in
            Task {
                do {
                    for try await envelope in connection.receive() {
                        await sink.store(envelope)
                        received.fulfill()
                        break
                    }
                } catch {
                    // A failed credential is expected to close without a frame.
                }
                await connection.close()
            }
        }

        let port = try await waitForBoundPort(listener)
        let client = try await withTimeout(seconds: 3) {
            try await HealthCoachNetworkClient.connect(host: "127.0.0.1", port: port, credential: credential)
        }
        let sent = SyncEnvelope(
            kind: .goodbye,
            pairID: pairID,
            authenticatedPeerID: clientPeerID,
            sender: .phone,
            body: Data("synthetic TLS fixture".utf8)
        )
        try await client.send(sent)
        await fulfillment(of: [received], timeout: 3)
        let receivedEnvelope = await sink.value()
        XCTAssertEqual(receivedEnvelope, sent)
        await client.close()

        let wrongCredential = PairingCredential(
            pairID: pairID,
            peerID: clientPeerID,
            secret: Data(repeating: 0xff, count: 32),
            expiresAt: Date().addingTimeInterval(60)
        )
        var wrongConnectionSucceeded = false
        do {
            let wrongClient = try await withTimeout(seconds: 3) {
                try await HealthCoachNetworkClient.connect(host: "127.0.0.1", port: port, credential: wrongCredential)
            }
            wrongConnectionSucceeded = true
            await wrongClient.close()
        } catch {
            // The TLS handshake must fail before the sync protocol can run.
        }
        XCTAssertFalse(wrongConnectionSucceeded)
    }
    #endif

    #if os(macOS)
    func testCodexAppServerStartsWithCapturedSyntheticSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try HealthCoachStore(path: fixture.databaseURL)
        try store.saveProfile(UserProfile(displayName: "Synthetic App Server user"))
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic meal"), enqueueAnalysis: false)
        let job = try store.createJob(
            kind: .analyzeMeal,
            request: JobRequest(mealID: meal.id),
            inputRevision: meal.revision,
            sourceRevision: meal.revision
        )
        let artifact = try store.captureJobSnapshot(
            for: job,
            at: fixture.directoryURL.appendingPathComponent("app-server/context.sqlite")
        )
        guard let codex = CodexAppServerProbe.defaultExecutableURL() else {
            throw HealthCoachError.unavailable("The installed Codex executable was not found.")
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperCandidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/out/Products/Debug/healthcoach-mcp"),
            repoRoot.appendingPathComponent(".build/out/Products/Debug/healthcoach-mcp")
        ]
        guard let helper = helperCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw HealthCoachError.unavailable("The built healthcoach-mcp helper was not found.")
        }
        let client = CodexAppServerClient(configuration: CodexAppServerConfiguration(
            executableURL: codex,
            mcpExecutableURL: helper,
            snapshotURL: artifact.path,
            workingDirectory: fixture.directoryURL.appendingPathComponent("app-server")
        ))
        try await client.start()
        let effectiveTools = await client.effectiveMCPTools()
        XCTAssertEqual(Set(effectiveTools), HealthCoachMCPToolCatalog.nameSet)
        await client.stop()
    }

    func testCodexAppServerMatchesNestedTurnIDCompletionPayload() throws {
        let completedTurn = try XCTUnwrap(matchingCompletedTurn(
            from: [
                "threadId": "fake-thread",
                "turn": [
                    "id": "fake-turn",
                    "status": "completed",
                    "items": [["type": "agentMessage", "text": "synthetic completion"]]
                ]
            ],
            threadID: "fake-thread",
            turnID: "fake-turn"
        ))
        XCTAssertEqual(completedTurn["id"] as? String, "fake-turn")
        XCTAssertNil(matchingCompletedTurn(
            from: [
                "threadId": "fake-thread",
                "turn": ["id": "other-turn"]
            ],
            threadID: "fake-thread",
            turnID: "fake-turn"
        ))
    }

    func testMCPHelperInitializesListsToolsAndReadsOnlyFromSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try HealthCoachStore(path: fixture.databaseURL)
        try store.saveProfile(UserProfile(displayName: "Synthetic MCP user"))
        let meal = try store.saveMeal(Meal(localDate: "2026-09-16", originalText: "synthetic oats"), enqueueAnalysis: false)
        let job = try store.createJob(kind: .analyzeMeal, request: JobRequest(mealID: meal.id), inputRevision: meal.revision, sourceRevision: meal.revision)
        let artifact = try store.captureJobSnapshot(
            for: job,
            at: fixture.directoryURL.appendingPathComponent("mcp/context.sqlite")
        )

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/out/Products/Debug/healthcoach-mcp"),
            repoRoot.appendingPathComponent(".build/out/Products/Debug/healthcoach-mcp")
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw HealthCoachError.unavailable("The built healthcoach-mcp helper was not found.")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--database", artifact.path.path]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            _ = errors.fileHandleForReading.readDataToEndOfFile()
        }

        var reader = MCPJSONLineReader(handle: output.fileHandleForReading)
        try sendMCPRequest([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "HealthCoachTests", "version": "1"]
            ]
        ], to: input.fileHandleForWriting)
        let initialized = try reader.nextObject()
        XCTAssertEqual(initialized["id"] as? Int, 1)
        XCTAssertNotNil(initialized["result"] as? [String: Any])

        try sendMCPRequest(["jsonrpc": "2.0", "method": "notifications/initialized"], to: input.fileHandleForWriting)
        try sendMCPRequest(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]], to: input.fileHandleForWriting)
        let toolsResponse = try reader.nextObject()
        let toolsResult = try XCTUnwrap(toolsResponse["result"] as? [String: Any])
        let toolObjects = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(toolObjects.compactMap { $0["name"] as? String }), Set(HealthCoachMCPToolCatalog.names))

        try sendMCPRequest([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": ["name": "get_profile", "arguments": [:]]
        ], to: input.fileHandleForWriting)
        let profileResponse = try reader.nextObject()
        let profileResult = try XCTUnwrap(profileResponse["result"] as? [String: Any])
        let content = try XCTUnwrap(profileResult["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Synthetic MCP user"))
        XCTAssertFalse(profileResult["isError"] as? Bool ?? true)
    }
    #endif
}

private func assertStrictSchemaObject(_ value: Any, at path: String) throws {
    guard let object = value as? [String: Any] else {
        if let array = value as? [Any] {
            for (index, item) in array.enumerated() {
                try assertStrictSchemaObject(item, at: "\(path)[\(index)]")
            }
        }
        return
    }

    if let properties = object["properties"] as? [String: Any] {
        let required = Set(try XCTUnwrap(object["required"] as? [String], "Missing required at \(path)"))
        XCTAssertEqual(required, Set(properties.keys), "Strict schema properties mismatch at \(path)")
        for (name, property) in properties {
            try assertStrictSchemaObject(property, at: "\(path).\(name)")
        }
    }
    if let items = object["items"] {
        try assertStrictSchemaObject(items, at: "\(path).items")
    }
}

private func waitForRunnerCondition(_ label: String, _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw HealthCoachError.unavailable("The sync runner did not reach the expected synthetic state: \(label).")
}

private final class RunnerTestTransport: SyncByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveContinuation: AsyncThrowingStream<SyncEnvelope, Error>.Continuation?
    private var pendingIncoming: [SyncEnvelope] = []
    private var outgoing: [SyncEnvelope] = []

    func send(_ envelope: SyncEnvelope) async throws {
        recordOutgoing(envelope)
    }

    private func recordOutgoing(_ envelope: SyncEnvelope) {
        lock.lock()
        outgoing.append(envelope)
        lock.unlock()
    }

    func receive() -> AsyncThrowingStream<SyncEnvelope, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            receiveContinuation = continuation
            let pending = pendingIncoming
            pendingIncoming.removeAll()
            lock.unlock()
            for envelope in pending {
                continuation.yield(envelope)
            }
        }
    }

    func push(_ envelope: SyncEnvelope) {
        lock.lock()
        if let receiveContinuation {
            receiveContinuation.yield(envelope)
        } else {
            pendingIncoming.append(envelope)
        }
        lock.unlock()
    }

    func sent() -> [SyncEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return outgoing
    }

    func finish() {
        lock.lock()
        receiveContinuation?.finish()
        receiveContinuation = nil
        lock.unlock()
    }

    func close() async {
        finish()
    }
}

private func syntheticMealOutput(mealID: UUID, revision: Int, jobID: UUID) -> JobOutput {
    JobOutput(
        kind: .analyzeMeal,
        meal: MealAnalysis(
            sourceMealID: mealID,
            sourceMealRevision: revision,
            components: [],
            totals: MacroTotals(kcal: 300, proteinGrams: 20, carbohydratesGrams: 30, fatGrams: 5),
            kcalRange: NutritionRange(lowKcal: 250, centralKcal: 300, highKcal: 350),
            assumptions: ["synthetic fixture"],
            sourceJobID: jobID,
            sourceModel: "synthetic"
        )
    )
}

private final class Fixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("healthcoach-tests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("healthcoach.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

#if canImport(Network)
private actor EnvelopeSink {
    private var stored: SyncEnvelope?

    func store(_ envelope: SyncEnvelope) {
        stored = envelope
    }

    func value() -> SyncEnvelope? {
        stored
    }
}

private func waitForBoundPort(_ listener: HealthCoachNetworkListener) async throws -> NWEndpoint.Port {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if let port = listener.boundPort, port.rawValue != 0 {
            return port
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw HealthCoachError.protocolError("The synthetic TLS listener did not bind.")
}

private func withTimeout<T: Sendable>(seconds: UInt64, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw HealthCoachError.protocolError("The synthetic network operation timed out.")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
#endif

#if os(macOS)
private struct MCPJSONLineReader {
    let handle: FileHandle
    var buffer = Data()

    mutating func nextObject() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newline) + 1)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            }

            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 3_000)
            guard ready > 0 else {
                throw HealthCoachError.protocolError("The MCP helper did not answer within the test deadline.")
            }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else {
                throw HealthCoachError.protocolError("The MCP helper closed stdout before answering.")
            }
            buffer.append(contentsOf: bytes.prefix(Int(count)))
        }
    }
}

private func sendMCPRequest(_ object: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [])
    data.append(0x0a)
    try handle.write(contentsOf: data)
}
#endif
