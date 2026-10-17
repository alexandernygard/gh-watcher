import Foundation
import Observation

enum RepoTab: String, CaseIterable, Identifiable {
    case overview, graph, pulls, issues, actions, activity, branches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .graph: "Graph"
        case .pulls: "Pull Requests"
        case .issues: "Issues"
        case .actions: "Actions"
        case .activity: "Activity"
        case .branches: "Branches"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .pulls: "arrow.triangle.pull"
        case .issues: "smallcircle.filled.circle"
        case .actions: "play.circle"
        case .activity: "waveform.path.ecg"
        case .branches: "arrow.triangle.branch"
        }
    }
}

/// Live state for one watched repository plus the change detection that turns polls into events.
@MainActor
@Observable
final class RepoStore: Identifiable {
    let fullName: String
    nonisolated var id: String { fullName }
    var owner: String { String(fullName.split(separator: "/").first ?? "") }
    var name: String { String(fullName.split(separator: "/").last ?? "") }

    var repo: Repo?
    var prs: [PRItem] = []
    var issues: [Issue] = []
    var runs: [WorkflowRun] = []
    var events: [RepoEvent] = []
    var branches: [BranchNode] = []
    var graph: CommitGraph?
    var closedPRs: [PRItem] = []
    var closedIssues: [Issue] = []

    var tab: RepoTab = .overview
    var lastPolled: Date?
    var lastError: String?
    var isPolling = false
    var graphLoading = false
    var branchesLoading = false
    var nextPoll = Date.distantPast
    var graphVisible = false
    var branchesVisible = false

    // Change tracking
    private let watchStarted = Date.now
    private var baselineDone = false
    private var runStates: [Int: CIState] = [:]
    private var prStates: [Int: (state: String, merged: Bool, draft: Bool)] = [:]
    private var issueStates: [Int: String] = [:]
    private var seenEvents: Set<String> = []
    private var authors: [Int: String] = [:]
    private var prsDirty = true
    private var issuesDirty = true
    private var graphDirty = true
    private var branchesDirty = true
    private var lastPRFetch = Date.distantPast
    private var lastRepoFetch = Date.distantPast
    private var nextEventsPoll = Date.distantPast

    init(fullName: String) {
        self.fullName = fullName
    }

    // MARK: Derived state

    var webURL: URL { repo?.htmlUrl ?? URL(string: "https://github.com/\(fullName)")! }
    var defaultBranch: String { repo?.defaultBranch ?? "main" }
    var hasActiveRuns: Bool { runs.contains(where: \.isActive) }

    /// Latest run of each workflow on the default branch.
    var defaultBranchRuns: [WorkflowRun] {
        var seen = Set<Int>()
        return runs.filter { $0.headBranch == defaultBranch && seen.insert($0.workflowId).inserted }
    }

    var ciState: CIState {
        if runs.isEmpty { return .none }
        return CIState.combine(defaultBranchRuns.map(\.state))
    }

    var activeRuns: [WorkflowRun] { runs.filter(\.isActive) }

    func latestRun(forBranch branch: String) -> WorkflowRun? { runs.first { $0.headBranch == branch } }

    func runs(forSha sha: String) -> [WorkflowRun] { runs.filter { $0.headSha == sha } }

    func markAllDirty() {
        prsDirty = true
        issuesDirty = true
        graphDirty = true
        branchesDirty = true
        lastRepoFetch = .distantPast
        nextEventsPoll = .distantPast
        nextPoll = .distantPast
    }

    func markPRsDirty() { prsDirty = true; nextPoll = .distantPast }
    func markIssuesDirty() { issuesDirty = true; nextPoll = .distantPast }
    func markRunsChanged() { nextPoll = .distantPast }

    // MARK: Polling

    /// One polling pass. Cheap when nothing changed: every REST call is conditional and returns 304.
    func poll(client: GitHubClient, me: String?) async -> [WatchEvent] {
        guard !isPolling else { return [] }
        isPolling = true
        defer { isPolling = false }
        var out: [WatchEvent] = []

        do {
            if repo == nil || Date.now.timeIntervalSince(lastRepoFetch) > 600 {
                repo = try await client.get("/repos/\(fullName)", as: Repo.self).value
                lastRepoFetch = .now
            }

            // Actions runs
            let runsResult = try await client.get("/repos/\(fullName)/actions/runs", query: ["per_page": "40"], as: WorkflowRunsResponse.self)
            if runsResult.changed || runs.isEmpty {
                let newRuns = runsResult.value.workflowRuns
                out += detectRunChanges(newRuns, me: me)
                if newRuns.map(\.state) != runs.map(\.state) || newRuns.map(\.id) != runs.map(\.id) { prsDirty = true }
                runs = newRuns
            }

            // Events (respect X-Poll-Interval)
            if Date.now >= nextEventsPoll {
                let ev = try await client.get("/repos/\(fullName)/events", query: ["per_page": "50"], as: [RepoEvent].self, snake: false)
                nextEventsPoll = Date.now.addingTimeInterval(TimeInterval(ev.pollInterval ?? 60))
                if ev.changed || events.isEmpty {
                    out += detectEvents(ev.value, me: me)
                    events = ev.value
                }
            }

            // Pull request sentinel
            let pulls = try await client.get("/repos/\(fullName)/pulls",
                                             query: ["state": "all", "sort": "updated", "direction": "desc", "per_page": "20"],
                                             as: [PullRequestREST].self)
            if pulls.changed || prStates.isEmpty {
                out += detectPRChanges(pulls.value, me: me)
                prsDirty = true
            }

            // Issue sentinel
            let issueSentinel = try await client.get("/repos/\(fullName)/issues",
                                                     query: ["state": "all", "sort": "updated", "direction": "desc", "per_page": "20"],
                                                     as: [Issue].self)
            if issueSentinel.changed || issueStates.isEmpty {
                out += detectIssueChanges(issueSentinel.value.filter { !$0.isPR }, me: me)
                issuesDirty = true
            }

            if prsDirty || Date.now.timeIntervalSince(lastPRFetch) > 300 {
                prs = try await client.pullRequests(fullName)
                for pr in prs { authors[pr.number] = pr.author }
                prsDirty = false
                lastPRFetch = .now
            }

            if issuesDirty {
                let open = try await client.get("/repos/\(fullName)/issues", query: ["state": "open", "per_page": "100"], as: [Issue].self)
                issues = open.value.filter { !$0.isPR }
                for issue in issues { if let login = issue.user?.login { authors[issue.number] = login } }
                issuesDirty = false
            }

            if graphVisible && graphDirty { await loadGraph(client: client) }
            if branchesVisible && branchesDirty { await loadBranches(client: client) }

            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        lastPolled = .now
        if !baselineDone {
            baselineDone = true
            return []
        }
        return out
    }

    func loadGraph(client: GitHubClient) async {
        guard !graphLoading else { return }
        graphLoading = true
        defer { graphLoading = false }
        do {
            let response = try await client.graph(fullName)
            graph = CommitGraph.build(from: response)
            graphDirty = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadBranches(client: GitHubClient) async {
        guard !branchesLoading else { return }
        branchesLoading = true
        defer { branchesLoading = false }
        do {
            branches = try await client.branches(fullName, defaultBranch: defaultBranch)
            branchesDirty = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadClosed(client: GitHubClient) async {
        do {
            closedPRs = try await client.pullRequests(fullName, states: ["MERGED", "CLOSED"], count: 40)
            let closed = try await client.get("/repos/\(fullName)/issues", query: ["state": "closed", "per_page": "50"], as: [Issue].self)
            closedIssues = closed.value.filter { !$0.isPR }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Change detection

    private func isMe(_ login: String?, _ me: String?) -> Bool {
        guard let login, let me else { return false }
        return login.caseInsensitiveCompare(me) == .orderedSame
    }

    private func detectRunChanges(_ newRuns: [WorkflowRun], me: String?) -> [WatchEvent] {
        var out: [WatchEvent] = []
        for (index, run) in newRuns.enumerated() {
            let previous = runStates[run.id]
            let state = run.state
            runStates[run.id] = state
            guard baselineDone else { continue }

            let actor = run.triggeringActor ?? run.actor
            let prAuthor = run.pullRequests?.first.flatMap { authors[$0.number] }
            let mine = isMe(actor?.login, me) || isMe(run.actor?.login, me) || isMe(prAuthor, me)
            let branch = run.headBranch ?? ""
            let title = "\(run.workflowName) on \(branch)"
            let subtitle = run.displayTitle ?? run.headCommit?.message.components(separatedBy: "\n").first ?? ""

            func event(_ kind: EventKind) -> WatchEvent {
                WatchEvent(kind: kind, repo: fullName, title: title, subtitle: subtitle, url: run.htmlUrl,
                           actor: actor?.login, actorAvatar: actor?.avatarUrl, branch: run.headBranch, involvesMe: mine)
            }

            if previous == nil {
                guard run.createdAt > watchStarted else { continue }
                if run.isActive { out.append(event(.workflowStarted)); continue }
            } else if previous?.isActive == false {
                continue
            }
            guard !run.isActive else { continue }

            switch state {
            case .failure:
                out.append(event(.workflowFailed))
            case .success:
                let prior = newRuns[(index + 1)...].first { $0.workflowId == run.workflowId && $0.headBranch == run.headBranch && !$0.isActive }
                out.append(event(prior?.state == .failure ? .workflowFixed : .workflowSucceeded))
            default:
                break
            }
        }
        return out
    }

    private func detectPRChanges(_ pulls: [PullRequestREST], me: String?) -> [WatchEvent] {
        var out: [WatchEvent] = []
        for pr in pulls {
            if let login = pr.user?.login { authors[pr.number] = login }
            let previous = prStates[pr.number]
            let merged = pr.mergedAt != nil
            let draft = pr.draft ?? false
            prStates[pr.number] = (pr.state, merged, draft)
            guard baselineDone else { continue }

            let mine = isMe(pr.user?.login, me)
            func event(_ kind: EventKind, _ subtitle: String) -> WatchEvent {
                WatchEvent(kind: kind, repo: fullName, title: "#\(pr.number) \(pr.title)", subtitle: subtitle, url: pr.htmlUrl,
                           actor: pr.user?.login, actorAvatar: pr.user?.avatarUrl, branch: pr.base.ref, involvesMe: mine)
            }

            if let previous {
                if previous.state == "open" && pr.state == "closed" {
                    out.append(merged ? event(.prMerged, "Merged into \(pr.base.ref)") : event(.prClosed, "Closed without merging"))
                } else if previous.state == "closed" && pr.state == "open" {
                    out.append(event(.prOpened, "Reopened by \(pr.user?.login ?? "someone")"))
                } else if previous.draft && !draft && pr.state == "open" {
                    out.append(event(.prReadyForReview, "\(pr.head.ref) → \(pr.base.ref)"))
                }
            } else if pr.createdAt > watchStarted && pr.state == "open" {
                out.append(event(.prOpened, "\(pr.user?.login ?? "Someone") wants to merge \(pr.head.ref) into \(pr.base.ref)"))
            }
        }
        return out
    }

    private func detectIssueChanges(_ list: [Issue], me: String?) -> [WatchEvent] {
        var out: [WatchEvent] = []
        for issue in list {
            if let login = issue.user?.login { authors[issue.number] = login }
            let previous = issueStates[issue.number]
            issueStates[issue.number] = issue.state
            guard baselineDone else { continue }

            let mine = isMe(issue.user?.login, me) || (issue.assignees ?? []).contains { isMe($0.login, me) }
            func event(_ kind: EventKind, _ subtitle: String) -> WatchEvent {
                WatchEvent(kind: kind, repo: fullName, title: "#\(issue.number) \(issue.title)", subtitle: subtitle, url: issue.htmlUrl,
                           actor: issue.user?.login, actorAvatar: issue.user?.avatarUrl, involvesMe: mine)
            }

            if let previous {
                if previous == "open" && issue.state == "closed" {
                    out.append(event(.issueClosed, issue.stateReason == "not_planned" ? "Closed as not planned" : "Closed as completed"))
                } else if previous == "closed" && issue.state == "open" {
                    out.append(event(.issueReopened, "Reopened"))
                }
            } else if issue.createdAt > watchStarted && issue.isOpen {
                out.append(event(.issueOpened, "Opened by \(issue.user?.login ?? "someone")"))
            }
        }
        return out
    }

    private func detectEvents(_ list: [RepoEvent], me: String?) -> [WatchEvent] {
        var out: [WatchEvent] = []
        for ev in list.reversed() where !seenEvents.contains(ev.id) {
            seenEvents.insert(ev.id)
            guard baselineDone, ev.createdAt > watchStarted.addingTimeInterval(-120) else { continue }
            let p = ev.payload
            let actor = ev.actor.login
            let avatar = ev.actor.avatarUrl

            switch ev.type {
            case "PushEvent":
                graphDirty = true
                branchesDirty = true
                let branch = p["ref"]?.string?.replacingOccurrences(of: "refs/heads/", with: "")
                let count = p["size"]?.int ?? p["commits"]?.array?.count
                let message = p["commits"]?.array?.last?["message"]?.string?.components(separatedBy: "\n").first ?? ""
                let headline = count.map { "\($0) commit\($0 == 1 ? "" : "s") to \(branch ?? "branch")" } ?? "Pushed to \(branch ?? "branch")"
                let url = p["head"]?.string.map { webURL.appending(path: "commit/\($0)") } ?? webURL
                out.append(WatchEvent(kind: .push, repo: fullName, title: headline, subtitle: message, url: url,
                                      actor: actor, actorAvatar: avatar, branch: branch, involvesMe: isMe(actor, me), date: ev.createdAt))

            case "CreateEvent", "DeleteEvent":
                graphDirty = true
                branchesDirty = true
                guard ev.type == "CreateEvent", let ref = p["ref"]?.string else { continue }
                let refType = p["ref_type"]?.string ?? "branch"
                guard refType != "repository" else { continue }
                out.append(WatchEvent(kind: .branchCreated, repo: fullName, title: "New \(refType) \(ref)", subtitle: "Created by \(actor)",
                                      url: webURL.appending(path: refType == "tag" ? "releases/tag/\(ref)" : "tree/\(ref)"),
                                      actor: actor, actorAvatar: avatar, branch: ref, involvesMe: isMe(actor, me), date: ev.createdAt))

            case "IssueCommentEvent", "PullRequestReviewCommentEvent":
                guard (p["action"]?.string ?? "created") == "created" else { continue }
                let issue = p["issue"] ?? p["pull_request"]
                let number = issue?["number"]?.int
                let owner = issue?["user"]?["login"]?.string ?? number.flatMap { authors[$0] }
                let title = issue?["title"]?.string ?? number.map { "#\($0)" } ?? "Conversation"
                let body = p["comment"]?["body"]?.string ?? ""
                let url = p["comment"]?["html_url"]?.url ?? issue?["html_url"]?.url ?? webURL
                let mine = isMe(owner, me) || (me.map { body.localizedCaseInsensitiveContains("@\($0)") } ?? false)
                out.append(WatchEvent(kind: .comment, repo: fullName, title: "\(actor) commented on \(number.map { "#\($0) " } ?? "")\(title.hasPrefix("#") ? "" : title)",
                                      subtitle: String(body.prefix(200)), url: url, actor: actor, actorAvatar: avatar, involvesMe: mine, date: ev.createdAt))
                if issue?["pull_request"] != nil || ev.type == "PullRequestReviewCommentEvent" { prsDirty = true } else { issuesDirty = true }

            case "PullRequestReviewEvent":
                prsDirty = true
                let pr = p["pull_request"]
                let number = pr?["number"]?.int
                let owner = pr?["user"]?["login"]?.string ?? number.flatMap { authors[$0] }
                let state = (p["review"]?["state"]?.string ?? "reviewed").lowercased()
                let verb = switch state {
                case "approved": "approved"
                case "changes_requested": "requested changes on"
                default: "reviewed"
                }
                let url = p["review"]?["html_url"]?.url ?? pr?["html_url"]?.url ?? webURL
                let title = pr?["title"]?.string ?? ""
                out.append(WatchEvent(kind: .prReviewSubmitted, repo: fullName, title: "\(actor) \(verb) #\(number ?? 0) \(title)",
                                      subtitle: String((p["review"]?["body"]?.string ?? "").prefix(200)), url: url,
                                      actor: actor, actorAvatar: avatar, involvesMe: isMe(owner, me), date: ev.createdAt))

            case "ReleaseEvent":
                guard p["action"]?.string == "published" else { continue }
                let release = p["release"]
                let name = release?["name"]?.string ?? release?["tag_name"]?.string ?? "New release"
                out.append(WatchEvent(kind: .release, repo: fullName, title: name, subtitle: "Published by \(actor)",
                                      url: release?["html_url"]?.url ?? webURL.appending(path: "releases"),
                                      actor: actor, actorAvatar: avatar, involvesMe: isMe(actor, me), date: ev.createdAt))

            case "WatchEvent":
                out.append(WatchEvent(kind: .star, repo: fullName, title: "\(actor) starred \(name)", subtitle: "",
                                      url: URL(string: "https://github.com/\(actor)"), actor: actor, actorAvatar: avatar, date: ev.createdAt))

            case "ForkEvent":
                let fork = p["forkee"]?["full_name"]?.string ?? actor
                out.append(WatchEvent(kind: .fork, repo: fullName, title: "\(actor) forked \(name)", subtitle: fork,
                                      url: p["forkee"]?["html_url"]?.url ?? URL(string: "https://github.com/\(fork)"),
                                      actor: actor, actorAvatar: avatar, date: ev.createdAt))

            case "PullRequestEvent":
                prsDirty = true
            case "IssuesEvent":
                issuesDirty = true
            default:
                break
            }
        }
        return out
    }
}
