import Foundation
import HealthCoachKit
import MCP

private struct MCPRecordsResponse<Record: Encodable>: Encodable {
    let schemaVersion: Int
    let tool: String
    let units: [String: String]
    let missingData: [String]
    let staleData: [String]
    let records: Record
    let nextCursor: String?
}

private struct MCPWorkoutRecord: Encodable {
    let session: WorkoutSession
    let sets: [TrainingSet]
}

private struct MCPEquipmentRecord: Encodable {
    let available: [String]
    let excluded: [String]
    let facilityType: EquipmentFacilityType?
    let facilityName: String?
    let referencePhotoCount: Int
    let onlineLookupAllowed: Bool?
}

private struct MCPPage<Record> {
    let records: [Record]
    let nextCursor: String?
}

private final class MCPReadService: @unchecked Sendable {
    private let store: HealthCoachStore
    private let maxRows = 100
    private let maxOutputBytes = 128 * 1024

    init(store: HealthCoachStore) {
        self.store = store
    }

    func tools() -> [Tool] {
        [
            tool("get_profile", "Read the phone-owned profile and exercise preferences.", properties: [:]),
            tool("get_goals", "Read current and target weight, waist, and body-fat values.", properties: [:]),
            tool("get_measurements", "Read bounded manual and HealthKit measurements. Dates are local YYYY-MM-DD.", properties: dateProperties),
            tool("get_health_metrics", "Read bounded normalized HealthKit summaries with units and freshness.", properties: dateProperties),
            tool("get_meals", "Read bounded meal text revisions and cached Codex estimates.", properties: dateProperties),
            tool("get_workouts", "Read bounded strength sessions and their logged sets.", properties: dateProperties),
            tool("get_current_program", "Read the accepted current program and cached exercise alternatives.", properties: [:]),
            tool("get_equipment", "Read available and explicitly excluded equipment.", properties: [:]),
            tool("get_user_corrections", "Read explicit record corrections and reusable preferences.", properties: dateProperties)
        ]
    }

    func call(_ params: CallTool.Parameters) throws -> CallTool.Result {
        do {
            let text = try execute(name: params.name, arguments: params.arguments ?? [:])
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "HealthCoach read failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func execute(name: String, arguments: [String: Value]) throws -> String {
        switch name {
        case "get_profile":
            let value = try store.profile()
            return try encode(tool: name, units: [:], records: value, missing: value == nil ? ["profile"] : [])
        case "get_goals":
            let value = try store.goals()
            return try encode(tool: name, units: ["weight": "kg", "waist": "cm", "bodyFat": "percent"], records: value, missing: value == nil ? ["goals"] : [])
        case "get_measurements":
            let page = try bounded(try store.measurements(), arguments: arguments) { $0.localDate }
            return try encode(tool: name, units: ["weight": "kg", "waist": "cm", "bodyFat": "percent"], records: page.records, missing: page.records.isEmpty ? ["measurements"] : [], nextCursor: page.nextCursor)
        case "get_health_metrics":
            let page = try bounded(try store.healthSummaries(), arguments: arguments) { $0.localDate }
            return try encode(tool: name, units: ["steps": "count", "activeEnergyKcal": "kcal", "sleepHours": "hours", "restingHeartRateBpm": "bpm", "hrvSDNNMilliseconds": "ms"], records: page.records, missing: page.records.isEmpty ? ["health summaries"] : [], nextCursor: page.nextCursor)
        case "get_meals":
            let page = try bounded(try store.meals(), arguments: arguments) { $0.localDate }
            return try encode(tool: name, units: ["kcal": "kcal", "proteinGrams": "g", "carbohydratesGrams": "g", "fatGrams": "g"], records: page.records, missing: page.records.isEmpty ? ["meals"] : [], nextCursor: page.nextCursor)
        case "get_workouts":
            let page = try bounded(try store.workouts(), arguments: arguments) { $0.localDate }
            let sets = try store.trainingSets()
            let values = page.records.map { session in
                MCPWorkoutRecord(session: session, sets: sets.filter { $0.sessionID == session.id })
            }
            return try encode(tool: name, units: ["loadKg": "kg", "reps": "count"], records: values, missing: values.isEmpty ? ["workouts"] : [], nextCursor: page.nextCursor)
        case "get_current_program":
            let value = try store.currentProgram()
            return try encode(tool: name, units: ["sets": "count", "reps": "count", "targetRIR": "RIR"], records: value, missing: value == nil ? ["current program"] : [])
        case "get_equipment":
            let value = try store.equipment()
            let sanitized = value.map {
                MCPEquipmentRecord(
                    available: $0.available,
                    excluded: $0.excluded,
                    facilityType: $0.facilityType,
                    facilityName: $0.facilityName,
                    referencePhotoCount: $0.referencePhotos?.count ?? 0,
                    onlineLookupAllowed: $0.onlineLookupAllowed
                )
            }
            return try encode(tool: name, units: [:], records: sanitized, missing: sanitized == nil ? ["equipment"] : [])
        case "get_user_corrections":
            let page = try bounded(try store.corrections(), arguments: arguments) { correction in
                ISO8601DateFormatter().string(from: correction.createdAt).prefix(10).description
            }
            return try encode(tool: name, units: [:], records: page.records, missing: page.records.isEmpty ? ["corrections"] : [], nextCursor: page.nextCursor)
        default:
            throw HealthCoachError.invalidInput("Unknown read-only tool (name).")
        }
    }

    private func bounded<Record>(_ records: [Record], arguments: [String: Value], date: (Record) -> String) throws -> MCPPage<Record> {
        let from = arguments["from"]?.stringValue
        let to = arguments["to"]?.stringValue
        if let from, !isLocalDate(from) { throw HealthCoachError.invalidInput("from must be YYYY-MM-DD.") }
        if let to, !isLocalDate(to) { throw HealthCoachError.invalidInput("to must be YYYY-MM-DD.") }
        if let from, let to, from > to { throw HealthCoachError.invalidInput("from must not be after to.") }
        if let from, let to, dayDistance(from: from, to: to) > HealthCoachConstants.maximumHistoryDays {
            throw HealthCoachError.invalidInput("The requested history range is too wide.")
        }
        let limit = min(max(arguments["limit"]?.intValue ?? maxRows, 1), maxRows)
        let filtered = records.filter { value in
            let key = date(value)
            return (from == nil || key >= from!) && (to == nil || key <= to!)
        }
        let cursor = arguments["cursor"]?.stringValue.flatMap(Int.init) ?? 0
        guard cursor >= 0, cursor <= filtered.count else { throw HealthCoachError.invalidInput("The cursor is invalid.") }
        let page = Array(filtered.dropFirst(cursor).prefix(limit))
        let end = cursor + page.count
        return MCPPage(records: page, nextCursor: end < filtered.count ? String(end) : nil)
    }

    private func encode<Record: Encodable>(tool: String, units: [String: String], records: Record, missing: [String], stale: [String] = [], nextCursor: String? = nil) throws -> String {
        let response = MCPRecordsResponse(
            schemaVersion: HealthCoachConstants.schemaVersion,
            tool: tool,
            units: units,
            missingData: missing,
            staleData: stale,
            records: records,
            nextCursor: nextCursor
        )
        let data = try HealthCoachJSON.encode(response)
        guard data.count <= maxOutputBytes else { throw HealthCoachError.frameTooLarge(data.count) }
        return String(decoding: data, as: UTF8.self)
    }

    private var dateProperties: [String: Value] {
        [
            "from": ["type": "string", "description": "Inclusive local date YYYY-MM-DD"],
            "to": ["type": "string", "description": "Inclusive local date YYYY-MM-DD"],
            "limit": ["type": "integer", "minimum": 1, "maximum": 100],
            "cursor": ["type": "string", "description": "Stable row offset cursor returned by the client"]
        ]
    }

    private func tool(_ name: String, _ description: String, properties: [String: Value]) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: [
                "type": "object",
                "properties": .object(properties),
                "additionalProperties": false
            ],
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        )
    }

    private func isLocalDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return value.count == 10 && formatter.date(from: value) != nil
    }

    private func dayDistance(from: String, to: String) -> Int {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: from), let end = formatter.date(from: to) else { return Int.max }
        return abs(Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day ?? Int.max)
    }
}

@main
struct HealthCoachMCPMain {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--database"), arguments.indices.contains(index + 1) else {
            writeError("healthcoach-mcp requires --database PATH")
            return
        }
        let path = URL(fileURLWithPath: arguments[index + 1], isDirectory: false)
        guard FileManager.default.fileExists(atPath: path.path) else {
            writeError("healthcoach-mcp database path does not exist")
            return
        }
        let store = try HealthCoachStore(readOnlyPath: path)
        let service = MCPReadService(store: store)
        let server = Server(
            name: "HealthCoach",
            version: "1.0.0",
            instructions: "Read-only personal health context. Every tool is bounded and cannot mutate data.",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: service.tools())
        }
        await server.withMethodHandler(CallTool.self) { params in
            try service.call(params)
        }
        let transport = CompatibilityStdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
