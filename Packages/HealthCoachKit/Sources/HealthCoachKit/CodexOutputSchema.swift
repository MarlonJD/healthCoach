import Foundation

public enum HealthCoachOutputSchema {
    public static func jobOutput() throws -> Data {
        let macroTotals: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["kcal", "proteinGrams", "carbohydratesGrams", "fatGrams"],
            "properties": [
                "kcal": ["type": "number", "minimum": 0],
                "proteinGrams": ["type": "number", "minimum": 0],
                "carbohydratesGrams": ["type": "number", "minimum": 0],
                "fatGrams": ["type": "number", "minimum": 0]
            ]
        ]
        let mealComponent: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["id", "name", "estimatedQuantity", "totals"],
            "properties": ["id": ["type": "string", "format": "uuid"], "name": ["type": "string"], "estimatedQuantity": ["type": "string"], "totals": macroTotals]
        ]
        let meal: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["sourceMealID", "sourceMealRevision", "components", "totals", "kcalRange", "assumptions", "sourceJobID", "sourceModel", "generatedAt"],
            "properties": [
                "sourceMealID": ["type": "string", "format": "uuid"], "sourceMealRevision": ["type": "integer", "minimum": 1],
                "components": ["type": "array", "items": mealComponent], "totals": macroTotals,
                "kcalRange": ["type": "object", "additionalProperties": false, "required": ["lowKcal", "centralKcal", "highKcal"], "properties": ["lowKcal": ["type": "number", "minimum": 0], "centralKcal": ["type": "number", "minimum": 0], "highKcal": ["type": "number", "minimum": 0]]],
                "assumptions": ["type": "array", "items": ["type": "string"]], "sourceJobID": ["type": "string", "format": "uuid"], "sourceModel": ["type": "string"], "generatedAt": ["type": "string", "format": "date-time"]
            ]
        ]
        let alternative: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["exerciseID", "displayName", "equipment", "reason"],
            "properties": ["exerciseID": ["type": "string"], "displayName": ["type": "string"], "equipment": ["type": "array", "items": ["type": "string"]], "reason": ["type": "string"]]
        ]
        let programExercise: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["exerciseID", "displayName", "order", "sets", "minimumReps", "maximumReps", "targetRIR", "targetRPE", "progressionText", "equipment", "alternatives"],
            "properties": ["exerciseID": ["type": "string"], "displayName": ["type": "string"], "order": ["type": "integer", "minimum": 0], "sets": ["type": "integer", "minimum": 1], "minimumReps": ["type": "integer", "minimum": 1], "maximumReps": ["type": "integer", "minimum": 1], "targetRIR": ["type": ["number", "null"]], "targetRPE": ["type": ["number", "null"]], "progressionText": ["type": "string"], "equipment": ["type": "array", "items": ["type": "string"]], "alternatives": ["type": "array", "items": alternative]]
        ]
        let day: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["id", "name", "order", "exercises"],
            "properties": ["id": ["type": "string", "format": "uuid"], "name": ["type": "string"], "order": ["type": "integer", "minimum": 0], "exercises": ["type": "array", "items": programExercise]]
        ]
        let program: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["id", "revision", "name", "goalSummary", "days", "equipment", "status", "sourceJobID", "sourceModel", "generatedAt", "acceptedAt", "inputRevision", "updatedAt"],
            "properties": ["id": ["type": "string", "format": "uuid"], "revision": ["type": "integer", "minimum": 1], "name": ["type": "string"], "goalSummary": ["type": "string"], "days": ["type": "array", "items": day], "equipment": ["type": "array", "items": ["type": "string"]], "status": ["type": "string", "enum": ["proposed", "current", "archived"]], "sourceJobID": ["type": ["string", "null"]], "sourceModel": ["type": ["string", "null"]], "generatedAt": ["type": "string", "format": "date-time"], "acceptedAt": ["type": ["string", "null"]], "inputRevision": ["type": "integer", "minimum": 1], "updatedAt": ["type": "string", "format": "date-time"]]
        ]
        let equipmentDiscovery: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["facilityType", "facilityName", "detectedEquipment", "confidenceByEquipment", "rationale", "sources", "limitations"],
            "properties": [
                "facilityType": ["type": ["string", "null"], "enum": ["standardGym", "smallGym", "mediumGym", "homeNoEquipment", "homeLimitedEquipment", NSNull()]],
                "facilityName": ["type": ["string", "null"]],
                "detectedEquipment": ["type": "array", "items": ["type": "string"]],
                "confidenceByEquipment": ["type": "object", "additionalProperties": ["type": "number", "minimum": 0, "maximum": 1]],
                "rationale": ["type": "string"],
                "sources": ["type": "array", "items": ["type": "string"]],
                "limitations": ["type": "array", "items": ["type": "string"]]
            ]
        ]
        let progression: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["exerciseID", "sourceSessionID", "sourceSessionRevision", "suggestedLoadKg", "suggestedMinimumReps", "suggestedMaximumReps", "rationale", "assumptions"],
            "properties": ["exerciseID": ["type": "string"], "sourceSessionID": ["type": "string", "format": "uuid"], "sourceSessionRevision": ["type": "integer", "minimum": 1], "suggestedLoadKg": ["type": ["number", "null"], "minimum": 0], "suggestedMinimumReps": ["type": ["integer", "null"], "minimum": 1], "suggestedMaximumReps": ["type": ["integer", "null"], "minimum": 1], "rationale": ["type": "string"], "assumptions": ["type": "array", "items": ["type": "string"]]]
        ]
        let suggestion: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["title", "detail"], "properties": ["title": ["type": "string"], "detail": ["type": "string"]]]
        let coaching: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["answerText", "referencedLocalDateRanges", "referencedRecordIDs", "uncertaintyAndLimitations", "suggestions"],
            "properties": ["answerText": ["type": "string"], "referencedLocalDateRanges": ["type": "array", "items": ["type": "string"]], "referencedRecordIDs": ["type": "array", "items": ["type": "string"]], "uncertaintyAndLimitations": ["type": "array", "items": ["type": "string"]], "suggestions": ["type": "array", "items": suggestion]]
        ]
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "meal", "program", "equipment", "progression", "coaching"],
            "properties": [
                "kind": ["type": "string", "enum": JobKind.allCases.map(\.rawValue)],
                "meal": meal, "program": program, "equipment": equipmentDiscovery, "progression": progression, "coaching": coaching
            ]
        ]
        return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }
}
