import Foundation
import SwiftUI
import HealthCoachKit

struct TrainingView: View {
    @ObservedObject var model: iOSAppModel
    @State private var selectedExercise: ProgramExercise?

    var body: some View {
        List {
            Section("Current program") {
                if let program = model.displayedTrainingProgram {
                    ProgramSection(program: program, model: model, selectedExercise: $selectedExercise)
                    if let session = model.activeSession {
                        Button("Finish session (\(session.setCount) sets)", role: .destructive) { model.finishWorkout() }
                    } else {
                        Button("Start session") { model.startWorkout() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("No accepted program yet. Cached proposals appear here for review.").foregroundStyle(.secondary)
                    Button("Request a complete program") { model.requestProgram() }
                }
            }
            if !model.proposedPrograms.isEmpty {
                Section("Proposals") {
                    ForEach(model.proposedPrograms) { program in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(program.name).font(.headline)
                            Text(program.goalSummary).font(.footnote).foregroundStyle(.secondary)
                            Text("Revision \(program.revision) · \(program.days.count) days · alternatives cached")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Accept proposal") { model.acceptProgram(program) }
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
                            WorkoutDetailView(workout: workout, sets: model.trainingSets.filter { $0.sessionID == workout.id })
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
        .sheet(item: $selectedExercise) { exercise in
            SetEntrySheet(exercise: exercise, model: model)
        }
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

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Date", value: workout.localDate)
                LabeledContent("Status", value: workout.status.rawValue.capitalized)
                if let revision = workout.programRevision {
                    LabeledContent("Program revision", value: "\(revision)")
                }
                LabeledContent("Sets", value: "\(workout.setCount)")
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
