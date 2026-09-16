import SwiftUI
import HealthCoachKit

private enum WatchPalette {
    static let accent = Color(red: 0.30, green: 0.52, blue: 0.95)
    static let energy = Color.orange
    static let success = Color.green
}

struct WatchWorkoutView: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(model.status.title)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(statusColor.opacity(0.14), in: Capsule())
                    if let snapshot = model.snapshot {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.programName ?? "Workout")
                                .font(.title3.weight(.bold))
                            Text(snapshot.dayName ?? snapshot.localDate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let current = model.currentExercise {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "figure.strengthtraining.traditional")
                                        .font(.headline)
                                        .foregroundStyle(WatchPalette.accent)
                                        .frame(width: 28, height: 28)
                                        .background(WatchPalette.accent.opacity(0.14), in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Current exercise")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(current.displayName)
                                            .font(.headline.weight(.bold))
                                            .lineLimit(2)
                                    }
                                }
                                Text("Set \(model.currentExerciseSetNumber) of \(max(current.sets, 1)) · \(current.minimumReps)–\(current.maximumReps) reps")
                                    .font(.subheadline.weight(.semibold))
                                ProgressView(
                                    value: Double(max(model.currentExerciseSetNumber - 1, 0)),
                                    total: Double(max(current.sets, 1))
                                )
                                .tint(WatchPalette.success)
                                if let rir = current.targetRIR {
                                    Text("Target RIR \(String(format: "%.1f", rir))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    model.showingSetEntry = true
                                } label: {
                                    Label("Log set", systemImage: "plus")
                                }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        } else {
                            Text("No exercises cached for this day.").foregroundStyle(.secondary)
                        }
                        if let next = model.nextExercise {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.secondary)
                                Text("Next · \(next.displayName)")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if snapshot.activeSessionID == nil && (model.liveStatus == .idle || isLiveError) {
                            Button {
                                model.startSession()
                            } label: {
                                Label("Start workout", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } else if model.liveStatus == .running || model.liveStatus == .paused {
                            Button {
                                model.finishSession()
                            } label: {
                                Label("Finish workout", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
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
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !model.terminalCommands.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            ForEach(model.terminalCommands) { command in
                                VStack(alignment: .leading) {
                                    Text(command.kind.rawValue).font(.caption)
                                    Text(command.terminalMessage ?? "Rejected").font(.caption2).foregroundStyle(.red)
                                    Button("Retry") { model.retry(command) }.font(.caption)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
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
            HStack(spacing: 7) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text(model.liveStatus.title)
                    .font(.subheadline.bold())
                Spacer()
                if let elapsed = model.liveMetrics?.elapsedSeconds {
                    Text(duration(elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                WatchMetricTile(title: "Heart rate", value: metricValue(model.liveMetrics?.heartRateBpm), unit: "bpm", systemImage: "heart.fill", tint: .red)
                WatchMetricTile(title: "Active energy", value: metricValue(model.liveMetrics?.activeEnergyKcal), unit: "kcal", systemImage: "flame.fill", tint: WatchPalette.energy)
            }
            HStack(spacing: 8) {
                WatchMetricTile(title: "Average", value: metricValue(model.liveMetrics?.averageHeartRateBpm), unit: "bpm", systemImage: "waveform.path.ecg", tint: WatchPalette.accent)
                WatchMetricTile(title: "Peak", value: metricValue(model.liveMetrics?.peakHeartRateBpm), unit: "bpm", systemImage: "arrow.up.right", tint: .purple)
            }
            Text("Live values come from this Watch's HealthKit workout session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
    }

    private func metricValue(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value.rounded()))
    }

    private func duration(_ value: Double) -> String {
        let totalSeconds = max(Int(value.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct WatchMetricTile: View {
    let title: String
    let value: String
    let unit: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
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
