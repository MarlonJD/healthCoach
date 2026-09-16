import Foundation

public enum HealthCoachJobPrompt {
    public static func make(for job: CoachJob) -> String {
        let requestData = (try? HealthCoachJSON.encode(job.request)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let tools: String
        switch job.kind {
        case .analyzeMeal:
            tools = "Call get_meals for the requested meal and use its original text and corrections."
        case .generateProgram:
            tools = "Call get_profile, get_goals, get_equipment, get_current_program, get_workouts, get_meals, and get_health_metrics as needed within the bounded history."
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
            tools,
            "Keep the answer bounded to this job's read-only MCP snapshot. For meal analysis, include per-item estimates, a low/central/high kcal range, and assumptions. For programs, include ordered days, positive targets, stable lower_snake_case exercise IDs, equipment, progression text, and at least one cached alternative per exercise when an alternative is feasible. For coaching, cite local date ranges/record IDs and state limitations."
        ].joined(separator: "\n")
    }
}
