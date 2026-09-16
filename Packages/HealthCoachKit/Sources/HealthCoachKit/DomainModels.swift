import Foundation

public enum HealthCoachConstants {
    public static let schemaVersion = 1
    public static let protocolVersion = 1
    public static let maximumFrameBytes = 1_048_576
    public static let maximumBatchRecords = 100
    public static let maximumHistoryDays = 90
}

public enum HealthCoachJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

public enum HealthCoachError: Error, LocalizedError, Sendable, Equatable {
    case invalidInput(String)
    case databaseFailure(String)
    case unsupportedVersion(Int)
    case malformedFrame
    case frameTooLarge(Int)
    case sequenceGap(expected: Int64, received: Int64)
    case wrongOwner
    case revokedPair
    case staleRevision
    case invalidOutput(String)
    case protocolError(String)
    case unavailable(String)
    case cancelled
    case snapshotIncomplete

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): return message
        case .databaseFailure(let message): return "Database error: \(message)"
        case .unsupportedVersion(let version): return "Unsupported version \(version)."
        case .malformedFrame: return "The sync frame was malformed."
        case .frameTooLarge(let size): return "The sync frame was too large (\(size) bytes)."
        case .sequenceGap(let expected, let received):
            return "Sync sequence gap: expected \(expected), received \(received)."
        case .wrongOwner: return "The mutation owner is not allowed for this peer."
        case .revokedPair: return "This pairing has been revoked."
        case .staleRevision: return "The record has changed since this request was created."
        case .invalidOutput(let message): return "The coaching result was invalid: \(message)"
        case .protocolError(let message): return "Protocol error: \(message)"
        case .unavailable(let message): return message
        case .cancelled: return "The job was cancelled."
        case .snapshotIncomplete: return "The snapshot transfer is incomplete."
        }
    }
}

public enum ExperienceLevel: String, Codable, CaseIterable, Sendable {
    case beginner
    case intermediate
    case advanced
}

public enum RecordOwner: String, Codable, Sendable {
    case phone
    case mac
}

public enum EntityType: String, Codable, CaseIterable, Sendable {
    case profile
    case goals
    case measurement
    case meal
    case workoutSession
    case trainingSet
    case trainingProgram
    case exercise
    case equipment
    case healthSummary
    case correction
    case preference
    case job
    case watchCommand
    case watchAck
}

public struct UserProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var experience: ExperienceLevel
    public var daysPerWeek: Int
    public var sessionDurationMinutes: Int
    public var scheduleConstraints: String
    public var exercisePreferences: [String]
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        experience: ExperienceLevel = .beginner,
        daysPerWeek: Int = 3,
        sessionDurationMinutes: Int = 45,
        scheduleConstraints: String = "",
        exercisePreferences: [String] = [],
        revision: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.experience = experience
        self.daysPerWeek = daysPerWeek
        self.sessionDurationMinutes = sessionDurationMinutes
        self.scheduleConstraints = scheduleConstraints
        self.exercisePreferences = exercisePreferences
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct Goals: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var currentWeightKg: Double?
    public var targetWeightKg: Double?
    public var targetBodyFatPercent: Double?
    public var targetWaistCm: Double?
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        currentWeightKg: Double? = nil,
        targetWeightKg: Double? = nil,
        targetBodyFatPercent: Double? = nil,
        targetWaistCm: Double? = nil,
        revision: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.currentWeightKg = currentWeightKg
        self.targetWeightKg = targetWeightKg
        self.targetBodyFatPercent = targetBodyFatPercent
        self.targetWaistCm = targetWaistCm
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public enum MeasurementKind: String, Codable, Sendable {
    case weight
    case waist
    case bodyFat
}

public enum MeasurementSource: String, Codable, Sendable {
    case manual
    case healthKit
}

public struct Measurement: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: MeasurementKind
    public var value: Double
    public var unit: String
    public var measuredAt: Date
    public var localDate: String
    public var source: MeasurementSource
    public var externalID: String?
    public var revision: Int
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: MeasurementKind,
        value: Double,
        unit: String,
        measuredAt: Date = Date(),
        localDate: String,
        source: MeasurementSource = .manual,
        externalID: String? = nil,
        revision: Int = 1,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.unit = unit
        self.measuredAt = measuredAt
        self.localDate = localDate
        self.source = source
        self.externalID = externalID
        self.revision = revision
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum AnalysisStatus: String, Codable, Sendable {
    case none
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public struct MacroTotals: Codable, Equatable, Sendable {
    public var kcal: Double
    public var proteinGrams: Double
    public var carbohydratesGrams: Double
    public var fatGrams: Double

    public init(kcal: Double = 0, proteinGrams: Double = 0, carbohydratesGrams: Double = 0, fatGrams: Double = 0) {
        self.kcal = kcal
        self.proteinGrams = proteinGrams
        self.carbohydratesGrams = carbohydratesGrams
        self.fatGrams = fatGrams
    }

    public static let zero = MacroTotals()
}

public struct NutritionRange: Codable, Equatable, Sendable {
    public var lowKcal: Double
    public var centralKcal: Double
    public var highKcal: Double

    public init(lowKcal: Double, centralKcal: Double, highKcal: Double) {
        self.lowKcal = lowKcal
        self.centralKcal = centralKcal
        self.highKcal = highKcal
    }
}

public struct MealComponentEstimate: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var estimatedQuantity: String
    public var totals: MacroTotals

    public init(id: UUID = UUID(), name: String, estimatedQuantity: String, totals: MacroTotals) {
        self.id = id
        self.name = name
        self.estimatedQuantity = estimatedQuantity
        self.totals = totals
    }
}

public struct MealAnalysis: Codable, Equatable, Sendable {
    public var sourceMealID: UUID
    public var sourceMealRevision: Int
    public var components: [MealComponentEstimate]
    public var totals: MacroTotals
    public var kcalRange: NutritionRange
    public var assumptions: [String]
    public var sourceJobID: UUID
    public var sourceModel: String
    public var generatedAt: Date

    public init(
        sourceMealID: UUID,
        sourceMealRevision: Int,
        components: [MealComponentEstimate],
        totals: MacroTotals,
        kcalRange: NutritionRange,
        assumptions: [String],
        sourceJobID: UUID,
        sourceModel: String,
        generatedAt: Date = Date()
    ) {
        self.sourceMealID = sourceMealID
        self.sourceMealRevision = sourceMealRevision
        self.components = components
        self.totals = totals
        self.kcalRange = kcalRange
        self.assumptions = assumptions
        self.sourceJobID = sourceJobID
        self.sourceModel = sourceModel
        self.generatedAt = generatedAt
    }
}

public struct MealTextRevision: Codable, Equatable, Sendable {
    public var revision: Int
    public var text: String
    public var createdAt: Date

    public init(revision: Int, text: String, createdAt: Date = Date()) {
        self.revision = revision
        self.text = text
        self.createdAt = createdAt
    }
}

public struct Meal: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var localDate: String
    public var capturedAt: Date
    public var originalText: String
    public var revision: Int
    public var revisions: [MealTextRevision]
    public var analysisStatus: AnalysisStatus
    public var analysis: MealAnalysis?
    public var corrected: Bool
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        localDate: String,
        capturedAt: Date = Date(),
        originalText: String,
        revision: Int = 1,
        revisions: [MealTextRevision]? = nil,
        analysisStatus: AnalysisStatus = .none,
        analysis: MealAnalysis? = nil,
        corrected: Bool = false,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.localDate = localDate
        self.capturedAt = capturedAt
        self.originalText = originalText
        self.revision = revision
        self.revisions = revisions ?? [MealTextRevision(revision: revision, text: originalText, createdAt: capturedAt)]
        self.analysisStatus = analysisStatus
        self.analysis = analysis
        self.corrected = corrected
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct UserCorrection: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var recordType: EntityType
    public var recordID: String
    public var field: String
    public var originalValue: String
    public var correctedValue: String
    public var sourceRevision: Int
    public var reusablePreference: Bool
    public var createdAt: Date
    public var revision: Int

    public init(
        id: UUID = UUID(),
        recordType: EntityType,
        recordID: String,
        field: String,
        originalValue: String,
        correctedValue: String,
        sourceRevision: Int,
        reusablePreference: Bool = false,
        createdAt: Date = Date(),
        revision: Int = 1
    ) {
        self.id = id
        self.recordType = recordType
        self.recordID = recordID
        self.field = field
        self.originalValue = originalValue
        self.correctedValue = correctedValue
        self.sourceRevision = sourceRevision
        self.reusablePreference = reusablePreference
        self.createdAt = createdAt
        self.revision = revision
    }
}

public enum WorkoutSource: String, Codable, Sendable {
    case manualStrength
    case healthKitImported
}

public enum WorkoutSessionStatus: String, Codable, Sendable {
    case active
    case completed
    case deleted
}

/// The latest live workout values collected by the Apple Watch. HealthCoach
/// stores a bounded summary rather than a raw sensor stream; HealthKit remains
/// the source of the underlying workout samples on the Watch.
public struct LiveWorkoutMetrics: Codable, Equatable, Sendable {
    public var heartRateBpm: Double?
    public var averageHeartRateBpm: Double?
    public var peakHeartRateBpm: Double?
    public var activeEnergyKcal: Double?
    public var elapsedSeconds: Double?
    public var capturedAt: Date

    public init(
        heartRateBpm: Double? = nil,
        averageHeartRateBpm: Double? = nil,
        peakHeartRateBpm: Double? = nil,
        activeEnergyKcal: Double? = nil,
        elapsedSeconds: Double? = nil,
        capturedAt: Date = Date()
    ) {
        self.heartRateBpm = heartRateBpm
        self.averageHeartRateBpm = averageHeartRateBpm
        self.peakHeartRateBpm = peakHeartRateBpm
        self.activeEnergyKcal = activeEnergyKcal
        self.elapsedSeconds = elapsedSeconds
        self.capturedAt = capturedAt
    }

    public func validate() throws {
        if let heartRateBpm {
            guard heartRateBpm.isFinite, heartRateBpm > 0, heartRateBpm <= 300 else {
                throw HealthCoachError.invalidInput("Heart rate must be finite and between 0 and 300 bpm.")
            }
        }
        if let averageHeartRateBpm {
            guard averageHeartRateBpm.isFinite, averageHeartRateBpm > 0, averageHeartRateBpm <= 300 else {
                throw HealthCoachError.invalidInput("Average heart rate is invalid.")
            }
        }
        if let peakHeartRateBpm {
            guard peakHeartRateBpm.isFinite, peakHeartRateBpm > 0, peakHeartRateBpm <= 300 else {
                throw HealthCoachError.invalidInput("Peak heart rate is invalid.")
            }
        }
        if let averageHeartRateBpm, let peakHeartRateBpm {
            guard averageHeartRateBpm <= peakHeartRateBpm else {
                throw HealthCoachError.invalidInput("Average heart rate cannot exceed peak heart rate.")
            }
        }
        if let activeEnergyKcal {
            guard activeEnergyKcal.isFinite, activeEnergyKcal >= 0 else {
                throw HealthCoachError.invalidInput("Active energy must be finite and non-negative.")
            }
        }
        if let elapsedSeconds {
            guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
                throw HealthCoachError.invalidInput("Workout duration must be finite and non-negative.")
            }
        }
    }
}

public struct WorkoutSession: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var localDate: String
    public var startedAt: Date
    public var endedAt: Date?
    public var programID: UUID?
    public var programRevision: Int?
    public var source: WorkoutSource
    public var status: WorkoutSessionStatus
    public var revision: Int
    public var setCount: Int
    public var liveMetrics: LiveWorkoutMetrics?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        localDate: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        programID: UUID? = nil,
        programRevision: Int? = nil,
        source: WorkoutSource = .manualStrength,
        status: WorkoutSessionStatus = .active,
        revision: Int = 1,
        setCount: Int = 0,
        liveMetrics: LiveWorkoutMetrics? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.localDate = localDate
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.programID = programID
        self.programRevision = programRevision
        self.source = source
        self.status = status
        self.revision = revision
        self.setCount = setCount
        self.liveMetrics = liveMetrics
        self.updatedAt = updatedAt
    }
}

public struct TrainingSet: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var exerciseID: String
    public var ordinal: Int
    public var reps: Int
    public var loadKg: Double
    public var rir: Double?
    public var rpe: Double?
    public var programID: UUID?
    public var programRevision: Int?
    public var completedAt: Date
    public var notes: String
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        exerciseID: String,
        ordinal: Int,
        reps: Int,
        loadKg: Double,
        rir: Double? = nil,
        rpe: Double? = nil,
        programID: UUID? = nil,
        programRevision: Int? = nil,
        completedAt: Date = Date(),
        notes: String = "",
        revision: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.exerciseID = exerciseID
        self.ordinal = ordinal
        self.reps = reps
        self.loadKg = loadKg
        self.rir = rir
        self.rpe = rpe
        self.programID = programID
        self.programRevision = programRevision
        self.completedAt = completedAt
        self.notes = notes
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct ExerciseAlternative: Codable, Equatable, Sendable {
    public var exerciseID: String
    public var displayName: String
    public var equipment: [String]
    public var reason: String

    public init(exerciseID: String, displayName: String, equipment: [String], reason: String) {
        self.exerciseID = exerciseID
        self.displayName = displayName
        self.equipment = equipment
        self.reason = reason
    }
}

public struct ProgramExercise: Codable, Identifiable, Equatable, Sendable {
    public var id: String { exerciseID }
    public var exerciseID: String
    public var displayName: String
    public var order: Int
    public var sets: Int
    public var minimumReps: Int
    public var maximumReps: Int
    public var targetRIR: Double?
    public var targetRPE: Double?
    public var progressionText: String
    public var equipment: [String]
    public var alternatives: [ExerciseAlternative]

    public init(
        exerciseID: String,
        displayName: String,
        order: Int,
        sets: Int,
        minimumReps: Int,
        maximumReps: Int,
        targetRIR: Double? = nil,
        targetRPE: Double? = nil,
        progressionText: String = "",
        equipment: [String] = [],
        alternatives: [ExerciseAlternative] = []
    ) {
        self.exerciseID = exerciseID
        self.displayName = displayName
        self.order = order
        self.sets = sets
        self.minimumReps = minimumReps
        self.maximumReps = maximumReps
        self.targetRIR = targetRIR
        self.targetRPE = targetRPE
        self.progressionText = progressionText
        self.equipment = equipment
        self.alternatives = alternatives
    }
}

public struct TrainingDay: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var order: Int
    public var exercises: [ProgramExercise]

    public init(id: UUID = UUID(), name: String, order: Int, exercises: [ProgramExercise]) {
        self.id = id
        self.name = name
        self.order = order
        self.exercises = exercises
    }
}

public enum ProgramStatus: String, Codable, Sendable {
    case proposed
    case current
    case archived
}

public struct TrainingProgram: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var revision: Int
    public var name: String
    public var goalSummary: String
    public var days: [TrainingDay]
    public var equipment: [String]
    public var status: ProgramStatus
    public var sourceJobID: UUID?
    public var sourceModel: String?
    public var generatedAt: Date
    public var acceptedAt: Date?
    public var inputRevision: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        goalSummary: String,
        days: [TrainingDay],
        equipment: [String],
        status: ProgramStatus = .proposed,
        sourceJobID: UUID? = nil,
        sourceModel: String? = nil,
        generatedAt: Date = Date(),
        acceptedAt: Date? = nil,
        inputRevision: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.goalSummary = goalSummary
        self.days = days
        self.equipment = equipment
        self.status = status
        self.sourceJobID = sourceJobID
        self.sourceModel = sourceModel
        self.generatedAt = generatedAt
        self.acceptedAt = acceptedAt
        self.inputRevision = inputRevision
        self.updatedAt = updatedAt
    }

    public func validate(excludedEquipment: Set<String>) throws {
        guard !days.isEmpty else { throw HealthCoachError.invalidOutput("A program must contain at least one day.") }
        guard Set(days.map(\.order)).count == days.count else {
            throw HealthCoachError.invalidOutput("Training day order must be unique.")
        }
        guard Set(equipment).isDisjoint(with: excludedEquipment) else {
            throw HealthCoachError.invalidOutput("The program uses excluded equipment.")
        }
        var exerciseIDs = Set<String>()
        for day in days {
            guard day.order >= 0 else { throw HealthCoachError.invalidOutput("Training day order must be non-negative.") }
            guard !day.exercises.isEmpty else { throw HealthCoachError.invalidOutput("Each training day must contain an exercise.") }
            guard Set(day.exercises.map(\.order)).count == day.exercises.count else {
                throw HealthCoachError.invalidOutput("Exercise order must be unique within a day.")
            }
            for exercise in day.exercises {
                guard exercise.exerciseID.matchesStableExerciseID else {
                    throw HealthCoachError.invalidOutput("Invalid exercise id \(exercise.exerciseID).")
                }
                guard exercise.order >= 0, exercise.sets > 0,
                      exercise.minimumReps > 0, exercise.maximumReps >= exercise.minimumReps else {
                    throw HealthCoachError.invalidOutput("Invalid target for \(exercise.exerciseID).")
                }
                guard Set(exercise.equipment).isDisjoint(with: excludedEquipment) else {
                    throw HealthCoachError.invalidOutput("The program uses excluded equipment.")
                }
                guard exerciseIDs.insert(exercise.exerciseID).inserted else {
                    throw HealthCoachError.invalidOutput("Duplicate exercise id \(exercise.exerciseID).")
                }
                var alternativeIDs = Set<String>()
                for alternative in exercise.alternatives {
                    guard alternative.exerciseID.matchesStableExerciseID else {
                        throw HealthCoachError.invalidOutput("Invalid alternative id \(alternative.exerciseID).")
                    }
                    guard alternative.exerciseID != exercise.exerciseID,
                          alternativeIDs.insert(alternative.exerciseID).inserted else {
                        throw HealthCoachError.invalidOutput("Duplicate exercise alternative for \(exercise.exerciseID).")
                    }
                    guard Set(alternative.equipment).isDisjoint(with: excludedEquipment) else {
                        throw HealthCoachError.invalidOutput("An alternative uses excluded equipment.")
                    }
                }
            }
        }
    }
}

public struct Exercise: Codable, Identifiable, Equatable, Sendable {
    public var id: String { exerciseID }
    public var exerciseID: String
    public var displayName: String
    public var equipment: [String]
    public var alternatives: [String]
    public var sourceProgramID: UUID?
    public var sourceProgramRevision: Int?
    public var revision: Int

    public init(
        exerciseID: String,
        displayName: String,
        equipment: [String],
        alternatives: [String] = [],
        sourceProgramID: UUID? = nil,
        sourceProgramRevision: Int? = nil,
        revision: Int = 1
    ) {
        self.exerciseID = exerciseID
        self.displayName = displayName
        self.equipment = equipment
        self.alternatives = alternatives
        self.sourceProgramID = sourceProgramID
        self.sourceProgramRevision = sourceProgramRevision
        self.revision = revision
    }
}

public struct EquipmentProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var available: [String]
    public var excluded: [String]
    public var revision: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(), available: [String] = [], excluded: [String] = [], revision: Int = 1, updatedAt: Date = Date()) {
        self.id = id
        self.available = available
        self.excluded = excluded
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public enum HealthMetricSource: String, Codable, Sendable {
    case healthKit
    case manual
    case unavailable
}

public struct HealthSummary: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var localDate: String
    public var dayStart: Date
    public var dayEnd: Date
    public var aggregationTimeZone: String
    public var steps: Double?
    public var activeEnergyKcal: Double?
    public var sleepHours: Double?
    public var restingHeartRateBpm: Double?
    public var hrvSDNNMilliseconds: Double?
    public var importedWorkoutCount: Int?
    public var source: HealthMetricSource
    public var freshness: Date?
    public var affectedSampleIDs: [String]
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        localDate: String,
        dayStart: Date,
        dayEnd: Date,
        aggregationTimeZone: String,
        steps: Double? = nil,
        activeEnergyKcal: Double? = nil,
        sleepHours: Double? = nil,
        restingHeartRateBpm: Double? = nil,
        hrvSDNNMilliseconds: Double? = nil,
        importedWorkoutCount: Int? = nil,
        source: HealthMetricSource = .healthKit,
        freshness: Date? = Date(),
        affectedSampleIDs: [String] = [],
        revision: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.localDate = localDate
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.aggregationTimeZone = aggregationTimeZone
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.sleepHours = sleepHours
        self.restingHeartRateBpm = restingHeartRateBpm
        self.hrvSDNNMilliseconds = hrvSDNNMilliseconds
        self.importedWorkoutCount = importedWorkoutCount
        self.source = source
        self.freshness = freshness
        self.affectedSampleIDs = affectedSampleIDs
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public enum JobKind: String, Codable, CaseIterable, Sendable {
    case analyzeMeal
    case generateProgram
    case suggestProgression
    case answerQuestion
}

public enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public enum JobExecutionStatus: String, Codable, Sendable {
    case notDelivered
    case delivered
    case acknowledged
    case stale
}

public enum JobIntent: String, Codable, Sendable {
    case active
    case cancelRequested
}

public struct JobContext: Codable, Equatable, Sendable {
    public var capturedWatermark: Int64
    public var prerequisiteRevisions: [String: Int]
    public var capturedAt: Date

    public init(capturedWatermark: Int64, prerequisiteRevisions: [String: Int], capturedAt: Date = Date()) {
        self.capturedWatermark = capturedWatermark
        self.prerequisiteRevisions = prerequisiteRevisions
        self.capturedAt = capturedAt
    }
}

public struct JobRequest: Codable, Equatable, Sendable {
    public var mealID: UUID?
    public var question: String?
    public var localDateFrom: String?
    public var localDateTo: String?
    public var exerciseID: String?
    public var sessionID: UUID?

    public init(
        mealID: UUID? = nil,
        question: String? = nil,
        localDateFrom: String? = nil,
        localDateTo: String? = nil,
        exerciseID: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.mealID = mealID
        self.question = question
        self.localDateFrom = localDateFrom
        self.localDateTo = localDateTo
        self.exerciseID = exerciseID
        self.sessionID = sessionID
    }
}

public struct ProgressionProposal: Codable, Equatable, Sendable {
    public var exerciseID: String
    public var sourceSessionID: UUID
    public var sourceSessionRevision: Int
    public var suggestedLoadKg: Double?
    public var suggestedMinimumReps: Int?
    public var suggestedMaximumReps: Int?
    public var rationale: String
    public var assumptions: [String]

    public init(
        exerciseID: String,
        sourceSessionID: UUID,
        sourceSessionRevision: Int,
        suggestedLoadKg: Double? = nil,
        suggestedMinimumReps: Int? = nil,
        suggestedMaximumReps: Int? = nil,
        rationale: String,
        assumptions: [String]
    ) {
        self.exerciseID = exerciseID
        self.sourceSessionID = sourceSessionID
        self.sourceSessionRevision = sourceSessionRevision
        self.suggestedLoadKg = suggestedLoadKg
        self.suggestedMinimumReps = suggestedMinimumReps
        self.suggestedMaximumReps = suggestedMaximumReps
        self.rationale = rationale
        self.assumptions = assumptions
    }
}

public struct CoachingSuggestion: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct CoachingAnswer: Codable, Equatable, Sendable {
    public var answerText: String
    public var referencedLocalDateRanges: [String]
    public var referencedRecordIDs: [String]
    public var uncertaintyAndLimitations: [String]
    public var suggestions: [CoachingSuggestion]

    public init(
        answerText: String,
        referencedLocalDateRanges: [String],
        referencedRecordIDs: [String],
        uncertaintyAndLimitations: [String],
        suggestions: [CoachingSuggestion] = []
    ) {
        self.answerText = answerText
        self.referencedLocalDateRanges = referencedLocalDateRanges
        self.referencedRecordIDs = referencedRecordIDs
        self.uncertaintyAndLimitations = uncertaintyAndLimitations
        self.suggestions = suggestions
    }
}

public struct JobOutput: Codable, Equatable, Sendable {
    public var kind: JobKind
    public var meal: MealAnalysis?
    public var program: TrainingProgram?
    public var progression: ProgressionProposal?
    public var coaching: CoachingAnswer?

    public init(kind: JobKind, meal: MealAnalysis? = nil, program: TrainingProgram? = nil, progression: ProgressionProposal? = nil, coaching: CoachingAnswer? = nil) {
        self.kind = kind
        self.meal = meal
        self.program = program
        self.progression = progression
        self.coaching = coaching
    }

    public func validate(excludedEquipment: Set<String> = []) throws {
        switch kind {
        case .analyzeMeal:
            guard let meal else { throw HealthCoachError.invalidOutput("Meal result is missing.") }
            try validateFiniteNonnegative(meal.totals)
            guard meal.kcalRange.lowKcal.isFinite, meal.kcalRange.centralKcal.isFinite, meal.kcalRange.highKcal.isFinite,
                  meal.kcalRange.lowKcal >= 0, meal.kcalRange.lowKcal <= meal.kcalRange.centralKcal,
                  meal.kcalRange.centralKcal <= meal.kcalRange.highKcal else {
                throw HealthCoachError.invalidOutput("Meal kcal range is not ordered.")
            }
            for component in meal.components { try validateFiniteNonnegative(component.totals) }
        case .generateProgram:
            guard let program else { throw HealthCoachError.invalidOutput("Program result is missing.") }
            try program.validate(excludedEquipment: excludedEquipment)
            guard program.days.allSatisfy({ day in
                day.exercises.allSatisfy { !$0.alternatives.isEmpty }
            }) else {
                throw HealthCoachError.invalidOutput("Every generated exercise must carry a cached alternative.")
            }
        case .suggestProgression:
            guard let progression else { throw HealthCoachError.invalidOutput("Progression result is missing.") }
            guard progression.exerciseID.matchesStableExerciseID else {
                throw HealthCoachError.invalidOutput("Progression exercise id is invalid.")
            }
            if let load = progression.suggestedLoadKg, (!load.isFinite || load < 0) {
                throw HealthCoachError.invalidOutput("Progression load is invalid.")
            }
            if let low = progression.suggestedMinimumReps, low <= 0 {
                throw HealthCoachError.invalidOutput("Progression minimum reps are invalid.")
            }
            if let high = progression.suggestedMaximumReps, high <= 0 {
                throw HealthCoachError.invalidOutput("Progression maximum reps are invalid.")
            }
            if let low = progression.suggestedMinimumReps, let high = progression.suggestedMaximumReps,
               low <= 0 || high < low {
                throw HealthCoachError.invalidOutput("Progression rep range is invalid.")
            }
        case .answerQuestion:
            guard let coaching, !coaching.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HealthCoachError.invalidOutput("Coaching answer is missing.")
            }
        }
    }

    private func validateFiniteNonnegative(_ totals: MacroTotals) throws {
        let values = [totals.kcal, totals.proteinGrams, totals.carbohydratesGrams, totals.fatGrams]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw HealthCoachError.invalidOutput("Meal nutrition values must be finite and non-negative.")
        }
    }
}

public struct JobResultEnvelope: Codable, Equatable, Sendable {
    public var jobID: UUID
    public var generation: Int
    public var kind: JobKind
    public var inputRevision: Int
    public var sourceRevision: Int?
    public var context: JobContext
    public var output: JobOutput
    public var sourceModel: String
    public var generatedAt: Date

    public init(
        jobID: UUID,
        generation: Int,
        kind: JobKind,
        inputRevision: Int,
        sourceRevision: Int?,
        context: JobContext,
        output: JobOutput,
        sourceModel: String,
        generatedAt: Date = Date()
    ) {
        self.jobID = jobID
        self.generation = generation
        self.kind = kind
        self.inputRevision = inputRevision
        self.sourceRevision = sourceRevision
        self.context = context
        self.output = output
        self.sourceModel = sourceModel
        self.generatedAt = generatedAt
    }
}

public struct JobExecutionUpdate: Codable, Equatable, Sendable {
    public var jobID: UUID
    public var generation: Int
    public var sourceRevision: Int?
    public var status: JobStatus
    public var attempts: Int
    public var threadID: String?
    public var turnID: String?
    public var errorMessage: String?
    public var updatedAt: Date

    public init(
        jobID: UUID,
        generation: Int,
        sourceRevision: Int?,
        status: JobStatus,
        attempts: Int,
        threadID: String? = nil,
        turnID: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.jobID = jobID
        self.generation = generation
        self.sourceRevision = sourceRevision
        self.status = status
        self.attempts = attempts
        self.threadID = threadID
        self.turnID = turnID
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

public struct AnalysisPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var revision: Int
    public var updatedAt: Date

    public init(enabled: Bool = true, revision: Int = 1, updatedAt: Date = Date()) {
        self.enabled = enabled
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct CoachJob: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: JobKind
    public var request: JobRequest
    public var inputRevision: Int
    public var sourceRevision: Int?
    public var requestGeneration: Int
    public var status: JobStatus
    public var executionStatus: JobExecutionStatus
    public var intent: JobIntent
    public var attempts: Int
    public var context: JobContext?
    public var result: JobResultEnvelope?
    public var resultHistory: [JobResultEnvelope]
    public var errorMessage: String?
    public var threadID: String?
    public var turnID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: JobKind,
        request: JobRequest,
        inputRevision: Int,
        sourceRevision: Int? = nil,
        requestGeneration: Int = 1,
        status: JobStatus = .queued,
        executionStatus: JobExecutionStatus = .notDelivered,
        intent: JobIntent = .active,
        attempts: Int = 0,
        context: JobContext? = nil,
        result: JobResultEnvelope? = nil,
        resultHistory: [JobResultEnvelope] = [],
        errorMessage: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.request = request
        self.inputRevision = inputRevision
        self.sourceRevision = sourceRevision
        self.requestGeneration = requestGeneration
        self.status = status
        self.executionStatus = executionStatus
        self.intent = intent
        self.attempts = attempts
        self.context = context
        self.result = result
        self.resultHistory = resultHistory
        self.errorMessage = errorMessage
        self.threadID = threadID
        self.turnID = turnID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SyncSender: String, Codable, Sendable {
    case phone
    case mac
}

public enum SyncMutationKind: String, Codable, Sendable {
    case userUpsert
    case userDelete
    case jobCommand
    case jobStatus
    case jobResult
    case policy
}

public struct SyncMutation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var pairID: UUID
    public var sender: SyncSender
    public var sequence: Int64
    public var mutationKind: SyncMutationKind
    public var entityType: EntityType?
    public var recordID: String?
    public var owner: RecordOwner
    public var sourceRevision: Int?
    public var payload: Data
    public var sourceWatermark: Int64
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        pairID: UUID,
        sender: SyncSender,
        sequence: Int64,
        mutationKind: SyncMutationKind,
        entityType: EntityType?,
        recordID: String?,
        owner: RecordOwner,
        sourceRevision: Int?,
        payload: Data,
        sourceWatermark: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.pairID = pairID
        self.sender = sender
        self.sequence = sequence
        self.mutationKind = mutationKind
        self.entityType = entityType
        self.recordID = recordID
        self.owner = owner
        self.sourceRevision = sourceRevision
        self.payload = payload
        self.sourceWatermark = sourceWatermark
        self.createdAt = createdAt
    }
}

public enum SyncMessageKind: String, Codable, Sendable {
    case hello
    case authenticated
    case batch
    case acknowledgment
    case snapshotOffer
    case snapshotBatch
    case snapshotComplete
    case pausePolicy
    case goodbye
}

public struct SyncEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: SyncMessageKind
    public var pairID: UUID
    public var authenticatedPeerID: UUID
    public var sender: SyncSender
    public var body: Data

    public init(version: Int = HealthCoachConstants.protocolVersion, kind: SyncMessageKind, pairID: UUID, authenticatedPeerID: UUID, sender: SyncSender, body: Data) {
        self.version = version
        self.kind = kind
        self.pairID = pairID
        self.authenticatedPeerID = authenticatedPeerID
        self.sender = sender
        self.body = body
    }
}

public struct SyncBatch: Codable, Equatable, Sendable {
    public var sender: SyncSender
    public var firstSequence: Int64
    public var lastSequence: Int64
    public var mutations: [SyncMutation]

    public init(sender: SyncSender, firstSequence: Int64, lastSequence: Int64, mutations: [SyncMutation]) {
        self.sender = sender
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.mutations = mutations
    }
}

public struct SyncAcknowledgment: Codable, Equatable, Sendable {
    public var sender: SyncSender
    public var lastSequence: Int64
    public var appliedMutationIDs: [UUID]
    public var rejectedMutationIDs: [UUID]

    public init(sender: SyncSender, lastSequence: Int64, appliedMutationIDs: [UUID], rejectedMutationIDs: [UUID] = []) {
        self.sender = sender
        self.lastSequence = lastSequence
        self.appliedMutationIDs = appliedMutationIDs
        self.rejectedMutationIDs = rejectedMutationIDs
    }
}

public struct SnapshotDescriptor: Codable, Equatable, Sendable {
    public var snapshotID: UUID
    public var pairID: UUID
    public var sourceSender: SyncSender
    public var sourceWatermark: Int64
    public var sourceSequence: Int64
    public var recordCount: Int
    public var createdAt: Date

    public init(snapshotID: UUID = UUID(), pairID: UUID, sourceSender: SyncSender = .phone, sourceWatermark: Int64, sourceSequence: Int64 = 0, recordCount: Int, createdAt: Date = Date()) {
        self.snapshotID = snapshotID
        self.pairID = pairID
        self.sourceSender = sourceSender
        self.sourceWatermark = sourceWatermark
        self.sourceSequence = sourceSequence
        self.recordCount = recordCount
        self.createdAt = createdAt
    }
}

public struct SnapshotRecord: Codable, Equatable, Sendable {
    public var entityType: EntityType
    public var recordID: String
    public var owner: RecordOwner
    public var revision: Int
    public var updatedAt: Date
    public var deletedAt: Date?
    public var payload: Data

    public init(entityType: EntityType, recordID: String, owner: RecordOwner, revision: Int, updatedAt: Date, deletedAt: Date?, payload: Data) {
        self.entityType = entityType
        self.recordID = recordID
        self.owner = owner
        self.revision = revision
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.payload = payload
    }
}

public struct SnapshotBatchPayload: Codable, Equatable, Sendable {
    public var snapshotID: UUID
    public var records: [SnapshotRecord]

    public init(snapshotID: UUID, records: [SnapshotRecord]) {
        self.snapshotID = snapshotID
        self.records = records
    }
}

public struct PairingCredential: Codable, Equatable, Sendable {
    public var pairID: UUID
    public var peerID: UUID
    public var secret: Data
    public var createdAt: Date
    public var expiresAt: Date
    public var revokedAt: Date?

    public init(pairID: UUID = UUID(), peerID: UUID, secret: Data, createdAt: Date = Date(), expiresAt: Date, revokedAt: Date? = nil) {
        self.pairID = pairID
        self.peerID = peerID
        self.secret = secret
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    public var isUsable: Bool {
        revokedAt == nil && expiresAt > Date() && secret.count == 32
    }
}

public struct PairingQRPayload: Codable, Equatable, Sendable {
    public var pairID: UUID
    public var macPeerID: UUID
    public var protocolVersion: Int
    public var credential: Data
    public var expiresAt: Date

    public init(pairID: UUID, macPeerID: UUID, protocolVersion: Int = HealthCoachConstants.protocolVersion, credential: Data, expiresAt: Date) {
        self.pairID = pairID
        self.macPeerID = macPeerID
        self.protocolVersion = protocolVersion
        self.credential = credential
        self.expiresAt = expiresAt
    }
}

public enum CodexReadiness: String, Codable, Sendable {
    case missingInstallation
    case signInRequired
    case offline
    case ready
    case restricted
}

public struct CodexStatus: Codable, Equatable, Sendable {
    public var readiness: CodexReadiness
    public var executablePath: String?
    public var modelID: String?
    public var reasoningEffort: String?
    public var effectiveMCPTools: [String]
    public var lastError: String?
    public var checkedAt: Date

    public init(
        readiness: CodexReadiness,
        executablePath: String? = nil,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        effectiveMCPTools: [String] = [],
        lastError: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.readiness = readiness
        self.executablePath = executablePath
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.effectiveMCPTools = effectiveMCPTools
        self.lastError = lastError
        self.checkedAt = checkedAt
    }
}

public enum WatchCommandKind: String, Codable, Sendable {
    case startSession
    case recordSet
    case finishSession
}

public enum WatchCommandStatus: String, Codable, Sendable {
    case queued
    case applied
    case duplicate
    case rejected
}

public struct WatchCommand: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: WatchCommandKind
    public var sessionID: UUID
    public var sequence: Int64
    public var programID: UUID?
    public var programRevision: Int?
    public var exerciseID: String?
    public var reps: Int?
    public var loadKg: Double?
    public var rir: Double?
    public var liveMetrics: LiveWorkoutMetrics?
    public var createdAt: Date
    public var status: WatchCommandStatus
    public var terminalMessage: String?

    public init(
        id: UUID = UUID(),
        kind: WatchCommandKind,
        sessionID: UUID,
        sequence: Int64,
        programID: UUID? = nil,
        programRevision: Int? = nil,
        exerciseID: String? = nil,
        reps: Int? = nil,
        loadKg: Double? = nil,
        rir: Double? = nil,
        liveMetrics: LiveWorkoutMetrics? = nil,
        createdAt: Date = Date(),
        status: WatchCommandStatus = .queued,
        terminalMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.sequence = sequence
        self.programID = programID
        self.programRevision = programRevision
        self.exerciseID = exerciseID
        self.reps = reps
        self.loadKg = loadKg
        self.rir = rir
        self.liveMetrics = liveMetrics
        self.createdAt = createdAt
        self.status = status
        self.terminalMessage = terminalMessage
    }
}

public struct WatchCommandAck: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var commandID: UUID
    public var sessionID: UUID
    public var sequence: Int64
    public var status: WatchCommandStatus
    public var message: String?
    public var phoneRevision: Int64
    public var committedAt: Date

    public init(
        id: UUID = UUID(),
        commandID: UUID,
        sessionID: UUID,
        sequence: Int64,
        status: WatchCommandStatus,
        message: String? = nil,
        phoneRevision: Int64,
        committedAt: Date = Date()
    ) {
        self.id = id
        self.commandID = commandID
        self.sessionID = sessionID
        self.sequence = sequence
        self.status = status
        self.message = message
        self.phoneRevision = phoneRevision
        self.committedAt = committedAt
    }
}

public struct WatchExerciseSnapshot: Codable, Equatable, Sendable {
    public var exerciseID: String
    public var displayName: String
    public var order: Int
    public var sets: Int
    public var minimumReps: Int
    public var maximumReps: Int
    public var targetRIR: Double?
    public var equipment: [String]

    public init(exerciseID: String, displayName: String, order: Int, sets: Int, minimumReps: Int, maximumReps: Int, targetRIR: Double?, equipment: [String]) {
        self.exerciseID = exerciseID
        self.displayName = displayName
        self.order = order
        self.sets = sets
        self.minimumReps = minimumReps
        self.maximumReps = maximumReps
        self.targetRIR = targetRIR
        self.equipment = equipment
    }
}

public struct WatchWorkoutSnapshot: Codable, Equatable, Sendable {
    public var phoneRevision: Int64
    public var localDate: String
    public var programID: UUID?
    public var programRevision: Int?
    public var programName: String?
    public var dayName: String?
    public var exercises: [WatchExerciseSnapshot]
    public var activeSessionID: UUID?
    public var activeSessionSetCount: Int
    public var liveMetrics: LiveWorkoutMetrics?
    public var generatedAt: Date

    public init(
        phoneRevision: Int64,
        localDate: String,
        programID: UUID?,
        programRevision: Int?,
        programName: String?,
        dayName: String?,
        exercises: [WatchExerciseSnapshot],
        activeSessionID: UUID?,
        activeSessionSetCount: Int,
        liveMetrics: LiveWorkoutMetrics? = nil,
        generatedAt: Date = Date()
    ) {
        self.phoneRevision = phoneRevision
        self.localDate = localDate
        self.programID = programID
        self.programRevision = programRevision
        self.programName = programName
        self.dayName = dayName
        self.exercises = exercises
        self.activeSessionID = activeSessionID
        self.activeSessionSetCount = activeSessionSetCount
        self.liveMetrics = liveMetrics
        self.generatedAt = generatedAt
    }
}

public struct WatchTransfer: Codable, Equatable, Sendable {
    public var kind: String
    public var command: WatchCommand?
    public var acknowledgment: WatchCommandAck?
    public var snapshot: WatchWorkoutSnapshot?

    public init(kind: String, command: WatchCommand? = nil, acknowledgment: WatchCommandAck? = nil, snapshot: WatchWorkoutSnapshot? = nil) {
        self.kind = kind
        self.command = command
        self.acknowledgment = acknowledgment
        self.snapshot = snapshot
    }
}

public extension String {
    var matchesStableExerciseID: Bool {
        guard !isEmpty else { return false }
        let scalars = unicodeScalars
        guard scalars.first?.value != nil else { return false }
        guard scalars.first!.value >= 97 && scalars.first!.value <= 122 else { return false }
        return scalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122) ||
            (scalar.value >= 48 && scalar.value <= 57) ||
            scalar.value == 95
        } && !contains("__")
    }
}
