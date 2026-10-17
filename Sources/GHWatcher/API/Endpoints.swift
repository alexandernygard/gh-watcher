import Foundation

enum Queries {
    static let prFields = """
    fragment PRFields on PullRequest {
      id number title url state isDraft createdAt updatedAt
      headRefName baseRefName headRefOid additions deletions changedFiles
      author { login avatarUrl }
      reviewDecision mergeable
      repository { nameWithOwner }
      comments { totalCount }
      labels(first: 10) { nodes { name color } }
      reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login avatarUrl } ... on Team { name } } } }
      lastCommit: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    static let repoPRs = """
    query($owner: String!, $name: String!, $states: [PullRequestState!], $count: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: $states, first: $count, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { ...PRFields }
        }
      }
    }
    """ + prFields

    static let viewerPRs = """
    query($mine: String!, $reviews: String!) {
      mine: search(query: $mine, type: ISSUE, first: 40) { nodes { ... on PullRequest { ...PRFields } } }
      reviews: search(query: $reviews, type: ISSUE, first: 40) { nodes { ... on PullRequest { ...PRFields } } }
    }
    """ + prFields

    static let prDetail = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          ...PRFields
          body mergeStateStatus mergedAt closedAt viewerCanUpdate
          conversation: comments(last: 60) { nodes { id author { login avatarUrl } body createdAt url } }
          reviews(last: 40) { nodes { id author { login avatarUrl } state body submittedAt } }
          commitsList: commits(last: 100) { nodes { commit {
            oid messageHeadline committedDate url
            author { name user { login avatarUrl } }
            statusCheckRollup { state }
          } } }
          files(first: 100) { nodes { path additions deletions changeType } }
          checks: commits(last: 1) { nodes { commit {
            oid messageHeadline committedDate
            statusCheckRollup { state contexts(first: 60) { nodes {
              __typename
              ... on CheckRun { name status conclusion detailsUrl startedAt completedAt checkSuite { workflowRun { workflow { name } } } }
              ... on StatusContext { context state targetUrl description }
            } } }
          } } }
        }
      }
    }
    """ + prFields

    static let graph = """
    query($owner: String!, $name: String!, $refs: Int!, $depth: Int!, $defaultDepth: Int!) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name target { oid ... on Commit { history(first: $defaultDepth) { nodes { ...GraphCommit } } } } }
        refs(refPrefix: "refs/heads/", first: $refs, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
          nodes { name target { oid ... on Commit { history(first: $depth) { nodes { ...GraphCommit } } } } }
        }
        tags: refs(refPrefix: "refs/tags/", first: 20, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
          nodes { name target { oid ... on Tag { target { oid } } } }
        }
      }
    }
    fragment GraphCommit on Commit {
      oid messageHeadline committedDate url
      author { name user { login avatarUrl } }
      parents(first: 4) { nodes { oid } }
      statusCheckRollup { state }
    }
    """

    static let branches = """
    query($owner: String!, $name: String!, $default: String!) {
      repository(owner: $owner, name: $name) {
        refs(refPrefix: "refs/heads/", first: 100, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
          totalCount
          nodes {
            name
            branchProtectionRule { pattern }
            associatedPullRequests(first: 1, states: OPEN) { nodes { number title url } }
            compare(headRef: $default) { aheadBy behindBy }
            target { ... on Commit { oid committedDate messageHeadline author { name user { login avatarUrl } } statusCheckRollup { state } } }
          }
        }
      }
    }
    """

    static let labels = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) { labels(first: 100) { nodes { name color } } }
    }
    """
}

private func split(_ fullName: String) -> (String, String) {
    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
    return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
}

extension GitHubClient {
    // MARK: Reads

    func pullRequests(_ repo: String, states: [String] = ["OPEN"], count: Int = 50) async throws -> [PRItem] {
        let (owner, name) = split(repo)
        let r = try await graphql(Queries.repoPRs, variables: ["owner": owner, "name": name, "states": states, "count": count], as: RepoPRsResponse.self)
        return r.repository?.pullRequests.items.map(\.item) ?? []
    }

    func pullRequestDetail(_ repo: String, number: Int) async throws -> GQLPR? {
        let (owner, name) = split(repo)
        let r = try await graphql(Queries.prDetail, variables: ["owner": owner, "name": name, "number": number], as: PRDetailResponse.self)
        return r.repository?.pullRequest
    }

    func viewerPRs(login: String) async throws -> (mine: [PRItem], reviews: [PRItem]) {
        let r = try await graphql(Queries.viewerPRs, variables: [
            "mine": "is:pr is:open archived:false author:\(login)",
            "reviews": "is:pr is:open archived:false review-requested:\(login)",
        ], as: ViewerPRsResponse.self)
        return (r.mine.items.map(\.item), r.reviews.items.map(\.item))
    }

    func graph(_ repo: String, refs: Int = 15, depth: Int = 40, defaultDepth: Int = 100) async throws -> GraphResponse {
        let (owner, name) = split(repo)
        return try await graphql(Queries.graph, variables: ["owner": owner, "name": name, "refs": refs, "depth": depth, "defaultDepth": defaultDepth], as: GraphResponse.self)
    }

    func branches(_ repo: String, defaultBranch: String) async throws -> [BranchNode] {
        let (owner, name) = split(repo)
        let r = try await graphql(Queries.branches, variables: ["owner": owner, "name": name, "default": defaultBranch], as: BranchesResponse.self)
        return r.repository?.refs.items ?? []
    }

    func labels(_ repo: String) async throws -> [GQLLabel] {
        let (owner, name) = split(repo)
        let r = try await graphql(Queries.labels, variables: ["owner": owner, "name": name], as: LabelsResponse.self)
        return r.repository?.labels.items ?? []
    }

    func issueComments(_ repo: String, number: Int) async throws -> [IssueComment] {
        try await get("/repos/\(repo)/issues/\(number)/comments", query: ["per_page": "100"], as: [IssueComment].self).value
    }

    func issue(_ repo: String, number: Int) async throws -> Issue {
        try await get("/repos/\(repo)/issues/\(number)", as: Issue.self).value
    }

    func jobs(_ repo: String, runID: Int) async throws -> [Job] {
        try await get("/repos/\(repo)/actions/runs/\(runID)/jobs", query: ["per_page": "100"], as: JobsResponse.self).value.jobs
    }

    func workflows(_ repo: String) async throws -> [Workflow] {
        try await get("/repos/\(repo)/actions/workflows", query: ["per_page": "100"], as: WorkflowsResponse.self).value.workflows
    }

    func commit(_ repo: String, sha: String) async throws -> CommitDetail {
        try await get("/repos/\(repo)/commits/\(sha)", as: CommitDetail.self).value
    }

    // MARK: Writes

    func comment(_ repo: String, number: Int, body: String) async throws {
        try await send("POST", "/repos/\(repo)/issues/\(number)/comments", json: ["body": body])
    }

    func setIssueState(_ repo: String, number: Int, open: Bool, reason: String? = nil) async throws {
        var json: [String: Any] = ["state": open ? "open" : "closed"]
        if let reason { json["state_reason"] = reason }
        try await send("PATCH", "/repos/\(repo)/issues/\(number)", json: json)
    }

    func createIssue(_ repo: String, title: String, body: String, labels: [String], assignees: [String]) async throws -> Issue {
        try await send("POST", "/repos/\(repo)/issues", json: ["title": title, "body": body, "labels": labels, "assignees": assignees], as: Issue.self)
    }

    func createPR(_ repo: String, title: String, body: String, head: String, base: String, draft: Bool) async throws -> PullRequestREST {
        try await send("POST", "/repos/\(repo)/pulls", json: ["title": title, "body": body, "head": head, "base": base, "draft": draft], as: PullRequestREST.self)
    }

    func merge(_ repo: String, number: Int, method: String) async throws {
        try await send("PUT", "/repos/\(repo)/pulls/\(number)/merge", json: ["merge_method": method])
    }

    func setPRState(_ repo: String, number: Int, open: Bool) async throws {
        try await send("PATCH", "/repos/\(repo)/pulls/\(number)", json: ["state": open ? "open" : "closed"])
    }

    func review(_ repo: String, number: Int, event: String, body: String = "") async throws {
        var json: [String: Any] = ["event": event]
        if !body.isEmpty { json["body"] = body }
        try await send("POST", "/repos/\(repo)/pulls/\(number)/reviews", json: json)
    }

    func updateBranch(_ repo: String, number: Int) async throws {
        try await send("PUT", "/repos/\(repo)/pulls/\(number)/update-branch", json: [:])
    }

    func markReady(prNodeID: String) async throws {
        _ = try await graphql("mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { clientMutationId } }", variables: ["id": prNodeID], as: JSON.self)
    }

    func rerun(_ repo: String, runID: Int, failedOnly: Bool) async throws {
        try await send("POST", "/repos/\(repo)/actions/runs/\(runID)/\(failedOnly ? "rerun-failed-jobs" : "rerun")")
    }

    func cancel(_ repo: String, runID: Int) async throws {
        try await send("POST", "/repos/\(repo)/actions/runs/\(runID)/cancel")
    }

    func dispatch(_ repo: String, workflowID: Int, ref: String) async throws {
        try await send("POST", "/repos/\(repo)/actions/workflows/\(workflowID)/dispatches", json: ["ref": ref])
    }

    func markThreadRead(_ id: String) async throws {
        try await send("PATCH", "/notifications/threads/\(id)")
    }

    func markAllNotificationsRead() async throws {
        try await send("PUT", "/notifications", json: ["read": true])
    }
}
