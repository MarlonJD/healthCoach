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
                        if snapshot.activeSessionID == nil && (model.liveStatus == .idle || isLiveError) {
                            Button("Start") { model.startSession() }.buttonStyle(.borderedProminent)
                        } else if model.liveStatus == .running || model.liveStatus == .paused {
                            Button("Finish") { model.finishSession() }.buttonStyle(.bordered)
                        } else if case .error = model.liveStatus {
                            Text("Workout could not continue. Retry the visible command or start again after resolving the error.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if snapshot.activeSessionID != nil && !model.liveStatus.isActive {
                            Text("This session is active on the iPhone. Waiting for Watch workout recovery.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if model.liveStatus.isActive {
                            ProgressView(model.liveStatus.title)
                                .font(.caption)
                        }
                        if model.liveStatus.isActive || model.liveMetrics != nil {
                            LiveWorkoutMetricsView(model: model)
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

    private var isLiveError: Bool {
        if case .error = model.liveStatus { return true }
        return false
    }
}

private struct LiveWorkoutMetricsView: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(model.liveStatus.title).font(.subheadline.bold())
            }
            HStack(spacing: 8) {
                metric(title: "HR", value: heartRate(model.liveMetrics?.heartRateBpm))
                metric(title: "Energy", value: energy(model.liveMetrics?.activeEnergyKcal))
            }
            HStack(spacing: 8) {
                metric(title: "Avg", value: heartRate(model.liveMetrics?.averageHeartRateBpm))
                metric(title: "Peak", value: heartRate(model.liveMetrics?.peakHeartRateBpm))
            }
            if let elapsed = model.liveMetrics?.elapsedSeconds {
                Text("Elapsed \(duration(elapsed))").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Live values come from this Watch's HealthKit workout session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heartRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) bpm"
    }

    private func energy(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) kcal"
    }

    private func duration(_ value: Double) -> String {
        let totalSeconds = max(Int(value.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
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
