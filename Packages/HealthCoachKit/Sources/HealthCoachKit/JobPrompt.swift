import Foundation

public enum HealthCoachJobPrompt {
    public static func make(for job: CoachJob) -> String {
        var promptRequest = job.request
        promptRequest.referenceImageData = nil
        let requestData = (try? HealthCoachJSON.encode(promptRequest)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let tools: String
        switch job.kind {
        case .analyzeMeal:
            tools = "Call get_meals for the requested meal and use its original text and corrections."
        case .generateProgram:
            tools = "Call get_profile, get_goals, get_equipment, get_current_program, get_workouts, get_meals, and get_health_metrics as needed within the bounded history."
        case .discoverEquipment:
            tools = "Do not call HealthCoach MCP tools for this job. Inspect the attached gym images when present. If allowsOnlineLookup is true and a facility name is present, use public web search to identify the facility and inspect public facility images."
        case .suggestProgression:
            tools = "Call get_current_program and get_workouts for the requested exercise/session history."
        case .answerQuestion:
            tools = "Use the bounded date range in the request and call only the read-only tools needed to answer from recorded context."
        }
        return [
            "You are the HealthCoach Codex worker. Produce only the JSON object required by the supplied output schema.",
            "This is an estimate/proposal, not a diagnosis or authoritative measurement. Do not invent missing data; put uncertainty and assumptions in the typed fields. Do not change records.",
            "Job kind: " + job.kind.rawValue,
            "Job id: " + job.id.uuidString,
            "Request generation: " + String(job.requestGeneration),
            "Input revision: " + String(job.inputRevision),
            "Request JSON: <untrusted-request>",
            requestData,
            "</untrusted-request>",
            "Reference images attached separately: " + String(job.request.referenceImageData?.count ?? 0),
            tools,
            "Keep the answer bounded to this job's read-only MCP snapshot. Every schema property is required: emit null for an inapplicable optional value and include all six root keys (kind, meal, program, equipment, progression, coaching). For meal analysis, copy sourceMealID exactly from the requested meal, sourceMealRevision exactly from Input revision, and sourceJobID exactly from Job id above; never reuse an ID from another record or example. Include per-item estimates, a low/central/high kcal range, and assumptions. For programs, include ordered days, positive targets, stable lower_snake_case exercise IDs that are unique within each day, equipment, progression text, and at least one cached alternative per exercise when an alternative is feasible; the same exercise may be reused on different days.",
            "For a first program, use the recorded primary goal, target timeframe, current and target body measurements, training experience, recent break history, schedule, preferences, and equipment. Build every exercise around get_equipment.available and never use get_equipment.excluded. If the available list is empty, use the recorded facilityType conservatively: homeNoEquipment means bodyweight only, while other facility types are assumptions that must be stated in coaching.answerText rather than treated as confirmed inventory. Do not invent missing profile or goal values.",
            "When a generateProgram request contains a programID and a non-empty question, treat it as a requested revision of that current program. Preserve details the user did not ask to change, apply feasible requests such as removing an exercise or using no equipment, return a complete replacement proposal with a new program id, and explain the exact additions, removals, and target/equipment/progression changes in coaching.answerText. Do not accept or reject the proposal automatically.",
            "For discoverEquipment, return detectedEquipment as conservative, user-facing equipment names. Only include items supported by an attached image or a public source; include confidenceByEquipment values from 0 to 1, sources, and limitations. Never infer or include health data. For coaching, cite local date ranges/record IDs and state limitations."
        ].joined(separator: "\n")
    }
}
