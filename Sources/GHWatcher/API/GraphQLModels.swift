import Foundation

/// A GraphQL connection's `nodes`, decoded leniently: entries that are null or fail to decode are skipped.
struct GQLNodes<T: Decodable>: Decodable {
    let items: [T]
    let totalCount: Int?

    enum CodingKeys: String, CodingKey { case nodes, totalCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try c.decodeIfPresent(Int.self, forKey: .totalCount)
        let raw = try c.decodeIfPresent([Lenient<T>].self, forKey: .nodes) ?? []
        items = raw.compactMap(\.value)
    }

    init(items: [T]) {
        self.items = items
        totalCount = items.count
    }
}

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        do { value = try T(from: decoder) } catch {
            if (try? decoder.singleValueContainer().decodeNil()) != true {
                print("[GHWatcher] Skipping \(T.self): \(error)")
            }
            value = nil
        }
    }
}

struct GQLCount: Decodable { let totalCount: Int }

struct GQLActor: Decodable, Hashable {
    let login: String
    let avatarUrl: URL?
}

struct GQLGitActor: Decodable, Hashable {
    let name: String?
    let user: GQLActor?
}

struct GQLLabel: Decodable, Hashable {
    let name: String
    let color: String
}

struct GQLRollup: Decodable {
    let state: String?
    let contexts: GQLNodes<GQLCheckContext>?
}

struct GQLOid: Decodable { let oid: String }

struct GQLCommit: Decodable {
    let oid: String
    let messageHeadline: String
    let committedDate: Date
    let url: URL?
    let author: GQLGitActor?
    let statusCheckRollup: GQLRollup?
    let parents: GQLNodes<GQLOid>?
}

struct GQLCommitWrap: Decodable { let commit: GQLCommit }

struct GQLRollupOnlyWrap: Decodable {
    let commit: Inner
    struct Inner: Decodable { let statusCheckRollup: GQLRollup? }
}

struct GQLReviewRequest: Decodable {
    let requestedReviewer: Reviewer?
    struct Reviewer: Decodable {
        let login: String?
        let name: String?
        let avatarUrl: URL?
    }
}

struct GQLComment: Decodable, Identifiable {
    let id: String
    let author: GQLActor?
    let body: String
    let createdAt: Date
    let url: URL?
}

struct GQLReview: Decodable, Identifiable {
    let id: String
    let author: GQLActor?
    let state: String
    let body: String
    let submittedAt: Date?
}

struct GQLFile: Decodable, Identifiable {
    var id: String { path }
    let path: String
    let additions: Int
    let deletions: Int
    let changeType: String
}

struct GQLCheckContext: Decodable, Identifiable {
    let typename: String
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsUrl: String?
    let startedAt: Date?
    let completedAt: Date?
    let context: String?
    let state: String?
    let targetUrl: String?
    let description: String?
    let checkSuite: Suite?

    struct Suite: Decodable {
        let workflowRun: Run?
        struct Run: Decodable {
            let workflow: Flow?
            struct Flow: Decodable { let name: String }
        }
    }

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, status, conclusion, detailsUrl, startedAt, completedAt, context, state, targetUrl, description, checkSuite
    }

    var id: String { (checkSuite?.workflowRun?.workflow?.name ?? "") + "/" + (name ?? context ?? UUID().uuidString) }
    var title: String { name ?? context ?? "Check" }
    var workflowName: String? { checkSuite?.workflowRun?.workflow?.name }
    var ciState: CIState {
        if typename == "StatusContext" { return CIState(rollup: state) }
        if status != "COMPLETED" { return CIState(rollup: status) }
        return CIState(rollup: conclusion)
    }
    var link: URL? { (detailsUrl ?? targetUrl).flatMap(URL.init(string:)) }
    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? .now).timeIntervalSince(startedAt)
    }
}

struct GQLPR: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let headRefName: String
    let baseRefName: String
    let headRefOid: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let author: GQLActor?
    let reviewDecision: String?
    let mergeable: String?
    let repository: RepoName
    let comments: GQLCount
    let labels: GQLNodes<GQLLabel>?
    let reviewRequests: GQLNodes<GQLReviewRequest>?
    let lastCommit: GQLNodes<GQLRollupOnlyWrap>?

    // Detail-only fields
    let body: String?
    let mergeStateStatus: String?
    let mergedAt: Date?
    let closedAt: Date?
    let viewerCanUpdate: Bool?
    let conversation: GQLNodes<GQLComment>?
    let reviews: GQLNodes<GQLReview>?
    let commitsList: GQLNodes<GQLCommitWrap>?
    let files: GQLNodes<GQLFile>?
    let checks: GQLNodes<GQLCommitWrap>?

    struct RepoName: Decodable { let nameWithOwner: String }

    var item: PRItem {
        PRItem(
            id: id,
            number: number,
            title: title,
            url: url,
            repo: repository.nameWithOwner,
            author: author?.login ?? "ghost",
            authorAvatar: author?.avatarUrl,
            state: state,
            isDraft: isDraft,
            createdAt: createdAt,
            updatedAt: updatedAt,
            headRef: headRefName,
            baseRef: baseRefName,
            headSha: headRefOid,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            commentCount: comments.totalCount,
            reviewDecision: reviewDecision,
            mergeable: mergeable,
            checkState: CIState(rollup: lastCommit?.items.first?.commit.statusCheckRollup?.state),
            labels: labels?.items.map { PRItem.Label(name: $0.name, color: $0.color) } ?? [],
            requestedReviewers: reviewRequests?.items.compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.name } ?? []
        )
    }
}

/// UI-facing pull request summary.
struct PRItem: Identifiable, Hashable, Sendable {
    struct Label: Hashable, Sendable {
        let name: String
        let color: String
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: String
    let authorAvatar: URL?
    let state: String
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let headRef: String
    let baseRef: String
    let headSha: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let commentCount: Int
    let reviewDecision: String?
    let mergeable: String?
    let checkState: CIState
    let labels: [Label]
    let requestedReviewers: [String]

    var owner: String { String(repo.split(separator: "/").first ?? "") }
    var repoName: String { String(repo.split(separator: "/").last ?? "") }
}

// MARK: - Response wrappers

struct RepoPRsResponse: Decodable {
    let repository: Repository?
    struct Repository: Decodable { let pullRequests: GQLNodes<GQLPR> }
}

struct PRDetailResponse: Decodable {
    let repository: Repository?
    struct Repository: Decodable { let pullRequest: GQLPR? }
}

struct ViewerPRsResponse: Decodable {
    let mine: GQLNodes<GQLPR>
    let reviews: GQLNodes<GQLPR>
}

struct GraphResponse: Decodable {
    let repository: Repository?

    struct Repository: Decodable {
        let defaultBranchRef: RefNode?
        let refs: GQLNodes<RefNode>
        let tags: GQLNodes<TagNode>
    }

    struct RefNode: Decodable {
        let name: String
        let target: Target?
        struct Target: Decodable {
            let oid: String
            let history: GQLNodes<GQLCommit>?
        }
    }

    struct TagNode: Decodable {
        let name: String
        let target: TagTarget?
        struct TagTarget: Decodable {
            let oid: String
            let target: GQLOid?
        }
        var commitOid: String? { target?.target?.oid ?? target?.oid }
    }
}

struct BranchesResponse: Decodable {
    let repository: Repository?
    struct Repository: Decodable { let refs: GQLNodes<BranchNode> }
}

struct BranchNode: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let branchProtectionRule: Rule?
    let associatedPullRequests: GQLNodes<PRLink>?
    let target: GQLCommitLite?
    let compare: Compare?

    struct Rule: Decodable { let pattern: String }
    struct PRLink: Decodable {
        let number: Int
        let title: String
        let url: URL
    }
    struct Compare: Decodable {
        let aheadBy: Int
        let behindBy: Int
    }
}

struct GQLCommitLite: Decodable {
    let oid: String?
    let committedDate: Date?
    let messageHeadline: String?
    let author: GQLGitActor?
    let statusCheckRollup: GQLRollup?
}

struct LabelsResponse: Decodable {
    let repository: Repository?
    struct Repository: Decodable { let labels: GQLNodes<GQLLabel> }
}
