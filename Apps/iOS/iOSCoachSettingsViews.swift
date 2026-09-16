import SwiftUI
import HealthCoachKit

struct CoachView: View {
    @ObservedObject var model: iOSAppModel
    @State private var question = ""
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        List {
            Section("Ask from recorded context") {
                TextField("Question", text: $question, axis: .vertical).lineLimit(3...6)
                HStack {
                    TextField("From YYYY-MM-DD", text: $from)
                    TextField("To YYYY-MM-DD", text: $to)
                }
                Button("Queue question") {
                    model.askCoach(question: question, from: from, to: to)
                    question = ""
                }
                .buttonStyle(.borderedProminent)
            }
            Section("Jobs") {
                if model.jobs.isEmpty {
                    Text("Questions, meal estimates, programs, and progression proposals will appear here.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.jobs) { job in
                        JobRow(job: job, model: model)
                    }
                }
            }
        }
        .navigationTitle("Coach")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
    }
}

private struct JobRow: View {
    let job: CoachJob
    @ObservedObject var model: iOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.kind.rawValue).font(.headline)
                Spacer()
                Text(job.status.rawValue.capitalized).foregroundStyle(job.status == .failed ? .red : .secondary)
            }
            if let question = job.request.question { Text(question).lineLimit(3) }
            if let error = job.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            if let answer = job.result?.output.coaching {
                Text(answer.answerText)
                ForEach(answer.uncertaintyAndLimitations, id: \.self) { Text("• \($0)").font(.footnote).foregroundStyle(.secondary) }
            }
            if let progression = job.result?.output.progression {
                Text("\(progression.exerciseID): \(progression.rationale)")
            }
            HStack {
                if job.status == .queued || job.status == .running { Button("Cancel") { model.cancel(job) } }
                if job.status == .failed || job.status == .cancelled || job.executionStatus == .stale { Button("Retry") { model.retry(job) } }
            }
            .font(.footnote)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: iOSAppModel
    @State private var displayName = ""
    @State private var daysPerWeek = "3"
    @State private var duration = "45"
    @State private var constraints = ""
    @State private var preferences = ""
    @State private var targetWeight = ""
    @State private var targetBodyFat = ""
    @State private var targetWaist = ""
    @State private var availableEquipment = ""
    @State private var excludedEquipment = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make the plan fit your life")
                        .font(.title3.weight(.bold))
                    Text("HealthCoach keeps daily logging light. Set your coaching context here, then let HealthKit fill in the routine signals.")
                        .font(.footnote)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            Section("Profile") {
                TextField("Display name", text: $displayName)
                Picker("Experience", selection: Binding(get: { model.profile.experience }, set: { model.saveProfile(displayName: displayName, experience: $0, daysPerWeek: Int(daysPerWeek) ?? 3, duration: Int(duration) ?? 45, constraints: constraints, preferences: split(preferences)) })) {
                    ForEach(ExperienceLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                TextField("Days per week", text: $daysPerWeek).keyboardType(.numberPad)
                TextField("Session minutes", text: $duration).keyboardType(.numberPad)
                TextField("Schedule constraints", text: $constraints, axis: .vertical)
                TextField("Exercise preferences, comma separated", text: $preferences)
                Button("Save profile") { saveProfile() }
            }
            Section("Goals") {
                Text("These are target values, not daily measurements.")
                    .font(.footnote)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
                TextField("Target weight kg", text: $targetWeight).keyboardType(.decimalPad)
                TextField("Target body fat %", text: $targetBodyFat).keyboardType(.decimalPad)
                TextField("Target waist cm", text: $targetWaist).keyboardType(.decimalPad)
                Button("Save targets") { saveGoals() }
            }
            Section("Body data") {
                NavigationLink {
                    BodyMeasurementsView(model: model)
                } label: {
                    Label("Body measurements", systemImage: "figure.stand")
                }
                Text("Weight is imported from HealthKit when available. Use the body measurements screen for occasional waist, body-fat, or missing-weight check-ins.")
                    .font(.footnote)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
            }
            Section("Equipment") {
                TextField("Available, comma separated", text: $availableEquipment)
                TextField("Excluded, comma separated", text: $excludedEquipment)
                Button("Save equipment") { model.saveEquipment(available: split(availableEquipment), excluded: split(excludedEquipment)) }
            }
            Section("HealthKit") {
                Text("HealthCoach reads only the requested HealthKit metrics. Missing data stays unavailable instead of becoming a made-up zero.")
                    .font(.footnote)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
                Button("Refresh last 90 days") { Task { await model.importHealthKit() } }
                if let message = model.healthKitMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                }
            }
            Section("Pairing and analysis") {
                StatusRow(title: "Mac", value: model.syncStatus.title, systemImage: "laptopcomputer")
                Button("Scan Mac pairing QR") { model.showingPairingScanner = true }
                Button("Unpair", role: .destructive) { model.unpair() }.disabled(model.syncStatus == .unpaired)
                Toggle("Allow Codex analysis", isOn: Binding(get: { model.analysisEnabled }, set: { model.toggleAnalysis($0) }))
                Text("The Mac runs the installed Codex App Server with your existing sign-in. New analysis requires Mac/model connectivity; storage and iPhone↔Mac sync remain local.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
        .onAppear(perform: load)
    }

    private func load() {
        displayName = model.profile.displayName
        daysPerWeek = String(model.profile.daysPerWeek)
        duration = String(model.profile.sessionDurationMinutes)
        constraints = model.profile.scheduleConstraints
        preferences = model.profile.exercisePreferences.joined(separator: ", ")
        targetWeight = model.goals.targetWeightKg.map { String($0) } ?? ""
        targetBodyFat = model.goals.targetBodyFatPercent.map { String($0) } ?? ""
        targetWaist = model.goals.targetWaistCm.map { String($0) } ?? ""
        availableEquipment = model.equipment.available.joined(separator: ", ")
        excludedEquipment = model.equipment.excluded.joined(separator: ", ")
    }

    private func saveProfile() {
        model.saveProfile(displayName: displayName, experience: model.profile.experience, daysPerWeek: Int(daysPerWeek) ?? 3, duration: Int(duration) ?? 45, constraints: constraints, preferences: split(preferences))
    }

    private func saveGoals() {
        model.saveGoals(currentWeight: model.goals.currentWeightKg, targetWeight: Double(targetWeight), bodyFat: Double(targetBodyFat), waist: Double(targetWaist))
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

struct BodyMeasurementsView: View {
    @ObservedObject var model: iOSAppModel
    @State private var showingAddMeasurement = false
    @State private var measurementKindToAdd: MeasurementKind = .waist

    private let kinds: [MeasurementKind] = [.weight, .waist, .bodyFat]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                intro
                ForEach(kinds, id: \.rawValue) { kind in
                    measurementCard(for: kind)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(HealthCoachPalette.canvas.ignoresSafeArea())
        .navigationTitle("Body measurements")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    measurementKindToAdd = .waist
                    showingAddMeasurement = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add body measurement")
            }
        }
        .sheet(isPresented: $showingAddMeasurement) {
            ManualMeasurementSheet(model: model, initialKind: measurementKindToAdd)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Occasional check-ins")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("You do not need to enter these every day. Weight comes from HealthKit automatically when available; waist and body fat are manual trend markers.")
                .font(.subheadline)
                .foregroundStyle(HealthCoachPalette.secondaryInk)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func measurementCard(for kind: MeasurementKind) -> some View {
        let entries = history(for: kind)
        let current = currentMeasurement(for: kind, entries: entries)

        HealthCoachCard(title(for: kind), eyebrow: sourceLabel(for: kind), systemImage: icon(for: kind), tint: tint(for: kind)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest")
                        .font(.caption)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                    if let current {
                        HStack(alignment: .lastTextBaseline, spacing: 5) {
                            Text(String(format: "%.1f", current.value))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(current.unit)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(HealthCoachPalette.secondaryInk)
                        }
                        Text(current.source == .healthKit ? "HealthKit" : "Manual")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(current.source == .healthKit ? HealthCoachPalette.mint : HealthCoachPalette.orange)
                    } else {
                        Text("Not recorded")
                            .font(.headline.weight(.bold))
                        Text(kind == .weight ? "Waiting for HealthKit" : "Add when useful")
                            .font(.caption)
                            .foregroundStyle(HealthCoachPalette.secondaryInk)
                    }
                }
                Spacer()
                Button {
                    measurementKindToAdd = kind
                    showingAddMeasurement = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(tint(for: kind))
            }

            Divider()

            if entries.isEmpty {
                Text("No entries yet. This is intentionally not part of the daily capture flow.")
                    .font(.footnote)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(4))) { measurement in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(measurement.measuredAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.subheadline.weight(.medium))
                                Text(measurement.source == .healthKit ? "HealthKit" : "Manual entry")
                                    .font(.caption)
                                    .foregroundStyle(HealthCoachPalette.secondaryInk)
                            }
                            Spacer()
                            Text(String(format: "%.1f %@", measurement.value, measurement.unit))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            if measurement.source == .manual {
                                Button(role: .destructive) {
                                    model.deleteMeasurement(measurement)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete manual measurement")
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func history(for kind: MeasurementKind) -> [HealthCoachKit.Measurement] {
        model.measurements
            .filter { $0.kind == kind && $0.deletedAt == nil }
            .sorted { $0.measuredAt > $1.measuredAt }
    }

    private func currentMeasurement(for kind: MeasurementKind, entries: [HealthCoachKit.Measurement]) -> HealthCoachKit.Measurement? {
        if kind == .weight {
            return entries.first(where: { $0.source == .healthKit }) ?? entries.first
        }
        return entries.first
    }

    private func title(for kind: MeasurementKind) -> String {
        switch kind {
        case .weight: return "Weight"
        case .waist: return "Waist"
        case .bodyFat: return "Body fat"
        }
    }

    private func sourceLabel(for kind: MeasurementKind) -> String {
        kind == .weight ? "HEALTHKIT FIRST" : "MANUAL CHECK-IN"
    }

    private func icon(for kind: MeasurementKind) -> String {
        switch kind {
        case .weight: return "scalemass.fill"
        case .waist: return "ruler.fill"
        case .bodyFat: return "figure.arms.open"
        }
    }

    private func tint(for kind: MeasurementKind) -> Color {
        switch kind {
        case .weight: return HealthCoachPalette.orange
        case .waist: return HealthCoachPalette.cyan
        case .bodyFat: return HealthCoachPalette.coral
        }
    }
}

struct ManualMeasurementSheet: View {
    @ObservedObject var model: iOSAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MeasurementKind = .waist
    @State private var value = ""
    @State private var measuredAt = Date()

    init(model: iOSAppModel, initialKind: MeasurementKind = .waist) {
        self.model = model
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Check-in") {
                    Picker("Type", selection: $kind) {
                        Text("Weight").tag(MeasurementKind.weight)
                        Text("Waist").tag(MeasurementKind.waist)
                        Text("Body fat").tag(MeasurementKind.bodyFat)
                    }
                    .pickerStyle(.segmented)
                    TextField(prompt, text: $value)
                        .keyboardType(.decimalPad)
                    DatePicker("Measured", selection: $measuredAt, in: ...Date(), displayedComponents: .date)
                }
                Section {
                    Text("Use this for an occasional check-in. Weight shown on Today prefers HealthKit and uses a manual value only when HealthKit has no weight.")
                        .font(.footnote)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                }
            }
            .navigationTitle("Add measurement")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(HealthCoachPalette.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(numericValue == nil)
                }
            }
        }
    }

    private var prompt: String {
        switch kind {
        case .weight: return "Weight in kg"
        case .waist: return "Waist in cm"
        case .bodyFat: return "Body fat %"
        }
    }

    private var numericValue: Double? {
        Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private func save() {
        guard let numericValue, numericValue >= 0 else { return }
        model.saveMeasurement(kind: kind, value: numericValue, measuredAt: measuredAt)
        dismiss()
    }
}
