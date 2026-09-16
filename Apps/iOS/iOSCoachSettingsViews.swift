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
    @State private var currentWeight = ""
    @State private var targetWeight = ""
    @State private var targetBodyFat = ""
    @State private var targetWaist = ""
    @State private var availableEquipment = ""
    @State private var excludedEquipment = ""

    var body: some View {
        Form {
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
            Section("Targets") {
                TextField("Current weight kg", text: $currentWeight).keyboardType(.decimalPad)
                TextField("Target weight kg", text: $targetWeight).keyboardType(.decimalPad)
                TextField("Target body fat %", text: $targetBodyFat).keyboardType(.decimalPad)
                TextField("Target waist cm", text: $targetWaist).keyboardType(.decimalPad)
                Button("Save targets") { saveGoals() }
            }
            Section("Equipment") {
                TextField("Available, comma separated", text: $availableEquipment)
                TextField("Excluded, comma separated", text: $excludedEquipment)
                Button("Save equipment") { model.saveEquipment(available: split(availableEquipment), excluded: split(excludedEquipment)) }
            }
            Section("HealthKit") {
                Text("HealthCoach reads only the requested HealthKit metrics. Manual capture remains available if access is denied or there is no data.").font(.footnote).foregroundStyle(.secondary)
                Button("Import last 90 days") { Task { await model.importHealthKit() } }
                if let message = model.healthKitMessage { Text(message).font(.footnote) }
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
        .onAppear(perform: load)
    }

    private func load() {
        displayName = model.profile.displayName
        daysPerWeek = String(model.profile.daysPerWeek)
        duration = String(model.profile.sessionDurationMinutes)
        constraints = model.profile.scheduleConstraints
        preferences = model.profile.exercisePreferences.joined(separator: ", ")
        currentWeight = model.goals.currentWeightKg.map { String($0) } ?? ""
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
        model.saveGoals(currentWeight: Double(currentWeight), targetWeight: Double(targetWeight), bodyFat: Double(targetBodyFat), waist: Double(targetWaist))
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
