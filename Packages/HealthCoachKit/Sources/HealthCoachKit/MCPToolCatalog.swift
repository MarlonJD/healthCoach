import Foundation

/// The only tools HealthCoach makes available to an automatic Codex turn.
/// Keeping this list in the shared package lets the host, helper, and tests
/// compare the effective catalog without duplicating tool names in prompts.
public enum HealthCoachMCPToolCatalog {
    public static let names: [String] = [
        "get_profile",
        "get_goals",
        "get_measurements",
        "get_health_metrics",
        "get_meals",
        "get_workouts",
        "get_current_program",
        "get_equipment",
        "get_user_corrections"
    ]

    public static let nameSet = Set(names)
}
