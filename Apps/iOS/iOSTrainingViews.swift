import Foundation
import SwiftUI
import HealthCoachKit
import PhotosUI
import UIKit

struct TrainingView: View {
    @ObservedObject var model: iOSAppModel
    @State private var selectedExercise: ProgramExercise?
    @State private var showingProgramResetConfirmation = false
    @State private var showingCurrentProgramRemovalConfirmation = false

    var body: some View {
        List {
            Section("Current program") {
                if let program = model.displayedTrainingProgram {
                    ProgramSection(program: program, model: model, selectedExercise: $selectedExercise)
                    if let session = model.activeSession {
                        Button("Finish session (\(session.setCount) sets)", role: .destructive) { model.finishWorkout() }
                    } else {
                        Button("Start session") { model.startWorkout() }.buttonStyle(.borderedProminent)
                        Button("Remove current program", role: .destructive) {
                            showingCurrentProgramRemovalConfirmation = true
                        }
                    }
                } else {
                    Text("No accepted program yet. The latest proposal appears below for review.").foregroundStyle(.secondary)
                    if let activeJob = model.activeProgramJob {
                        Text("A program request is already \(activeJob.status == .running ? "running" : "queued").").font(.footnote).foregroundStyle(.secondary)
                    } else if !model.programSetupMissingFields.isEmpty {
                        ProgramSetupGate(model: model)
                    } else {
                        Button("Request a complete program") { model.requestProgram() }
                    }
                }
            }
            if let currentProgram = model.currentProgram {
                Section("Modify current program") {
                    ProgramModificationComposer(program: currentProgram, model: model)
                }
            }
            Section("Program request") {
                if let job = model.latestProgramJob {
                    ProgramJobRow(job: job, model: model)
                } else {
                    Text("No program request yet.").foregroundStyle(.secondary)
                }
                if let equipmentJob = model.activeEquipmentDiscoveryJob {
                    Text("Equipment lookup is \(equipmentJob.status == .running ? "running" : "queued"). You can still request a program; its result will be updated when the lookup finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !model.programJobs.isEmpty || !model.proposedPrograms.isEmpty {
                    Button("Reset old requests", role: .destructive) {
                        showingProgramResetConfirmation = true
                    }
                }
            }
            if !model.proposedPrograms.isEmpty {
                Section("Proposals") {
                    ForEach(model.proposedPrograms) { program in
                        NavigationLink {
                            ProgramProposalDetailView(program: program, model: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(program.name).font(.headline)
                                Text(program.goalSummary).font(.footnote).foregroundStyle(.secondary)
                                Text("Revision \(program.revision) · \(program.days.count) days · tap to review")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("History") {
                if model.workouts.isEmpty {
                    Text("No strength sessions logged yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.workouts) { workout in
                        NavigationLink {
                            WorkoutDetailView(workout: workout, sets: model.trainingSets.filter { $0.sessionID == workout.id }, model: model)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(workout.localDate)
                                Text("\(workout.setCount) sets · \(workout.status.rawValue)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Training")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
        .sheet(item: $selectedExercise) { exercise in
            SetEntrySheet(exercise: exercise, model: model)
        }
        .confirmationDialog(
            "Reset program requests?",
            isPresented: $showingProgramResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset old requests", role: .destructive) { model.resetProgramRequests() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Previous requests and proposals will be removed. Your accepted program and workout history will stay.")
        }
        .confirmationDialog(
            "Remove current program?",
            isPresented: $showingCurrentProgramRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove program", role: .destructive) { model.removeCurrentProgram() }
            Button("Keep program", role: .cancel) {}
        } message: {
            Text("The program will be archived. Your workout history will stay, and you can request a new program afterward.")
        }
    }
}

private struct ProgramJobRow: View {
    let job: CoachJob
    @ObservedObject var model: iOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Complete program").font(.headline)
                Spacer()
                Text(statusTitle).foregroundStyle(job.status == .deadLettered || job.status == .failed ? .red : .secondary)
            }
            if job.attempts > 0 { Text("Attempts: \(job.attempts)").font(.caption).foregroundStyle(.secondary) }
            if let error = job.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                if job.status == .queued || job.status == .running {
                    Button("Cancel") { model.cancel(job) }
                }
                if job.status == .failed || job.status == .deadLettered || job.status == .cancelled || job.executionStatus == .stale {
                    Button("Retry") { model.retry(job) }
                }
            }
            .font(.footnote)
        }
    }

    private var statusTitle: String {
        job.status == .deadLettered ? "Dead-lettered" : job.status.rawValue.capitalized
    }
}

private struct ProgramSetupGate: View {
    @ObservedObject var model: iOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before we build your first program")
                .font(.headline)
            Text("Tell us about your goal, body measurements, timeline, training background, and equipment first. No Codex request will be created until this is complete.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Still needed: " + model.programSetupMissingFields.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink("Complete program setup") {
                ProgramSetupView(model: model)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

private struct ProgramSetupView: View {
    @ObservedObject var model: iOSAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var primaryGoal: String
    @State private var currentWeight: String
    @State private var targetWeight: String
    @State private var targetBodyFat: String
    @State private var targetTimeframeWeeks: String
    @State private var experience: ExperienceLevel
    @State private var trainingExperienceMonths: String
    @State private var recentBreakWeeks: String
    @State private var availableEquipment: String
    @State private var excludedEquipment: String
    @State private var currentBodyFat: String
    @State private var currentWaist: String
    @State private var facilityType: EquipmentFacilityType
    @State private var facilityName: String
    @State private var allowOnlineLookup: Bool
    @State private var selectedPhotoItems: [PhotosPickerItem]
    @State private var referencePhotos: [Data]
    @State private var isLoadingPhotos = false
    @State private var validationMessage: String?

    init(model: iOSAppModel) {
        self.model = model
        _primaryGoal = State(initialValue: model.goals.primaryGoal ?? "")
        _currentWeight = State(initialValue: (model.goals.currentWeightKg ?? model.currentMeasurementValue(for: .weight)).map { healthCoachDecimal($0) } ?? "")
        _targetWeight = State(initialValue: model.goals.targetWeightKg.map { healthCoachDecimal($0) } ?? "")
        _targetBodyFat = State(initialValue: model.goals.targetBodyFatPercent.map { healthCoachDecimal($0) } ?? "")
        _targetTimeframeWeeks = State(initialValue: model.goals.targetTimeframeWeeks.map(String.init) ?? "")
        _experience = State(initialValue: model.profile.experience)
        _trainingExperienceMonths = State(initialValue: model.profile.trainingExperienceMonths.map(String.init) ?? "")
        _recentBreakWeeks = State(initialValue: model.profile.recentBreakWeeks.map(String.init) ?? "")
        _availableEquipment = State(initialValue: model.equipment.available.isEmpty ? "none" : model.equipment.available.joined(separator: ", "))
        _excludedEquipment = State(initialValue: model.equipment.excluded.joined(separator: ", "))
        _currentBodyFat = State(initialValue: model.currentMeasurementValue(for: .bodyFat).map { healthCoachDecimal($0) } ?? "")
        _currentWaist = State(initialValue: model.currentMeasurementValue(for: .waist).map { healthCoachDecimal($0) } ?? "")
        _facilityType = State(initialValue: model.equipment.facilityType ?? .standardGym)
        _facilityName = State(initialValue: model.equipment.facilityName ?? "")
        _allowOnlineLookup = State(initialValue: model.equipment.onlineLookupAllowed ?? false)
        _selectedPhotoItems = State(initialValue: [])
        _referencePhotos = State(initialValue: model.equipment.referencePhotos ?? [])
    }

    var body: some View {
        Form {
            Section {
                Text("This information is used to tailor the first proposal. You can edit it later in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Goal and measurements") {
                LabeledContent("Primary goal") {
                    TextField("e.g. fat loss", text: $primaryGoal)
                }
                LabeledContent("Current weight (kg)") {
                    TextField("Required", text: $currentWeight).keyboardType(.decimalPad)
                }
                LabeledContent("Target weight (kg)") {
                    TextField("Required", text: $targetWeight).keyboardType(.decimalPad)
                }
                LabeledContent("Current body fat (%)") {
                    TextField("Required", text: $currentBodyFat).keyboardType(.decimalPad)
                }
                LabeledContent("Target body fat (%)") {
                    TextField("Required", text: $targetBodyFat).keyboardType(.decimalPad)
                }
                LabeledContent("Target timeframe (weeks)") {
                    TextField("Required", text: $targetTimeframeWeeks).keyboardType(.numberPad)
                }
                LabeledContent("Current waist (cm)") {
                    TextField("Required", text: $currentWaist).keyboardType(.decimalPad)
                }
            }
            Section("Training background") {
                Picker("Experience", selection: $experience) {
                    ForEach(ExperienceLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                LabeledContent("Training experience (months)") {
                    TextField("Required", text: $trainingExperienceMonths).keyboardType(.numberPad)
                }
                LabeledContent("Recent break (weeks)") {
                    TextField("0 if none", text: $recentBreakWeeks).keyboardType(.numberPad)
                }
            }
            Section("Equipment") {
                Picker("Space type", selection: $facilityType) {
                    ForEach(EquipmentFacilityType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                LabeledContent("Gym/facility name") {
                    TextField("Optional", text: $facilityName)
                }
                LabeledContent("Available equipment") {
                    TextField("Write none if none", text: $availableEquipment)
                }
                LabeledContent("Equipment to avoid") {
                    TextField("Optional, comma separated", text: $excludedEquipment)
                }
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: HealthCoachConstants.maximumEquipmentPhotos,
                    matching: .images
                ) {
                    Label("Add gym photos", systemImage: "photo.on.rectangle.angled")
                }
                if isLoadingPhotos {
                    ProgressView("Preparing photos…")
                } else if !referencePhotos.isEmpty {
                    Text("\(referencePhotos.count) reference photo(s) ready for equipment detection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Allow public web lookup for this facility", isOn: $allowOnlineLookup)
                Text("If enabled, the facility name and selected photos may be sent to Codex for public equipment lookup. Health records are not sent to this lookup job.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let validationMessage {
                Section {
                    Text(validationMessage).foregroundStyle(.red)
                }
            }
            Section {
                Button("Save and continue") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Program setup")
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
        .onChange(of: selectedPhotoItems) { _, items in
            Task { await loadPhotos(items) }
        }
    }

    private func save() {
        let goal = primaryGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty,
              let currentWeightValue = healthCoachDouble(currentWeight), currentWeightValue > 0,
              let targetWeightValue = healthCoachDouble(targetWeight), targetWeightValue > 0,
              let targetBodyFatValue = healthCoachDouble(targetBodyFat), (0...100).contains(targetBodyFatValue),
              let currentBodyFatValue = healthCoachDouble(currentBodyFat), (0...100).contains(currentBodyFatValue),
              let currentWaistValue = healthCoachDouble(currentWaist), currentWaistValue > 0,
              let timeframe = Int(targetTimeframeWeeks), (1...520).contains(timeframe),
              let experienceMonths = Int(trainingExperienceMonths), experienceMonths >= 0,
              let breakWeeks = Int(recentBreakWeeks), breakWeeks >= 0 else {
            validationMessage = "Complete the required fields with valid values. Break weeks can be 0 if there was no break."
            return
        }

        model.saveProfile(
            displayName: model.profile.displayName,
            experience: experience,
            daysPerWeek: model.profile.daysPerWeek,
            duration: model.profile.sessionDurationMinutes,
            constraints: model.profile.scheduleConstraints,
            preferences: model.profile.exercisePreferences,
            trainingExperienceMonths: experienceMonths,
            recentBreakWeeks: breakWeeks
        )
        model.saveGoals(
            currentWeight: currentWeightValue,
            targetWeight: targetWeightValue,
            bodyFat: targetBodyFatValue,
            waist: model.goals.targetWaistCm,
            primaryGoal: goal,
            timeframeWeeks: timeframe
        )
        model.saveEquipment(
            available: normalizedEquipment(availableEquipment),
            excluded: split(excludedEquipment),
            facilityType: facilityType,
            facilityName: facilityName,
            referencePhotos: referencePhotos,
            onlineLookupAllowed: allowOnlineLookup
        )
        model.requestEquipmentDiscovery(
            facilityType: facilityType,
            facilityName: facilityName,
            referencePhotos: referencePhotos,
            allowsOnlineLookup: allowOnlineLookup
        )
        model.saveMeasurement(kind: .weight, value: currentWeightValue)
        model.saveMeasurement(kind: .bodyFat, value: currentBodyFatValue)
        model.saveMeasurement(kind: .waist, value: currentWaistValue)
        let missingFields = model.programSetupMissingFields
        if missingFields.isEmpty || missingFields.allSatisfy({ $0 == "equipment lookup" }) {
            dismiss()
        } else {
            validationMessage = "Please complete: " + missingFields.joined(separator: ", ")
        }
    }

    private func normalizedEquipment(_ value: String) -> [String] {
        let items = split(value)
        if facilityType == .homeNoEquipment && (items.isEmpty || items.allSatisfy({ ["none", "no equipment", "bodyweight"].contains($0.lowercased()) })) {
            return ["bodyweight"]
        }
        if items.allSatisfy({ ["none", "no equipment"].contains($0.lowercased()) }) { return [] }
        return items
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        var loaded: [Data] = []
        for item in items.prefix(HealthCoachConstants.maximumEquipmentPhotos) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let compressed = healthCoachCompressedJPEG(data) else { continue }
            loaded.append(compressed)
        }
        referencePhotos = loaded
        isLoadingPhotos = false
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

func healthCoachCompressedJPEG(_ data: Data) -> Data? {
    guard let image = UIImage(data: data), let source = image.cgImage else { return nil }
    let maxDimension: CGFloat = 1_200
    let scale = min(1, maxDimension / CGFloat(max(source.width, source.height)))
    let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
    let renderer = UIGraphicsImageRenderer(size: size)
    let compressed = renderer.jpegData(withCompressionQuality: 0.55) { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard compressed.count <= HealthCoachConstants.maximumEquipmentPhotoBytes else { return nil }
    return compressed
}

private struct ProgramModificationComposer: View {
    let program: TrainingProgram
    @ObservedObject var model: iOSAppModel
    @State private var comment = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var referencePhotos: [Data] = []
    @State private var isLoadingPhotos = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe what should change. Coach will return a complete proposal for review.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextEditor(text: $comment)
                .frame(minHeight: 90)
                .overlay(alignment: .topLeading) {
                    if comment.isEmpty {
                        Text("Example: remove wall push-ups and make the whole plan equipment-free.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: HealthCoachConstants.maximumEquipmentPhotos,
                matching: .images
            ) {
                Label("Attach equipment photos", systemImage: "photo.on.rectangle.angled")
            }
            if isLoadingPhotos {
                ProgressView("Preparing photos…")
            } else if !referencePhotos.isEmpty {
                Text("\(referencePhotos.count) equipment photo(s) attached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Request changes") {
                model.requestProgramModification(for: program, question: comment, referencePhotos: referencePhotos)
                comment = ""
                selectedPhotoItems = []
                referencePhotos = []
            }
            .buttonStyle(.borderedProminent)
            .disabled((comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && referencePhotos.isEmpty) || model.activeProgramJob != nil)
            if model.activeProgramJob != nil {
                Text("A program request is already in progress. You can submit another change after it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            Task { await loadPhotos(items) }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        var loaded: [Data] = []
        for item in items.prefix(HealthCoachConstants.maximumEquipmentPhotos) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let compressed = healthCoachCompressedJPEG(data) else { continue }
            loaded.append(compressed)
        }
        referencePhotos = loaded
        isLoadingPhotos = false
    }
}

private struct ProgramProposalDetailView: View {
    let program: TrainingProgram
    @ObservedObject var model: iOSAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingRejectConfirmation = false

    private var sourceJob: CoachJob? {
        model.programJob(for: program)
    }

    var body: some View {
        List {
            Section("Proposal") {
                Text(program.name).font(.title3.weight(.bold))
                Text(program.goalSummary).foregroundStyle(.secondary)
                LabeledContent("Revision", value: "\(program.revision)")
                LabeledContent("Training days", value: "\(program.days.count)")
                LabeledContent("Equipment", value: program.equipment.isEmpty ? "None" : program.equipment.joined(separator: ", "))
            }
            if let question = sourceJob?.request.question, !question.isEmpty {
                Section("Your requested change") {
                    Text(question)
                }
            }
            if let answer = sourceJob?.result?.output.coaching?.answerText {
                Section("Coach explanation") {
                    Text(answer)
                }
            }
            if let current = model.currentProgram, current.id != program.id {
                Section("What changes") {
                    ProgramChangeSummary(current: current, proposed: program)
                }
            } else {
                Section("What changes") {
                    Text("This is a new program proposal. Review each training day and exercise below before accepting it.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(program.days.sorted { $0.order < $1.order }) { day in
                Section(day.name) {
                    ForEach(day.exercises.sorted { $0.order < $1.order }) { exercise in
                        ProgramExerciseDetailRow(exercise: exercise)
                    }
                }
            }
            Section {
                HStack(spacing: 12) {
                    Button("Reject", role: .destructive) {
                        showingRejectConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Accept") {
                        model.acceptProgram(program)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Program proposal")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
        .confirmationDialog(
            "Reject this proposal?",
            isPresented: $showingRejectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reject proposal", role: .destructive) {
                model.rejectProgram(program)
                dismiss()
            }
            Button("Keep proposal", role: .cancel) {}
        } message: {
            Text("The proposal will be archived and no changes will be made to your current program.")
        }
    }
}

private struct ProgramExerciseDetailRow: View {
    let exercise: ProgramExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.displayName).font(.headline)
                Spacer()
                Text("\(exercise.sets) × \(exercise.minimumReps)–\(exercise.maximumReps)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let rir = exercise.targetRIR {
                Text("Target RIR \(String(format: "%.1f", rir))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let rpe = exercise.targetRPE {
                Text("Target RPE \(String(format: "%.1f", rpe))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(exercise.equipment.isEmpty ? "No equipment" : "Equipment: " + exercise.equipment.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !exercise.progressionText.isEmpty {
                Text(exercise.progressionText)
                    .font(.footnote)
            }
            if !exercise.alternatives.isEmpty {
                Text("Alternatives: " + exercise.alternatives.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProgramChangeSummary: View {
    let current: TrainingProgram
    let proposed: TrainingProgram

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if changes.isEmpty {
                Text("No exercise or target changes were detected; review the full proposal for context changes.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(changes, id: \.self) { change in
                    Label(change, systemImage: change.hasPrefix("Added") ? "plus.circle" : change.hasPrefix("Removed") ? "minus.circle" : "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private var changes: [String] {
        let currentMap = placements(for: current)
        let proposedMap = placements(for: proposed)
        let keys = Set(currentMap.keys).union(proposedMap.keys).sorted()
        return keys.compactMap { key in
            let old = currentMap[key]
            let new = proposedMap[key]
            switch (old, new) {
            case (nil, let new?):
                return "Added \(new.dayName): \(new.exercise.displayName)"
            case (let old?, nil):
                return "Removed \(old.dayName): \(old.exercise.displayName)"
            case (let old?, let new?) where old.exercise != new.exercise:
                let details = changedFields(old.exercise, new.exercise)
                return "Changed \(new.dayName): \(new.exercise.displayName) (\(details))"
            default:
                return nil
            }
        }
    }

    private func placements(for program: TrainingProgram) -> [String: (dayName: String, exercise: ProgramExercise)] {
        Dictionary(uniqueKeysWithValues: program.days.flatMap { day in
            day.exercises.map { exercise in
                ("\(day.order)|\(exercise.exerciseID)", (day.name, exercise))
            }
        })
    }

    private func changedFields(_ old: ProgramExercise, _ new: ProgramExercise) -> String {
        var fields: [String] = []
        if old.displayName != new.displayName { fields.append("name") }
        if old.sets != new.sets || old.minimumReps != new.minimumReps || old.maximumReps != new.maximumReps { fields.append("targets") }
        if old.targetRIR != new.targetRIR || old.targetRPE != new.targetRPE { fields.append("intensity") }
        if old.equipment != new.equipment { fields.append("equipment") }
        if old.progressionText != new.progressionText { fields.append("progression") }
        return fields.isEmpty ? "exercise placement" : fields.joined(separator: ", ")
    }
}

private struct ProgramSection: View {
    let program: TrainingProgram
    @ObservedObject var model: iOSAppModel
    @Binding var selectedExercise: ProgramExercise?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(program.name).font(.headline)
            Text(program.goalSummary).font(.footnote).foregroundStyle(.secondary)
            ForEach(program.days.sorted { $0.order < $1.order }) { day in
                Text(day.name).font(.subheadline.bold())
                ForEach(day.exercises.sorted { $0.order < $1.order }) { exercise in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Button {
                                if model.activeSession != nil { selectedExercise = exercise }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(exercise.displayName).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(exercise.sets) × \(exercise.minimumReps)–\(exercise.maximumReps)").foregroundStyle(.secondary)
                                    }
                                    if !exercise.alternatives.isEmpty {
                                        Text("Cached alternatives: " + exercise.alternatives.map(\.displayName).joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(model.activeSession == nil)
                            .accessibilityLabel("Log \(exercise.displayName)")
                            if let session = model.progressionSession(for: exercise.exerciseID) {
                                Button {
                                    model.requestProgression(for: exercise.exerciseID, session: session)
                                } label: {
                                    Image(systemName: "arrow.up.right")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Request progression for \(exercise.displayName)")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct WorkoutDetailView: View {
    let workout: WorkoutSession
    let sets: [TrainingSet]
    @ObservedObject var model: iOSAppModel

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Date", value: workout.localDate)
                LabeledContent("Status", value: workout.status.rawValue.capitalized)
                if let revision = workout.programRevision {
                    LabeledContent("Program revision", value: "\(revision)")
                }
                LabeledContent("Sets", value: "\(workout.setCount)")
                if workout.status == .completed {
                    if workout.liveMetrics != nil {
                        Text("Apple Watch recorded this workout and its live energy data.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Add activity to Apple Health") {
                            model.exportWorkoutToHealthKit(workout)
                        }
                        Text("The iPhone can save the strength activity and duration. It has no measured active-energy value unless the workout was recorded on Apple Watch.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let message = model.healthKitWorkoutMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let metrics = workout.liveMetrics {
                Section("Apple Watch workout") {
                    if let heartRate = metrics.heartRateBpm {
                        LabeledContent("Ending heart rate", value: "\(Int(heartRate.rounded())) bpm")
                    }
                    if let average = metrics.averageHeartRateBpm {
                        LabeledContent("Average heart rate", value: "\(Int(average.rounded())) bpm")
                    }
                    if let peak = metrics.peakHeartRateBpm {
                        LabeledContent("Peak heart rate", value: "\(Int(peak.rounded())) bpm")
                    }
                    if let energy = metrics.activeEnergyKcal {
                        LabeledContent("Active energy", value: String(format: "%.0f kcal", energy))
                    }
                    if let elapsed = metrics.elapsedSeconds {
                        LabeledContent("Recorded duration", value: durationText(elapsed))
                    }
                    Text("Summary received from the Apple Watch HealthKit workout session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Logged sets") {
                if sets.isEmpty {
                    Text("No sets logged.").foregroundStyle(.secondary)
                } else {
                    ForEach(sets.sorted { $0.ordinal < $1.ordinal }) { set in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(set.ordinal). \(set.exerciseID)")
                            HStack {
                                Text("\(set.reps) reps · \(String(format: "%.1f", set.loadKg)) kg")
                                if let rir = set.rir {
                                    Text("· RIR \(String(format: "%.1f", rir))")
                                }
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Workout")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
    }

    private func durationText(_ value: Double) -> String {
        let totalSeconds = max(Int(value.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct SetEntrySheet: View {
    let exercise: ProgramExercise
    @ObservedObject var model: iOSAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reps = ""
    @State private var load = ""
    @State private var rir = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(exercise.displayName) {
                    Text("Target: \(exercise.sets) sets of \(exercise.minimumReps)–\(exercise.maximumReps)")
                    TextField("Reps", text: $reps).keyboardType(.numberPad)
                    TextField("Load kg", text: $load).keyboardType(.decimalPad)
                    TextField("RIR (optional)", text: $rir).keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Log set")
            .scrollContentBackground(.hidden)
            .background(HealthCoachPalette.canvas)
            .tint(HealthCoachPalette.indigo)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let reps = Int(reps), let load = Double(load) else { return }
                        model.recordSet(exercise: exercise, reps: reps, loadKg: load, rir: Double(rir))
                        dismiss()
                    }
                }
            }
        }
    }
}
