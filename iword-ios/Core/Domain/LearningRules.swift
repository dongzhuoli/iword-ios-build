import Foundation

/// The four ratings shown after a recall answer.
public enum RecallRating: String, Codable, CaseIterable {
    case forgot
    case hint
    case slow
    case easy
}

/// The durable scheduling fields needed by the rule engine.
public struct ScheduleState: Codable, Equatable {
    public var stability: Int
    public var dueAt: Date?
    public var lastContactAt: Date?

    public init(stability: Int = 0, dueAt: Date? = nil, lastContactAt: Date? = nil) {
        self.stability = stability
        self.dueAt = dueAt
        self.lastContactAt = lastContactAt
    }
}

/// The result of applying one learning rule transition.
public struct ScheduleResult: Equatable {
    public let state: ScheduleState
    public let delayedSuccess: Bool
    public let clockAnomaly: Bool

    public init(state: ScheduleState, delayedSuccess: Bool, clockAnomaly: Bool) {
        self.state = state
        self.delayedSuccess = delayedSuccess
        self.clockAnomaly = clockAnomaly
    }
}

/// Foundation-only implementation of mobile-rule-v1.
public enum LearningRules {
    private static let delayedThreshold: TimeInterval = 12 * 60 * 60
    private static let scheduleMinutes = [1_440, 4_320, 10_080, 20_160, 43_200]

    /// Marks a newly confirmed word as learned and schedules its first review.
    public static func afterLearning(now: Date) -> ScheduleState {
        ScheduleState(
            stability: 0,
            dueAt: now.addingTimeInterval(4 * 60 * 60),
            lastContactAt: now)
    }

    /// Applies a recall rating. `observedAt` is the locked observation time (the
    /// first reveal or hint), while `now` is the time at which the transition is
    /// committed. This keeps time spent staring at the rating screen out of the
    /// delayed-recall interval.
    public static func afterRecall(
        state: ScheduleState,
        rating: RecallRating,
        hinted: Bool,
        observedAt: Date,
        now: Date,
        voluntary: Bool,
        audioAssisted: Bool = false
    ) -> ScheduleResult {
        var next = state
        let interval: TimeInterval?
        if let previous = state.lastContactAt {
            interval = observedAt.timeIntervalSince(previous)
        } else {
            interval = nil
        }

        // A future client timestamp is treated like a non-positive interval. It
        // must not manufacture a delayed success or advance stability.
        let clockAnomaly = observedAt > now || (interval.map { $0 <= 0 } ?? false)
        let validInterval = interval.map { $0 > 0 && observedAt <= now } ?? false
        let delayed = validInterval && (interval ?? 0) >= delayedThreshold
        let effectiveRating: RecallRating =
            hinted && (rating == .slow || rating == .easy) ? .hint : rating

        // The server implementation records the current contact even when the
        // timestamp supplied by the device is unusable. This gives a safe new
        // baseline for the next interval without granting mastery.
        next.lastContactAt = now

        // Voluntary consolidation is intentionally not a scheduling mutation.
        // Its contact timestamp is still retained for a later actual interval.
        guard !voluntary, !clockAnomaly else {
            return ScheduleResult(
                state: next,
                delayedSuccess: false,
                clockAnomaly: clockAnomaly)
        }

        let unsuccessful = effectiveRating == .forgot || effectiveRating == .hint
        if unsuccessful {
            next.stability = 0
        } else if delayed && !audioAssisted {
            next.stability = min(4, next.stability + 1)
        }

        var delayMinutes: Int
        switch effectiveRating {
        case .forgot:
            delayMinutes = 10
        case .hint:
            delayMinutes = 240
        case .slow:
            delayMinutes = 1_440
        case .easy:
            // Stability is incremented before looking up the interval. Thus a
            // first delayed easy recall (stability 0 -> 1) gets three days.
            let index = min(max(next.stability, 0), scheduleMinutes.count - 1)
            delayMinutes = scheduleMinutes[index]
        }
        if audioAssisted && !hinted && (rating == .slow || rating == .easy) {
            // Assisted playback is practice, not delayed recall mastery.
            delayMinutes = 1_440
        }
        next.dueAt = now.addingTimeInterval(TimeInterval(delayMinutes * 60))

        return ScheduleResult(
            state: next,
            delayedSuccess: delayed && !unsuccessful && !audioAssisted,
            clockAnomaly: false)
    }

    /// Returns the remaining new-word budget for a session slot.
    public static func newWordLimit(
        slot: String,
        morningUsed: Int,
        afternoonUsed: Int,
        dailyUsed: Int,
        dailyLimit: Int = 10
    ) -> Int {
        guard (0...50).contains(dailyLimit) else { return 0 }
        guard slot == "morning" || slot == "afternoon" else { return 0 }
        let usedInSlot = slot == "morning" ? morningUsed : afternoonUsed
        let slotLimit = slot == "morning" ? (dailyLimit + 1) / 2 : dailyLimit / 2
        let slotRemaining = max(0, slotLimit - usedInSlot)
        let dailyRemaining = max(0, dailyLimit - dailyUsed)
        return min(slotRemaining, dailyRemaining)
    }
}
