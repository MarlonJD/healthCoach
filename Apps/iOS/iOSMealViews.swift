import SwiftUI
import HealthCoachKit

struct MealsView: View {
    @ObservedObject var model: iOSAppModel
    @State private var mealText = ""

    var body: some View {
        List {
            Section("Capture") {
                TextField("What did you eat?", text: $mealText, axis: .vertical)
                    .lineLimit(2...5)
                Button("Save meal") {
                    model.addMeal(text: mealText)
                    mealText = ""
                }
                .disabled(mealText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("History") {
                if model.meals.isEmpty {
                    ContentUnavailableView("No meals yet", systemImage: "fork.knife", description: Text("Captured meals remain on this iPhone until the Mac is available."))
                } else {
                    ForEach(model.meals) { meal in
                        NavigationLink {
                            MealDetailView(meal: meal, model: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meal.originalText).lineLimit(2)
                                HStack {
                                    Text(meal.localDate)
                                    Spacer()
                                    Text(mealStatus(meal))
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.deleteMeal(meal) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Meals")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
    }

    private func mealStatus(_ meal: Meal) -> String {
        if meal.corrected { return "User corrected" }
        switch meal.analysisStatus {
        case .none: return "Not analyzed"
        case .queued: return "Pending"
        case .running: return "Running"
        case .succeeded: return meal.analysis == nil ? "No estimate" : "Estimated"
        case .failed: return "Error"
        case .cancelled: return "Cancelled"
        }
    }
}

struct MealDetailView: View {
    let meal: Meal
    @ObservedObject var model: iOSAppModel
    @State private var text: String
    @State private var correctionKcal = ""
    @State private var correctionProtein = ""
    @State private var correctionCarbohydrates = ""
    @State private var correctionFat = ""
    @State private var showingCorrection = false

    init(meal: Meal, model: iOSAppModel) {
        self.meal = meal
        self.model = model
        _text = State(initialValue: meal.originalText)
    }

    var body: some View {
        Form {
            Section("Meal text") {
                TextEditor(text: $text).frame(minHeight: 100)
                Button("Save text and analyze") {
                    model.updateMeal(meal, text: text)
                }
            }
            Section("Status") {
                LabeledContent("Captured", value: meal.localDate)
                LabeledContent("Revision", value: "\(meal.revision)")
                LabeledContent("Analysis", value: status)
                if meal.analysisStatus == .queued || meal.analysisStatus == .running {
                    Text("The paired Mac will process this when it can reach Codex. The iPhone checks for the result while the app is open.").font(.footnote).foregroundStyle(.secondary)
                }
                if let job = model.analysisJob(for: meal), let error = job.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("Request analysis again") { model.reanalyze(meal) }
            }
            if let analysis = meal.analysis {
                Section("Estimate") {
                    MacroLine(label: "Energy", value: analysis.totals.kcal, unit: "kcal")
                    MacroLine(label: "Protein", value: analysis.totals.proteinGrams, unit: "g")
                    MacroLine(label: "Carbohydrates", value: analysis.totals.carbohydratesGrams, unit: "g")
                    MacroLine(label: "Fat", value: analysis.totals.fatGrams, unit: "g")
                    Text("Range: \(Int(analysis.kcalRange.lowKcal))–\(Int(analysis.kcalRange.highKcal)) kcal")
                    ForEach(analysis.assumptions, id: \.self) { Text("• \($0)").font(.footnote) }
                    Button("Correct nutrition") {
                        correctionKcal = String(Int(analysis.totals.kcal.rounded()))
                        correctionProtein = String(Int(analysis.totals.proteinGrams.rounded()))
                        correctionCarbohydrates = String(Int(analysis.totals.carbohydratesGrams.rounded()))
                        correctionFat = String(Int(analysis.totals.fatGrams.rounded()))
                        showingCorrection = true
                    }
                }
            }
        }
        .navigationTitle("Meal")
        .scrollContentBackground(.hidden)
        .background(HealthCoachPalette.canvas)
        .tint(HealthCoachPalette.indigo)
        .sheet(isPresented: $showingCorrection) {
            NavigationStack {
                Form {
                    TextField("Correct kcal", text: $correctionKcal).keyboardType(.decimalPad)
                    TextField("Protein g", text: $correctionProtein).keyboardType(.decimalPad)
                    TextField("Carbohydrates g", text: $correctionCarbohydrates).keyboardType(.decimalPad)
                    TextField("Fat g", text: $correctionFat).keyboardType(.decimalPad)
                    Text("These explicit totals become the current user correction and are excluded from automatic estimates.").font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Correct estimate")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let kcal = Double(correctionKcal) {
                                model.correctMealNutrition(
                                    meal,
                                    kcal: kcal,
                                    protein: Double(correctionProtein),
                                    carbohydrates: Double(correctionCarbohydrates),
                                    fat: Double(correctionFat)
                                )
                            }
                            showingCorrection = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingCorrection = false } }
                }
            }
        }
    }

    private var status: String {
        if meal.corrected { return "User corrected" }
        return meal.analysisStatus.rawValue.capitalized
    }
}
