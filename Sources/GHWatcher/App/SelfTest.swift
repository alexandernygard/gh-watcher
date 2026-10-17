import SwiftUI

/// `GHWatcher --selftest [owner/repo]` exercises every API path with the real client and exits.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }

    @MainActor
    static func run() async {
        func line(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
        guard let token = await GHCLI.token() else { line("FAIL: no gh token"); exit(1) }
        let client = GitHubClient(token: token)
        var failures = 0
        func check<T>(_ name: String, _ work: () async throws -> T, _ describe: (T) -> String) async -> T? {
            do {
                let value = try await work()
                line("ok   \(name): \(describe(value))")
                return value
            } catch {
                failures += 1
                line("FAIL \(name): \(error)")
                return nil
            }
        }

        let me = await check("user", { try await client.get("/user", as: GHUser.self).value }, { $0.login })
        let repos: [Repo]? = await check("repos", { try await client.getPaged("/user/repos", query: ["per_page": "100", "sort": "pushed"], maxPages: 1) }, { "\($0.count)" })
        let explicit = CommandLine.arguments.drop { $0 != "--selftest" }.dropFirst().first
        guard let repo = explicit ?? repos?.first?.fullName else { exit(1) }
        line("repo \(repo)")

        let store = RepoStore(fullName: repo)
        _ = await store.poll(client: client, me: me?.login)
        line("\(store.lastError == nil ? "ok  " : "FAIL") poll: runs=\(store.runs.count) events=\(store.events.count) prs=\(store.prs.count) issues=\(store.issues.count) ci=\(store.ciState) err=\(store.lastError ?? "-")")
        if store.lastError != nil { failures += 1 }

        let second = Date.now
        _ = await store.poll(client: client, me: me?.login)
        line("ok   second poll took \(String(format: "%.2f", Date.now.timeIntervalSince(second)))s (conditional requests)")

        await store.loadGraph(client: client)
        line("\(store.graph == nil ? "FAIL" : "ok  ") graph: rows=\(store.graph?.rows.count ?? 0) lanes=\(store.graph?.laneCount ?? 0)")
        await store.loadBranches(client: client)
        line("ok   branches: \(store.branches.count)")
        await store.loadClosed(client: client)
        line("ok   closed: prs=\(store.closedPRs.count) issues=\(store.closedIssues.count)")

        if let login = me?.login {
            let viewer = await check("viewerPRs", { try await client.viewerPRs(login: login) }, { "mine=\($0.mine.count) reviews=\($0.reviews.count)" })
            if let pr = viewer?.mine.first ?? store.prs.first ?? store.closedPRs.first {
                _ = await check("prDetail \(pr.repo)#\(pr.number)", { try await client.pullRequestDetail(pr.repo, number: pr.number) },
                                { "commits=\($0?.commitsList?.items.count ?? -1) files=\($0?.files?.items.count ?? -1) checks=\($0?.checks?.items.first?.commit.statusCheckRollup?.contexts?.items.count ?? 0)" })
            }
        }
        if let run = store.runs.first {
            _ = await check("jobs", { try await client.jobs(repo, runID: run.id) }, { "\($0.count)" })
        }
        if let run = store.runs.first {
            _ = await check("run", { try await client.run(repo, id: run.id) }, { "\($0.state)" })
        }
        if let failed = store.runs.first(where: { $0.state == .failure }),
           let jobs = await check("failed jobs", { try await client.jobs(repo, runID: failed.id) }, { "\($0.filter { $0.state == .failure }.count) failed" }),
           let job = jobs.first(where: { $0.state == .failure }) {
            if let raw = await check("jobLog \(job.name)", { try await client.jobLog(repo, jobID: job.id) }, { "\($0.count) bytes" }) {
                let log = JobLog(raw: raw)
                line("ok   parsed: lines=\(log.lines.count) errors=\(log.errorCount) excerpt=\(log.excerpt.count)")
                for l in log.excerpt.suffix(8) { line("     | \(l.level) \(l.text.prefix(110))") }
            }
        } else {
            line("--   no failed run in the latest \(store.runs.count) to test logs with")
        }
        if let pr = store.prs.first ?? store.closedPRs.first {
            if let rest = await check("pull #\(pr.number)", { try await client.pull(repo, number: pr.number) }, { "comments=\($0.comments ?? -1) review_comments=\($0.reviewComments ?? -1)" }) {
                _ = await check("reviews", { try await client.reviews(repo, number: pr.number) }, { "\($0.count)" })
                _ = await check("checkRuns", { try await client.checkRuns(repo, sha: rest.head.sha) }, { "\($0.count) → \(CIState.combine($0.map(\.state)))" })
            }
        }
        line("fuzzy: \(Fuzzy.score("clic", "cli/cli") ?? -1) \(Fuzzy.score("ghw act", "alex/gh-watcher › Actions") ?? -1) \(Fuzzy.score("zzz", "cli/cli") ?? -1)")
        if let sha = store.graph?.rows.first?.id {
            _ = await check("commit", { try await client.commit(repo, sha: sha) }, { "files=\($0.files?.count ?? 0)" })
        }
        _ = await check("workflows", { try await client.workflows(repo) }, { "\($0.count)" })
        _ = await check("labels", { try await client.labels(repo) }, { "\($0.count)" })
        _ = await check("notifications", { try await client.get("/notifications", as: [NotificationThread].self).value }, { "\($0.count)" })
        if let issue = store.issues.first ?? store.closedIssues.first {
            _ = await check("issueComments", { try await client.issueComments(repo, number: issue.number) }, { "\($0.count)" })
        }
        line(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `GHWatcher --snapshot <dir> [owner/repo]` renders the main screens offscreen to PNGs (for development).
enum Snapshot {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    @MainActor
    static func run() async {
        let args = Array(CommandLine.arguments.drop { $0 != "--snapshot" }.dropFirst())
        let dir = URL(fileURLWithPath: args.first ?? ".")
        let store = AppStore.shared
        await store.bootstrap()
        try? await Task.sleep(for: .seconds(14))
        let repo = args.dropFirst().first ?? store.prefs.watched.first ?? ""

        func shot<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) async {
            let host = NSHostingView(rootView: view().environment(store))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: 0), size: size),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(name.contains("graph") ? 10 : 4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
            print("wrote \(name)")
        }

        let size = CGSize(width: 1360, height: 860)
        store.selection = .overview
        await shot("overview", size: size) { RootView() }
        if let s = store.repoStores[repo] {
            store.selection = .repo(repo)
            for tab in [RepoTab.overview, .graph, .pulls, .actions, .issues, .branches] {
                s.tab = tab
                if tab == .actions { s.selectedRun = s.runs.first { $0.state == .failure }?.id ?? s.runs.first?.id }
                if tab == .graph, let client = store.client { await s.loadGraph(client: client) }
                await shot("repo-\(tab.rawValue)", size: size) { RootView() }
            }
        }
        store.selection = .inbox
        await shot("inbox", size: size) { RootView() }
        await shot("quickopen", size: CGSize(width: 620, height: 560)) { QuickOpenView() }
        await shot("menubar", size: CGSize(width: 380, height: 640)) { MenuBarView() }
        await shot("settings-notifications", size: CGSize(width: 680, height: 560)) { NotificationSettings() }
        exit(0)
    }
}
