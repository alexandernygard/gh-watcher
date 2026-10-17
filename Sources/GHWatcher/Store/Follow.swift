import Foundation

/// A single run or pull request the user asked to hear about, independent of notification rules.
struct Follow: Codable, Identifiable, Hashable, Sendable {
    enum Target: Codable, Hashable, Sendable {
        case run(Int)
        case pr(Int)
    }

    let repo: String
    let target: Target
    var title: String
    var url: URL
    var created = Date.now
    var snapshot: Snapshot?

    /// Last observed state; compared on every poll to decide what to announce.
    struct Snapshot: Codable, Hashable, Sendable {
        var active = false
        var sawActive = false
        var state = ""
        var merged = false
        var draft = false
        var headSha = ""
        var comments = 0
        var reviewIDs: [Int] = []
        var checks = CIState.none.rawValue

        var isRunActiveOrChecks: String { active ? CIState.running.rawValue : checks }
    }

    var id: String {
        switch target {
        case .run(let id): "\(repo)/run/\(id)"
        case .pr(let number): "\(repo)/pr/\(number)"
        }
    }

    var isRun: Bool { if case .run = target { true } else { false } }

    var statusLine: String {
        guard let s = snapshot else { return "Waiting for first check" }
        if isRun { return s.active ? "running" : s.sawActive ? "finished" : "waiting for the next attempt" }
        let checks = CIState(rawValue: s.checks) ?? .none
        return checks == .none ? "watching for changes" : "checks \(checks.label.lowercased())"
    }

    init(run: WorkflowRun, repo: String) {
        self.repo = repo
        target = .run(run.id)
        title = "\(run.workflowName) on \(run.headBranch ?? "?")"
        url = run.htmlUrl
    }

    init(pr: PRItem) {
        repo = pr.repo
        target = .pr(pr.number)
        title = "#\(pr.number) \(pr.title)"
        url = pr.url
    }

    init(repo: String, number: Int, title: String, url: URL) {
        self.repo = repo
        target = .pr(number)
        self.title = "#\(number) \(title)"
        self.url = url
    }
}

extension AppStore {
    func isFollowing(_ follow: Follow) -> Bool { prefs.follows.contains { $0.id == follow.id } }

    func toggleFollow(_ follow: Follow) {
        if isFollowing(follow) {
            prefs.follows.removeAll { $0.id == follow.id }
        } else {
            prefs.follows.append(follow)
            nextFollowPoll = .distantPast
        }
    }

    func unfollow(_ id: Follow.ID) { prefs.follows.removeAll { $0.id == id } }

    /// Poll every followed item once. Conditional requests make unchanged items free.
    func pollFollows() async {
        guard let client else { return }
        var events: [WatchEvent] = []
        for follow in prefs.follows {
            do {
                let (updated, found, done) = switch follow.target {
                case .run(let id): try await checkRun(follow, id: id, client: client)
                case .pr(let number): try await checkPR(follow, number: number, client: client)
                }
                events += found
                if done {
                    prefs.follows.removeAll { $0.id == follow.id }
                } else if let i = prefs.follows.firstIndex(where: { $0.id == follow.id }), prefs.follows[i] != updated {
                    prefs.follows[i] = updated
                }
            } catch GitHubError.http(404, _) {
                prefs.follows.removeAll { $0.id == follow.id }
            } catch {
                lastError = error.localizedDescription
            }
        }
        handle(events)
    }

    var followPollInterval: TimeInterval {
        let active = prefs.follows.contains { $0.isRun || $0.snapshot?.checks == CIState.running.rawValue || $0.snapshot?.checks == CIState.queued.rawValue }
        return (active ? 15 : 30) * (appActive ? 1 : 1.5)
    }

    private func event(_ follow: Follow, _ kind: EventKind, _ headline: String, _ subtitle: String,
                       actor: GHUser? = nil, url: URL? = nil) -> WatchEvent {
        var e = WatchEvent(kind: kind, repo: follow.repo, title: follow.title, subtitle: subtitle, url: url ?? follow.url,
                           actor: actor?.login, actorAvatar: actor?.avatarUrl, involvesMe: true)
        e.followed = true
        e.headline = headline
        return e
    }

    private func checkRun(_ follow: Follow, id: Int, client: GitHubClient) async throws -> (Follow, [WatchEvent], Bool) {
        let run = try await client.run(follow.repo, id: id)
        var f = follow
        var snap = f.snapshot ?? Follow.Snapshot()
        snap.active = run.isActive
        snap.sawActive = snap.sawActive || run.isActive
        snap.state = run.state.rawValue
        f.snapshot = snap
        // Following a finished run waits for its next attempt (e.g. after a re-run).
        guard snap.sawActive, !run.isActive else { return (f, [], false) }
        let kind: EventKind = run.state == .failure ? .workflowFailed : .workflowSucceeded
        let verb = switch run.state {
        case .success: "passed"
        case .failure: "failed"
        case .cancelled: "was cancelled"
        default: "finished"
        }
        let duration = run.duration.map { " in \($0.durationString)" } ?? ""
        return (f, [event(follow, kind, "Run \(verb)", "\(run.workflowName) \(verb)\(duration)", actor: run.triggeringActor ?? run.actor)], true)
    }

    private func checkPR(_ follow: Follow, number: Int, client: GitHubClient) async throws -> (Follow, [WatchEvent], Bool) {
        let pr = try await client.pull(follow.repo, number: number)
        let reviews = try await client.reviews(follow.repo, number: number)
        let checks = try await client.checkRuns(follow.repo, sha: pr.head.sha)
        let checkState = checks.isEmpty ? CIState.none : CIState.combine(checks.map(\.state))

        var f = follow
        f.title = "#\(pr.number) \(pr.title)"
        let new = Follow.Snapshot(
            state: pr.state, merged: pr.mergedAt != nil, draft: pr.draft ?? false, headSha: pr.head.sha,
            comments: (pr.comments ?? 0) + (pr.reviewComments ?? 0),
            reviewIDs: reviews.map(\.id), checks: checkState.rawValue
        )
        guard let old = follow.snapshot else {
            f.snapshot = new
            return (f, [], false)
        }
        f.snapshot = new
        var out: [WatchEvent] = []

        if new.merged && !old.merged {
            out.append(event(f, .prMerged, "Pull request merged", "Merged into \(pr.base.ref)"))
            return (f, out, true)
        }
        if new.state == "closed" && old.state == "open" {
            out.append(event(f, .prClosed, "Pull request closed", "Closed without merging"))
            return (f, out, true)
        }
        for review in reviews where !old.reviewIDs.contains(review.id) && review.state != "PENDING" {
            let verb = switch review.state {
            case "APPROVED": "approved"
            case "CHANGES_REQUESTED": "requested changes"
            case "DISMISSED": "had a review dismissed"
            default: "left a review"
            }
            out.append(event(f, .prReviewSubmitted, "\(review.user?.login ?? "Someone") \(verb)", f.title, actor: review.user, url: review.htmlUrl))
        }
        if new.comments > old.comments {
            let n = new.comments - old.comments
            out.append(event(f, .comment, "\(n) new comment\(n == 1 ? "" : "s")", f.title))
        }
        if old.draft && !new.draft {
            out.append(event(f, .prReadyForReview, "Ready for review", "\(pr.head.ref) → \(pr.base.ref)"))
        }
        if new.headSha != old.headSha {
            out.append(event(f, .push, "New commits pushed", "\(pr.head.ref) is now at \(pr.head.sha.prefix(7))"))
        } else {
            let was = CIState(rawValue: old.checks) ?? .none
            if was.isActive && !checkState.isActive && checkState != .none {
                let passed = checkState == .success || checkState == .skipped || checkState == .neutral
                out.append(event(f, passed ? .workflowSucceeded : .workflowFailed, passed ? "Checks passed" : "Checks failed",
                                 "\(checks.count) check\(checks.count == 1 ? "" : "s") on \(pr.head.ref)"))
            }
        }
        return (f, out, false)
    }
}
