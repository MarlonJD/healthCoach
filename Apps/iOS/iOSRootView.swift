import SwiftUI
import UIKit
import HealthCoachKit

enum HealthCoachPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedSurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let secondaryInk = Color(uiColor: .secondaryLabel)
    static let line = Color(uiColor: .separator).opacity(0.35)
    static let indigo = Color(red: 0.30, green: 0.32, blue: 0.88)
    static let cyan = Color(red: 0.08, green: 0.63, blue: 0.72)
    static let mint = Color(red: 0.16, green: 0.64, blue: 0.48)
    static let orange = Color(red: 0.92, green: 0.47, blue: 0.18)
    static let coral = Color(red: 0.88, green: 0.30, blue: 0.34)
    static let deepIndigo = Color(red: 0.16, green: 0.18, blue: 0.55)
}

struct iOSRootView: View {
    @ObservedObject var model: iOSAppModel

    var body: some View {
        TabView {
            NavigationStack { TodayView(model: model) }
                .tabItem { Label("Today", systemImage: "heart.text.square.fill") }
            NavigationStack { MealsView(model: model) }
                .tabItem { Label("Meals", systemImage: "fork.knife") }
            NavigationStack { TrainingView(model: model) }
                .tabItem { Label("Training", systemImage: "figure.strengthtraining.traditional") }
            NavigationStack { CoachView(model: model) }
                .tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right.fill") }
            NavigationStack { SettingsView(model: model) }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(HealthCoachPalette.indigo)
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

struct HealthCoachCard<Content: View>: View {
    let title: String
    let eyebrow: String?
    let systemImage: String?
    let tint: Color
    private let content: Content

    init(
        _ title: String,
        eyebrow: String? = nil,
        systemImage: String? = nil,
        tint: Color = HealthCoachPalette.indigo,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.eyebrow = eyebrow
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(.caption.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(HealthCoachPalette.ink)
                }
                Spacer(minLength: 8)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.12), in: Circle())
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)

        return styledCard(card)
    }

    @ViewBuilder
    private func styledCard<StyledContent: View>(_ content: StyledContent) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 26))
                .shadow(color: .black.opacity(0.035), radius: 14, y: 7)
        } else {
            content
                .background(HealthCoachPalette.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(HealthCoachPalette.line, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.045), radius: 18, y: 8)
        }
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    var systemImage: String = "circle.fill"
    var tint: Color = HealthCoachPalette.indigo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(HealthCoachPalette.ink)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(HealthCoachPalette.secondaryInk)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TodayView: View {
    @ObservedObject var model: iOSAppModel
    @State private var mealText = ""

    var body: some View {
        ScrollView {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 16) {
                    dashboardContent
                }
            } else {
                dashboardContent
            }
        }
        .scrollIndicators(.hidden)
        .background(HealthCoachPalette.canvas.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var dashboardContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            header
            dailyPulseCard
            quickCaptureCard
            bodySnapshotCard
            nutritionCard
            healthCard
            trainingCard
            connectionsCard
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 32)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HealthCoachPalette.indigo)
                Text("Today")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(HealthCoachPalette.ink)
                Text(displayDate)
                    .font(.subheadline)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
            }
            Spacer()
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 42))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(HealthCoachPalette.indigo)
                .accessibilityLabel("HealthCoach")
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var dailyPulseCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.16), in: Circle())
                Text("YOUR DAY AT A GLANCE")
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(pulseTitle)
                    .font(.title2.weight(.bold))
                Text(pulseSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                PulseMetric(value: "\(model.todayNutrition.mealCount)", label: "meals")
                PulseMetric(value: "\(model.todayWorkoutSetCount)", label: "sets")
                PulseMetric(value: syncLabel, label: "sync")
            }

            HStack(spacing: 10) {
                if model.activeSession != nil {
                    NavigationLink("Continue workout") {
                        TrainingView(model: model)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                } else if model.displayedTrainingProgram != nil {
                    Button("Start workout") { model.startWorkout() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                } else {
                    NavigationLink("Open training") {
                        TrainingView(model: model)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                }

                NavigationLink {
                    CoachView(model: model)
                } label: {
                    Label("Ask Coach", systemImage: "bubble.left")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [HealthCoachPalette.deepIndigo, HealthCoachPalette.indigo, HealthCoachPalette.cyan.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: HealthCoachPalette.indigo.opacity(0.24), radius: 18, y: 9)
    }

    private var quickCaptureCard: some View {
        HealthCoachCard("Quick add", eyebrow: "CAPTURE NOW", systemImage: "plus.circle.fill", tint: HealthCoachPalette.indigo) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Describe a meal…", text: $mealText, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(HealthCoachPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(HealthCoachPalette.line, lineWidth: 1)
                        }
                        .accessibilityLabel("Meal description")
                    Button {
                        model.addMeal(text: mealText)
                        mealText = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .foregroundStyle(HealthCoachPalette.indigo)
                    .disabled(mealText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Save meal")
                }
                HStack(spacing: 12) {
                    Text("Saved offline on this iPhone")
                        .font(.footnote)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                    Spacer()
                    NavigationLink {
                        MealsView(model: model)
                    } label: {
                        Label("Meal history", systemImage: "arrow.right")
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
        }
    }

    private var bodySnapshotCard: some View {
        HealthCoachCard("Body snapshot", eyebrow: "AUTOMATIC WHERE POSSIBLE", systemImage: "figure.stand", tint: HealthCoachPalette.orange) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current weight")
                        .font(.subheadline)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                    if let measurement = model.currentWeightMeasurement {
                        HStack(alignment: .lastTextBaseline, spacing: 5) {
                            Text(String(format: "%.1f", measurement.value))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(measurement.unit)
                                .font(.headline.weight(.medium))
                                .foregroundStyle(HealthCoachPalette.secondaryInk)
                        }
                        Text(weightSourceText(measurement))
                            .font(.caption)
                            .foregroundStyle(measurement.source == .healthKit ? HealthCoachPalette.mint : HealthCoachPalette.orange)
                    } else {
                        Text("No weight yet")
                            .font(.title3.weight(.bold))
                        Text("Import HealthKit data in Settings.")
                            .font(.caption)
                            .foregroundStyle(HealthCoachPalette.secondaryInk)
                    }
                }
                Spacer(minLength: 10)
                if let target = model.goals.targetWeightKg {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Target")
                            .font(.caption)
                            .foregroundStyle(HealthCoachPalette.secondaryInk)
                        Text(String(format: "%.1f kg", target))
                            .font(.headline.weight(.bold))
                        if let current = model.currentWeightMeasurement {
                            Text(targetDeltaText(current: current.value, target: target))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HealthCoachPalette.mint)
                        }
                    }
                }
            }
            Divider()
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("7-day average")
                        .font(.caption)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                    Text(model.weightTrend.averageKg.map { String(format: "%.1f kg", $0) } ?? "No samples")
                        .font(.headline.weight(.bold))
                }
                Spacer()
                NavigationLink {
                    BodyMeasurementsView(model: model)
                } label: {
                    Label("Body measurements", systemImage: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    private var nutritionCard: some View {
        HealthCoachCard("Nutrition", eyebrow: "TODAY", systemImage: "fork.knife.circle.fill", tint: HealthCoachPalette.coral) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int(model.todayNutrition.totals.kcal.rounded()))")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("kcal")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
                Spacer()
                Text("\(model.todayNutrition.mealCount) logged")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
            }
            HStack(spacing: 8) {
                MacroPill(label: "Protein", value: model.todayNutrition.totals.proteinGrams, tint: HealthCoachPalette.indigo)
                MacroPill(label: "Carbs", value: model.todayNutrition.totals.carbohydratesGrams, tint: HealthCoachPalette.cyan)
                MacroPill(label: "Fat", value: model.todayNutrition.totals.fatGrams, tint: HealthCoachPalette.orange)
            }
            if model.todayNutrition.mealCount == 0 {
                Text("Add your first meal above. Codex will estimate kcal and macros when the Mac is available.")
                    .font(.footnote)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
            }
        }
    }

    private var healthCard: some View {
        HealthCoachCard("Health signals", eyebrow: "HEALTHKIT", systemImage: "waveform.path.ecg", tint: HealthCoachPalette.mint) {
            if let summary = model.todayHealthSummary {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    HealthCoachMetricTile(label: "Steps", value: summary.steps.map { String(Int($0.rounded())) } ?? "—", unit: "steps", systemImage: "figure.walk", tint: HealthCoachPalette.mint)
                    HealthCoachMetricTile(label: "Active energy", value: summary.activeEnergyKcal.map { String(Int($0.rounded())) } ?? "—", unit: "kcal", systemImage: "flame.fill", tint: HealthCoachPalette.orange)
                    HealthCoachMetricTile(label: "Sleep", value: summary.sleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "hours", systemImage: "bed.double.fill", tint: HealthCoachPalette.indigo)
                    HealthCoachMetricTile(label: "Resting HR", value: summary.restingHeartRateBpm.map { String(Int($0.rounded())) } ?? "—", unit: "bpm", systemImage: "heart.fill", tint: HealthCoachPalette.coral)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No HealthKit summary for today yet.")
                        .font(.subheadline.weight(.semibold))
                    Text("HealthCoach shows unavailable data honestly; it never turns a missing sample into zero.")
                        .font(.footnote)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                }
            }
            HStack(spacing: 12) {
                Button {
                    Task { await model.importHealthKit() }
                } label: {
                    Label("Refresh HealthKit", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                if let message = model.healthKitMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                        .lineLimit(2)
                }
            }
        }
    }

    private var trainingCard: some View {
        HealthCoachCard("Training", eyebrow: "UP NEXT", systemImage: "figure.strengthtraining.traditional", tint: HealthCoachPalette.orange) {
            if let program = model.displayedTrainingProgram {
                HStack(spacing: 12) {
                    Image(systemName: model.activeSession == nil ? "play.circle.fill" : "bolt.circle.fill")
                        .font(.title2)
                        .foregroundStyle(HealthCoachPalette.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(program.name)
                            .font(.headline.weight(.bold))
                            .lineLimit(2)
                        Text(model.activeSession.map { "\($0.setCount) sets logged · session in progress" } ?? "Ready when you are")
                            .font(.footnote)
                            .foregroundStyle(HealthCoachPalette.secondaryInk)
                    }
                }
                HStack(spacing: 10) {
                    if model.activeSession == nil {
                        Button("Start session") { model.startWorkout() }
                            .buttonStyle(.borderedProminent)
                            .tint(HealthCoachPalette.orange)
                    } else {
                        NavigationLink("Continue session") {
                            TrainingView(model: model)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(HealthCoachPalette.orange)
                    }
                    NavigationLink("Open plan") {
                        TrainingView(model: model)
                    }
                    .font(.footnote.weight(.semibold))
                }
            } else {
                Text("No accepted program yet. Request a complete plan from Training.")
                    .font(.subheadline)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
                NavigationLink("Open Training") {
                    TrainingView(model: model)
                }
                .buttonStyle(.borderedProminent)
                .tint(HealthCoachPalette.orange)
            }
        }
    }

    private var connectionsCard: some View {
        HealthCoachCard("Connections", eyebrow: "LOCAL STATUS", systemImage: "arrow.triangle.2.circlepath", tint: HealthCoachPalette.cyan) {
            HStack(spacing: 12) {
                Circle()
                    .fill(syncTint)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.syncStatus.title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.pendingJobCount == 0 ? "No coaching jobs waiting" : "\(model.pendingJobCount) coaching job\(model.pendingJobCount == 1 ? "" : "s") waiting")
                        .font(.caption)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                }
                Spacer()
                Button("Sync now") { model.syncNow() }
                    .buttonStyle(.bordered)
                    .tint(HealthCoachPalette.cyan)
            }
        }
    }

    private var pulseTitle: String {
        if model.activeSession != nil { return "Workout in progress" }
        if model.todayNutrition.mealCount == 0 { return "Make your first check-in" }
        if model.displayedTrainingProgram != nil { return "Your plan is ready" }
        return "Keep your momentum"
    }

    private var pulseSubtitle: String {
        if let session = model.activeSession {
            return "\(session.setCount) sets logged. Continue from the saved session whenever you are ready."
        }
        if model.todayNutrition.mealCount == 0 {
            return "Log a meal in seconds. It stays on this iPhone until the paired Mac can analyze it."
        }
        if model.displayedTrainingProgram != nil {
            return "Your accepted training plan is cached and ready for the next session."
        }
        return "HealthCoach keeps your day organized while your local data stays under your control."
    }

    private var syncLabel: String {
        switch model.syncStatus {
        case .synced: return "OK"
        case .syncing, .pairing: return "…"
        case .failed: return "!"
        case .unpaired, .disconnected: return "—"
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeGreeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = model.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? timeGreeting : "\(timeGreeting), \(name)"
    }

    private var displayDate: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private var syncTint: Color {
        switch model.syncStatus {
        case .synced: return HealthCoachPalette.mint
        case .syncing, .pairing: return HealthCoachPalette.orange
        case .failed: return HealthCoachPalette.coral
        case .unpaired, .disconnected: return HealthCoachPalette.secondaryInk
        }
    }

    private func weightSourceText(_ measurement: HealthCoachKit.Measurement) -> String {
        let date = measurement.measuredAt.formatted(date: .abbreviated, time: .omitted)
        return measurement.source == .healthKit ? "HealthKit · \(date)" : "Manual fallback · \(date)"
    }

    private func targetDeltaText(current: Double, target: Double) -> String {
        let difference = abs(target - current)
        if difference < 0.05 { return "On target" }
        let direction = current > target ? "to lose" : "to gain"
        return String(format: "%.1f kg %@", difference, direction)
    }
}

private struct PulseMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.70))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct HealthCoachMetricTile: View {
    let label: String
    let value: String
    let unit: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(HealthCoachPalette.secondaryInk)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(HealthCoachPalette.secondaryInk)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct MacroPill: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(HealthCoachPalette.secondaryInk)
            Text(String(format: "%.0f g", value))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct MacroLine: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(HealthCoachPalette.indigo.opacity(0.75))
                .frame(width: 7, height: 7)
            Text(label)
            Spacer()
            Text(String(format: "%.0f %@", value, unit))
                .foregroundStyle(HealthCoachPalette.secondaryInk)
                .monospacedDigit()
        }
    }
}
