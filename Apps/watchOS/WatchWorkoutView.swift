import SwiftUI
import HealthCoachKit

struct WatchWorkoutView: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: statusIcon).foregroundStyle(statusColor)
                        Text(model.status.title).font(.caption)
                    }
                    if let snapshot = model.snapshot {
                        Text(snapshot.programName ?? "Workout").font(.headline)
                        Text(snapshot.dayName ?? snapshot.localDate).font(.caption).foregroundStyle(.secondary)
                        if let current = model.currentExercise {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Current").font(.caption).foregroundStyle(.secondary)
                                Text(current.displayName).font(.headline)
                                Text("Set \(model.currentExerciseSetNumber) of \(current.sets) · \(current.minimumReps)–\(current.maximumReps) reps")
                                if let rir = current.targetRIR { Text("Target RIR \(String(format: "%.1f", rir))").font(.caption) }
                                Button("Log set") { model.showingSetEntry = true }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        } else {
                            Text("No exercises cached for this day.").foregroundStyle(.secondary)
                        }
                        if let next = model.nextExercise {
                            Text("Next: \(next.displayName)").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if snapshot.activeSessionID == nil {
                                Button("Start") { model.startSession() }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Finish") { model.finishSession() }.buttonStyle(.bordered)
                            }
                        }
                    } else {
                        ContentUnavailableView("Open HealthCoach on iPhone", systemImage: "iphone", description: Text("The Watch uses a cached accepted workout and never connects to the Mac directly."))
                    }
                    if let error = model.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if !model.terminalCommands.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Needs attention").font(.subheadline.bold())
                            ForEach(model.terminalCommands) { command in
                                VStack(alignment: .leading) {
                                    Text(command.kind.rawValue).font(.caption)
                                    Text(command.terminalMessage ?? "Rejected").font(.caption2).foregroundStyle(.red)
                                    Button("Retry") { model.retry(command) }.font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("Workout")
        }
        .sheet(isPresented: $model.showingSetEntry) {
            WatchSetEntryView(model: model)
        }
    }

    private var statusIcon: String {
        switch model.status {
        case .synced: return "checkmark.circle.fill"
        case .pending: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .unavailable: return "iphone.slash"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .synced: return .green
        case .pending: return .orange
        case .error: return .red
        case .unavailable: return .secondary
        }
    }
}

private struct WatchSetEntryView: View {
    @ObservedObject var model: WatchAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reps = ""
    @State private var load = ""
    @State private var rir = ""

    var body: some View {
        NavigationStack {
            Form {
                if let exercise = model.currentExercise {
                    Section(exercise.displayName) {
                        Text("Target \(exercise.minimumReps)–\(exercise.maximumReps) reps")
                        TextField("Reps", text: $reps)
                        TextField("kg", text: $load)
                        TextField("RIR optional", text: $rir)
                    }
                }
            }
            .navigationTitle("Set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let reps = Int(reps), let load = Double(load) else { return }
                        model.recordSet(reps: reps, loadKg: load, rir: Double(rir))
                        dismiss()
                    }
                }
            }
        }
    }
}
