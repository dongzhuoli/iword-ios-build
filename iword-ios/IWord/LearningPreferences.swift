import Foundation

/// User-controlled learning cadence. The optional profile field keeps older
/// profile payloads decodable; callers use `LocalProfile.preferences` to get
/// the defaults when the field is absent.
struct LearningPreferences: Codable, Equatable {
    var order: String = "recommended"
    var dailyNewWords: Int = 10
    var reminderEnabled: Bool = false
    var reminderHour: Int = 20
    var reminderMinute: Int = 30

    static let defaults = LearningPreferences()
    static let validOrders: Set<String> = ["recommended", "sequential"]

    var isValid: Bool {
        Self.validate(self)
    }

    static func validate(_ value: LearningPreferences) -> Bool {
        validOrders.contains(value.order)
            && (0...50).contains(value.dailyNewWords)
            && (0...23).contains(value.reminderHour)
            && (0...59).contains(value.reminderMinute)
    }

    /// Returns a safe preference value for settings imported from an older or
    /// hand-edited profile. This does not silently turn an invalid cadence
    /// into a usable credential or other external configuration.
    static func validated(_ value: LearningPreferences) -> LearningPreferences {
        guard validate(value) else { return defaults }
        return value
    }
}
