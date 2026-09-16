import SwiftUI
import HealthCoachKit

struct iOSRootView: View {
    @ObservedObject var model: iOSAppModel

    var body: some View {
        TabView {
            NavigationStack { TodayView(model: model) }
                .tabItem { Label("Today", systemImage: "heart.text.square") }
            NavigationStack { MealsView(model: model) }
                .tabItem { Label("Meals", systemImage: "fork.knife") }
            NavigationStack { TrainingView(model: model) }
                .tabItem { Label("Training", systemImage: "figure.strengthtraining.traditional") }
            NavigationStack { CoachView(model: model) }
                .tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right") }
            NavigationStack { SettingsView(model: model) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $model.showingPairingScanner) {
            PairingScannerSheet(model: model)
        }
        .alert("HealthCoach", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    var systemImage: String = "circle.fill"
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TodayView: View {
    @ObservedObject var model: iOSAppModel
    @State private var mealText = ""
    @State private var weightText = ""
    @State private var waistText = ""
    @State private var bodyFatText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today").font(.largeTitle.bold())
                    Text(model.today).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox("Quick capture") {
                    VStack(spacing: 12) {
                        TextField("Meal, for example: eggs and toast", text: $mealText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Meal description")
                        Button("Save meal") {
                            model.addMeal(text: mealText)
                            mealText = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(mealText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        HStack {
                            TextField("Weight kg", text: $weightText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                            Button("Save") { saveWeight() }.buttonStyle(.bordered)
                        }
                        HStack {
                            TextField("Waist cm", text: $waistText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                            Button("Save") { saveWaist() }.buttonStyle(.bordered)
                        }
                        HStack {
                            TextField("Body fat %", text: $bodyFatText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                            Button("Save") { saveBodyFat() }.buttonStyle(.bordered)
                        }
                    }
                }

                GroupBox("Nutrition") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(Int(model.todayNutrition.totals.kcal.rounded())) kcal from \(model.todayNutrition.mealCount) meals with current values")
                        MacroLine(label: "Protein", value: model.todayNutrition.totals.proteinGrams, unit: "g")
                        MacroLine(label: "Carbohydrates", value: model.todayNutrition.totals.carbohydratesGrams, unit: "g")
                        MacroLine(label: "Fat", value: model.todayNutrition.totals.fatGrams, unit: "g")
                        if model.todayNutrition.mealCount == 0 {
                            Text("No completed estimates yet. Captured text stays available offline.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("Weight trend") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.weightTrend.averageKg.map { String(format: "%.1f kg average", $0) } ?? "No weight samples")
                        Text("\(model.weightTrend.sampleDayCount) of 7 days sampled")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Recent measurements") {
                    if model.measurements.isEmpty {
                        Text("No weight, waist, or body-fat measurements yet.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.measurements.prefix(6)) { measurement in
                            StatusRow(
                                title: measurement.kind == .bodyFat ? "Body fat" : measurement.kind.rawValue.capitalized,
                                value: String(format: "%.1f %@ · %@", measurement.value, measurement.unit, measurement.localDate),
                                systemImage: measurement.kind == .waist ? "ruler" : measurement.kind == .bodyFat ? "figure.arms.open" : "scalemass"
                            )
                        }
                    }
                }

                GroupBox("Health and sync") {
                    VStack(spacing: 10) {
                        if let summary = model.healthSummaries.first(where: { $0.localDate == model.today }) {
                            StatusRow(title: "Steps", value: summary.steps.map { String(Int($0)) } ?? "Unavailable", systemImage: "figure.walk")
                            StatusRow(title: "Active energy", value: summary.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "Unavailable", systemImage: "flame")
                            StatusRow(title: "Sleep", value: summary.sleepHours.map { String(format: "%.1f h", $0) } ?? "Unavailable", systemImage: "bed.double")
                        } else {
                            Text("HealthKit summaries are unavailable or not imported.").font(.footnote).foregroundStyle(.secondary)
                        }
                        StatusRow(title: "Sync", value: model.syncStatus.title, systemImage: "arrow.triangle.2.circlepath")
                        StatusRow(title: "Pending coaching", value: "\(model.pendingJobCount)", systemImage: "clock")
                        Button("Sync now") { model.syncNow() }.buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("HealthCoach")
    }

    private func saveWeight() {
        guard let value = Double(weightText) else { return }
        model.saveMeasurement(kind: .weight, value: value)
        weightText = ""
    }

    private func saveWaist() {
        guard let value = Double(waistText) else { return }
        model.saveMeasurement(kind: .waist, value: value)
        waistText = ""
    }

    private func saveBodyFat() {
        guard let value = Double(bodyFatText) else { return }
        model.saveMeasurement(kind: .bodyFat, value: value)
        bodyFatText = ""
    }
}

struct MacroLine: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        HStack { Text(label); Spacer(); Text(String(format: "%.0f %@", value, unit)).foregroundStyle(.secondary) }
    }
}
