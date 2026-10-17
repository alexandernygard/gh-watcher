import SwiftUI

/// Kinds of things GH Watcher can detect and notify about.
enum EventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case workflowFailed, workflowFixed, workflowSucceeded, workflowStarted
    case prOpened, prMerged, prClosed, prReadyForReview
    case prReviewRequested, prReviewSubmitted, comment, mention, assigned
    case issueOpened, issueClosed, issueReopened
    case push, branchCreated, release, star, fork
    case inboxOther

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workflowFailed: "Workflow failed"
        case .workflowFixed: "Workflow fixed"
        case .workflowSucceeded: "Workflow succeeded"
        case .workflowStarted: "Workflow started"
        case .prOpened: "Pull request opened"
        case .prMerged: "Pull request merged"
        case .prClosed: "Pull request closed"
        case .prReadyForReview: "Pull request ready for review"
        case .prReviewRequested: "Review requested from you"
        case .prReviewSubmitted: "Review submitted"
        case .comment: "New comment"
        case .mention: "You were mentioned"
        case .assigned: "Assigned to you"
        case .issueOpened: "Issue opened"
        case .issueClosed: "Issue closed"
        case .issueReopened: "Issue reopened"
        case .push: "Commits pushed"
        case .branchCreated: "Branch or tag created"
        case .release: "Release published"
        case .star: "Repository starred"
        case .fork: "Repository forked"
        case .inboxOther: "Other GitHub notifications"
        }
    }

    var category: String {
        switch self {
        case .workflowFailed, .workflowFixed, .workflowSucceeded, .workflowStarted: "CI / Actions"
        case .prOpened, .prMerged, .prClosed, .prReadyForReview, .prReviewRequested, .prReviewSubmitted: "Pull Requests"
        case .comment, .mention, .assigned, .inboxOther: "Conversation"
        case .issueOpened, .issueClosed, .issueReopened: "Issues"
        case .push, .branchCreated, .release, .star, .fork: "Repository"
        }
    }

    var symbol: String {
        switch self {
        case .workflowFailed: "xmark.circle.fill"
        case .workflowFixed: "checkmark.seal.fill"
        case .workflowSucceeded: "checkmark.circle.fill"
        case .workflowStarted: "play.circle.fill"
        case .prOpened: "arrow.triangle.pull"
        case .prMerged: "arrow.triangle.merge"
        case .prClosed: "xmark.square"
        case .prReadyForReview: "eye"
        case .prReviewRequested: "eye.circle.fill"
        case .prReviewSubmitted: "text.bubble"
        case .comment: "bubble.left"
        case .mention: "at"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .issueOpened: "smallcircle.filled.circle"
        case .issueClosed: "checkmark.circle"
        case .issueReopened: "arrow.uturn.backward.circle"
        case .push: "arrow.up.circle"
        case .branchCreated: "arrow.triangle.branch"
        case .release: "shippingbox.fill"
        case .star: "star.fill"
        case .fork: "tuningfork"
        case .inboxOther: "bell"
        }
    }

    var color: Color {
        switch self {
        case .workflowFailed, .prClosed: .ghRed
        case .workflowFixed, .workflowSucceeded, .prOpened, .issueOpened, .issueReopened: .ghGreen
        case .prMerged, .issueClosed: .ghPurple
        case .workflowStarted, .star: .ghAmber
        case .prReviewRequested, .mention, .assigned, .prReadyForReview: .ghBlue
        default: .secondary
        }
    }

    /// Whether the "only things involving me" and "ignore my own actions" filters make sense.
    var supportsInvolvement: Bool { true }
    var supportsBranchFilter: Bool {
        switch self {
        case .workflowFailed, .workflowFixed, .workflowSucceeded, .workflowStarted, .push, .branchCreated, .prOpened, .prMerged, .prClosed: true
        default: false
        }
    }
}

struct WatchEvent: Identifiable, Hashable, Sendable {
    let id = UUID()
    let kind: EventKind
    let repo: String
    let title: String
    let subtitle: String
    let url: URL?
    let actor: String?
    let actorAvatar: URL?
    let branch: String?
    /// The current user authored / owns / was targeted by the underlying object.
    let involvesMe: Bool
    let date: Date
    var notified = false

    init(kind: EventKind, repo: String, title: String, subtitle: String, url: URL?, actor: String? = nil,
         actorAvatar: URL? = nil, branch: String? = nil, involvesMe: Bool = false, date: Date = .now) {
        self.kind = kind
        self.repo = repo
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.actor = actor
        self.actorAvatar = actorAvatar
        self.branch = branch
        self.involvesMe = involvesMe
        self.date = date
    }
}

struct NotificationRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var enabled = true
    var kind: EventKind
    /// Empty means every watched repository.
    var repos: [String] = []
    /// Comma separated glob patterns (e.g. `main, release/*`). Empty matches any branch.
    var branchPattern = ""
    var onlyInvolvingMe = false
    var ignoreMyOwn = false
    var playSound = true

    func matches(_ event: WatchEvent, me: String?) -> Bool {
        guard enabled, event.kind == kind else { return false }
        if !repos.isEmpty && !repos.contains(event.repo) { return false }
        if onlyInvolvingMe && !event.involvesMe { return false }
        if ignoreMyOwn, let me, event.actor?.caseInsensitiveCompare(me) == .orderedSame { return false }
        let patterns = branchPattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !patterns.isEmpty {
            guard let branch = event.branch else { return false }
            if !patterns.contains(where: { NSPredicate(format: "SELF LIKE %@", $0).evaluate(with: branch) }) { return false }
        }
        return true
    }

    var summary: String {
        var parts: [String] = []
        parts.append(repos.isEmpty ? "All repos" : repos.count == 1 ? repos[0] : "\(repos.count) repos")
        if !branchPattern.isEmpty { parts.append("branch \(branchPattern)") }
        if onlyInvolvingMe { parts.append("involving me") }
        if ignoreMyOwn { parts.append("not my own") }
        if !playSound { parts.append("silent") }
        return parts.joined(separator: " · ")
    }

    static let defaults: [NotificationRule] = [
        NotificationRule(kind: .workflowFailed),
        NotificationRule(kind: .workflowFixed),
        NotificationRule(enabled: false, kind: .workflowSucceeded, onlyInvolvingMe: true),
        NotificationRule(kind: .prOpened, ignoreMyOwn: true),
        NotificationRule(kind: .prMerged),
        NotificationRule(kind: .prReviewRequested),
        NotificationRule(kind: .prReviewSubmitted, onlyInvolvingMe: true, ignoreMyOwn: true),
        NotificationRule(kind: .comment, onlyInvolvingMe: true, ignoreMyOwn: true),
        NotificationRule(kind: .mention),
        NotificationRule(kind: .assigned),
        NotificationRule(kind: .issueOpened, ignoreMyOwn: true),
        NotificationRule(kind: .release),
        NotificationRule(enabled: false, kind: .star, playSound: false),
    ]
}
