import SwiftUI

enum CIState: String, Hashable, Sendable {
    case success, failure, running, queued, cancelled, skipped, neutral, none

    init(status: String?, conclusion: String?) {
        switch status {
        case "queued", "waiting", "pending", "requested": self = .queued
        case "in_progress": self = .running
        default:
            switch conclusion {
            case "success": self = .success
            case "failure", "timed_out", "startup_failure", "action_required": self = .failure
            case "cancelled": self = .cancelled
            case "skipped": self = .skipped
            case "neutral", "stale": self = .neutral
            default: self = status == nil ? .none : .neutral
            }
        }
    }

    /// GraphQL StatusState / CheckConclusionState / CheckStatusState values.
    init(rollup: String?) {
        switch rollup?.uppercased() {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED": self = .failure
        case "PENDING", "EXPECTED", "IN_PROGRESS": self = .running
        case "QUEUED", "WAITING", "REQUESTED": self = .queued
        case "CANCELLED": self = .cancelled
        case "SKIPPED": self = .skipped
        case "NEUTRAL", "STALE": self = .neutral
        default: self = .none
        }
    }

    var isActive: Bool { self == .running || self == .queued }

    var color: Color {
        switch self {
        case .success: .ghGreen
        case .failure: .ghRed
        case .running: .ghAmber
        case .queued: .ghAmber.opacity(0.7)
        case .cancelled, .skipped, .neutral: .secondary
        case .none: .secondary.opacity(0.5)
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .queued: "clock.fill"
        case .cancelled: "slash.circle.fill"
        case .skipped: "arrow.uturn.forward.circle.fill"
        case .neutral: "minus.circle.fill"
        case .none: "circle.dotted"
        }
    }

    var label: String {
        switch self {
        case .success: "Passing"
        case .failure: "Failing"
        case .running: "Running"
        case .queued: "Queued"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .neutral: "Neutral"
        case .none: "No checks"
        }
    }

    /// Worst-first combination of several states.
    static func combine(_ states: [CIState]) -> CIState {
        let order: [CIState] = [.failure, .running, .queued, .success, .cancelled, .neutral, .skipped]
        for s in order where states.contains(s) { return s }
        return .none
    }
}

extension Color {
    static let ghGreen = Color(red: 0.18, green: 0.70, blue: 0.32)
    static let ghRed = Color(red: 0.90, green: 0.27, blue: 0.27)
    static let ghAmber = Color(red: 0.90, green: 0.63, blue: 0.13)
    static let ghPurple = Color(red: 0.57, green: 0.37, blue: 0.90)
    static let ghBlue = Color(red: 0.25, green: 0.52, blue: 0.96)

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0x8b949e
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
