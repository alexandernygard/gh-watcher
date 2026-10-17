import Foundation

// MARK: - Generic JSON (for loosely-typed event payloads)

enum JSON: Decodable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSON])
    case array([JSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var url: URL? { string.flatMap(URL.init(string:)) }
}

// MARK: - REST models

struct GHUser: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let login: String
    let avatarUrl: URL?
    let htmlUrl: URL?
    let name: String?
}

struct Repo: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let owner: GHUser
    let isPrivate: Bool
    let description: String?
    let htmlUrl: URL
    let defaultBranch: String?
    let language: String?
    let stargazersCount: Int?
    let forksCount: Int?
    let openIssuesCount: Int?
    let watchersCount: Int?
    let subscribersCount: Int?
    let pushedAt: Date?
    let updatedAt: Date?
    let archived: Bool?
    let fork: Bool?
    let topics: [String]?
    let homepage: String?

    enum CodingKeys: String, CodingKey {
        case id, name, fullName, owner, isPrivate = "private", description, htmlUrl, defaultBranch, language
        case stargazersCount, forksCount, openIssuesCount, watchersCount, subscribersCount
        case pushedAt, updatedAt, archived, fork, topics, homepage
    }
}

struct GHLabel: Decodable, Hashable, Sendable {
    let name: String
    let color: String?
    let description: String?
}

struct Milestone: Decodable, Hashable, Sendable {
    let title: String
    let number: Int
}

struct Issue: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let number: Int
    let title: String
    let state: String
    let stateReason: String?
    let htmlUrl: URL
    let user: GHUser?
    let labels: [GHLabel]
    let assignees: [GHUser]?
    let comments: Int
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let body: String?
    let pullRequest: IssuePRLink?
    let milestone: Milestone?

    var isPR: Bool { pullRequest != nil }
    var isOpen: Bool { state == "open" }
}

struct IssuePRLink: Decodable, Hashable, Sendable {
    let url: URL?
    let mergedAt: Date?
}

struct IssueComment: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let user: GHUser?
    let body: String?
    let createdAt: Date
    let htmlUrl: URL?
}

/// Lightweight REST pull request, used as a cheap change sentinel.
struct PullRequestREST: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let number: Int
    let title: String
    let state: String
    let htmlUrl: URL
    let user: GHUser?
    let draft: Bool?
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let mergedAt: Date?
    let head: PRRef
    let base: PRRef
    /// Only present on the single pull request endpoint.
    let comments: Int?
    let reviewComments: Int?
}

struct PRReviewREST: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let user: GHUser?
    let state: String
    let submittedAt: Date?
    let htmlUrl: URL?
}

struct CheckRunsResponse: Decodable, Sendable {
    let totalCount: Int
    let checkRuns: [CheckRunREST]
}

struct CheckRunREST: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?

    var state: CIState { CIState(status: status, conclusion: conclusion) }
}

struct PRRef: Decodable, Hashable, Sendable {
    let ref: String
    let sha: String
}

struct WorkflowRunsResponse: Decodable, Sendable {
    let totalCount: Int
    let workflowRuns: [WorkflowRun]
}

struct WorkflowRun: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let headSha: String
    let status: String?
    let conclusion: String?
    let event: String
    let runNumber: Int
    let runAttempt: Int?
    let htmlUrl: URL
    let createdAt: Date
    let updatedAt: Date
    let runStartedAt: Date?
    let actor: GHUser?
    let triggeringActor: GHUser?
    let workflowId: Int
    let pullRequests: [RunPR]?
    let headCommit: HeadCommit?

    var isActive: Bool { status != "completed" }
    var state: CIState { CIState(status: status, conclusion: conclusion) }
    var workflowName: String { name ?? "Workflow" }
    var duration: TimeInterval? {
        guard let start = runStartedAt else { return nil }
        return (isActive ? Date.now : updatedAt).timeIntervalSince(start)
    }
}

struct RunPR: Decodable, Hashable, Sendable { let number: Int }

struct HeadCommit: Decodable, Hashable, Sendable {
    let id: String
    let message: String
    let timestamp: Date?
    let author: CommitPerson?
}

struct CommitPerson: Decodable, Hashable, Sendable {
    let name: String?
    let email: String?
    let date: Date?
}

struct JobsResponse: Decodable, Sendable {
    let totalCount: Int
    let jobs: [Job]
}

struct Job: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let htmlUrl: URL?
    let steps: [JobStep]?
    let runnerName: String?

    var state: CIState { CIState(status: status, conclusion: conclusion) }
}

struct JobStep: Decodable, Hashable, Identifiable, Sendable {
    let name: String
    let status: String?
    let conclusion: String?
    let number: Int
    let startedAt: Date?
    let completedAt: Date?

    var id: Int { number }
    var state: CIState { CIState(status: status, conclusion: conclusion) }
}

struct WorkflowsResponse: Decodable, Sendable {
    let totalCount: Int
    let workflows: [Workflow]
}

struct Workflow: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let path: String
    let state: String
    let htmlUrl: URL?
}

struct CommitDetail: Decodable, Sendable {
    let sha: String
    let htmlUrl: URL
    let commit: Inner
    let author: GHUser?
    let stats: Stats?
    let files: [File]?
    let parents: [Parent]

    struct Inner: Decodable, Sendable {
        let message: String
        let author: CommitPerson?
        let committer: CommitPerson?
    }

    struct Stats: Decodable, Sendable {
        let additions: Int
        let deletions: Int
        let total: Int
    }

    struct File: Decodable, Identifiable, Sendable {
        var id: String { filename }
        let filename: String
        let status: String
        let additions: Int
        let deletions: Int
        let patch: String?
    }

    struct Parent: Decodable, Sendable { let sha: String }
}

// MARK: - Events API (decoded with the plain decoder; payloads stay loosely typed)

struct RepoEvent: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let type: String?
    let actor: EventActor
    let repo: EventRepo
    let payload: JSON
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, actor, repo, payload
        case createdAt = "created_at"
    }
}

struct EventActor: Decodable, Hashable, Sendable {
    let login: String
    let avatarUrl: URL?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarUrl = "avatar_url"
    }
}

struct EventRepo: Decodable, Hashable, Sendable {
    let name: String
}

// MARK: - Notifications inbox

struct NotificationThread: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: Date
    let lastReadAt: Date?
    let subject: Subject
    let repository: ThreadRepo

    struct Subject: Decodable, Hashable, Sendable {
        let title: String
        let url: URL?
        let latestCommentUrl: URL?
        let type: String
    }

    struct ThreadRepo: Decodable, Hashable, Sendable {
        let fullName: String
        let htmlUrl: URL
        let owner: GHUser
    }

    /// Translate the API URL of the subject into a browser URL.
    var webURL: URL {
        let repoURL = repository.htmlUrl
        guard let api = subject.url?.absoluteString else {
            switch subject.type {
            case "CheckSuite": return repoURL.appending(path: "actions")
            case "Discussion": return repoURL.appending(path: "discussions")
            default: return repoURL
            }
        }
        var web = api.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
        web = web.replacingOccurrences(of: "/pulls/", with: "/pull/")
        web = web.replacingOccurrences(of: "/commits/", with: "/commit/")
        if subject.type == "Release" { return repoURL.appending(path: "releases") }
        return URL(string: web) ?? repoURL
    }

    var reasonLabel: String {
        switch reason {
        case "review_requested": "Review requested"
        case "mention": "Mentioned"
        case "team_mention": "Team mentioned"
        case "assign": "Assigned"
        case "author": "Author"
        case "comment": "Comment"
        case "ci_activity": "CI"
        case "state_change": "State change"
        case "subscribed": "Watching"
        case "manual": "Subscribed"
        case "security_alert": "Security"
        case "approval_requested": "Approval requested"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var typeSymbol: String {
        switch subject.type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.filled.circle"
        case "Release": "shippingbox"
        case "Commit": "point.topleft.down.to.point.bottomright.curvepath"
        case "CheckSuite": "gearshape.2"
        case "Discussion": "bubble.left.and.bubble.right"
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread": "exclamationmark.shield"
        default: "bell"
        }
    }
}
