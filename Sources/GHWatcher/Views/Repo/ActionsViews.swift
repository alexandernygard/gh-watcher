import SwiftUI

struct RepoActionsView: View {
    @Environment(AppStore.self) private var store
    @Bindable var repoStore: RepoStore
    @State private var workflowFilter: Int?
    @State private var branchFilter: String?
    @State private var workflows: [Workflow] = []

    private var list: [WorkflowRun] {
        repoStore.runs.filter { run in
            (workflowFilter == nil || run.workflowId == workflowFilter) &&
            (branchFilter == nil || run.headBranch == branchFilter)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("Workflow", selection: $workflowFilter) {
                        Text("All workflows").tag(Int?.none)
                        Divider()
                        ForEach(uniqueWorkflows, id: \.0) { id, name in Text(name).tag(Optional(id)) }
                    }
                    .labelsHidden()
                    Picker("Branch", selection: $branchFilter) {
                        Text("All branches").tag(String?.none)
                        Divider()
                        ForEach(Array(Set(repoStore.runs.compactMap(\.headBranch))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    Menu {
                        if workflows.isEmpty { Text("No workflows") }
                        ForEach(workflows.filter { $0.state == "active" }) { wf in
                            Button(wf.name) { dispatch(wf) }
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Run a workflow on \(repoStore.defaultBranch) (needs a workflow_dispatch trigger)")
                }
                .padding(10)
                Divider()
                if list.isEmpty {
                    ContentUnavailableView("No workflow runs", systemImage: "play.circle")
                } else {
                    List(list, selection: $repoStore.selectedRun) { run in
                        RunRow(run: run).tag(run.id)
                            .contextMenu {
                                Button("Open in Browser") { NSWorkspace.shared.open(run.htmlUrl) }
                                let follow = Follow(run: run, repo: repoStore.fullName)
                                Button(store.isFollowing(follow) ? "Stop Following" : "Notify When Finished") { store.toggleFollow(follow) }
                                Button("Copy URL") { copyToPasteboard(run.htmlUrl.absoluteString) }
                            }
                    }
                    .listKeyNavigation($repoStore.selectedRun, ids: list.map(\.id)) { id in
                        if let run = list.first(where: { $0.id == id }) { NSWorkspace.shared.open(run.htmlUrl) }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 420, maxWidth: 580)

            Group {
                if let run = repoStore.runs.first(where: { $0.id == repoStore.selectedRun }) {
                    RunDetailView(repoStore: repoStore, run: run).id(run.id)
                } else {
                    ContentUnavailableView("Select a workflow run", systemImage: "gearshape.2")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            if let client = store.client { workflows = (try? await client.workflows(repoStore.fullName)) ?? [] }
        }
        .onAppear { if repoStore.selectedRun == nil { repoStore.selectedRun = list.first?.id } }
    }

    private var uniqueWorkflows: [(Int, String)] {
        var seen = Set<Int>()
        return repoStore.runs.compactMap { seen.insert($0.workflowId).inserted ? ($0.workflowId, $0.workflowName) : nil }
            .sorted { $0.1 < $1.1 }
    }

    private func dispatch(_ wf: Workflow) {
        guard let client = store.client else { return }
        Task {
            do {
                try await client.dispatch(repoStore.fullName, workflowID: wf.id, ref: repoStore.defaultBranch)
                repoStore.markRunsChanged()
            } catch {
                repoStore.lastError = "Couldn't start \(wf.name): \(error.localizedDescription)"
            }
        }
    }
}

struct RunRow: View {
    let run: WorkflowRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CIStatusIcon(state: run.state, size: 15).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.displayTitle ?? run.workflowName).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
                    Text(run.workflowName).fontWeight(.medium)
                    Text("#\(run.runNumber)").monospacedDigit()
                    Text("·")
                    Text(run.event.replacingOccurrences(of: "_", with: " "))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let branch = run.headBranch { BranchChip(name: branch, color: .secondary) }
                    AvatarView(url: run.actor?.avatarUrl, size: 14)
                    Text(run.actor?.login ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Ago(date: run.createdAt).font(.caption).foregroundStyle(.secondary)
                if run.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(run.duration?.durationString ?? "").font(.caption.monospacedDigit()).foregroundStyle(Color.ghAmber)
                    }
                } else if let d = run.duration {
                    Text(d.durationString).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct RunDetailView: View {
    @Environment(AppStore.self) private var store
    let repoStore: RepoStore
    let run: WorkflowRun
    @State private var jobs: [Job] = []
    @State private var loading = true
    @State private var runner = ActionRunner()
    @State private var expanded: Set<Int> = []
    @State private var logsShown: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = runner.error { ErrorBanner(message: error) }
                    if loading && jobs.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
                    ForEach(jobs) { job in jobCard(job) }
                }
                .padding(16)
            }
        }
        .focusedSceneValue(\.focusedItem, FocusedItem(url: run.htmlUrl, branch: run.headBranch, follow: Follow(run: run, repo: repoStore.fullName)))
        .focusedSceneValue(\.runCommands, RunCommands(
            rerunFailed: !run.isActive && run.state == .failure ? { act { try await $0.rerun(repoStore.fullName, runID: run.id, failedOnly: true) } } : nil,
            rerunAll: run.isActive ? nil : { act { try await $0.rerun(repoStore.fullName, runID: run.id, failedOnly: false) } },
            cancel: run.isActive ? { act { try await $0.cancel(repoStore.fullName, runID: run.id) } } : nil
        ))
        .task(id: run.updatedAt) { await loadJobs() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if run.isActive || jobs.contains(where: { $0.state.isActive }) { await loadJobs() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CIStatusIcon(state: run.state, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.displayTitle ?? run.workflowName).font(.title3.bold()).lineLimit(2)
                    Text("\(run.workflowName) #\(run.runNumber)\(run.runAttempt.map { $0 > 1 ? " · attempt \($0)" : "" } ?? "")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if runner.isRunning { ProgressView().controlSize(.small) }
                if run.isActive {
                    Button(role: .destructive) { act { try await $0.cancel(repoStore.fullName, runID: run.id) } } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                } else {
                    Menu {
                        Button("Re-run All Jobs") { act { try await $0.rerun(repoStore.fullName, runID: run.id, failedOnly: false) } }
                        if run.state == .failure {
                            Button("Re-run Failed Jobs") { act { try await $0.rerun(repoStore.fullName, runID: run.id, failedOnly: true) } }
                        }
                    } label: {
                        Label("Re-run", systemImage: "arrow.clockwise")
                    } primaryAction: {
                        act { try await $0.rerun(repoStore.fullName, runID: run.id, failedOnly: run.state == .failure) }
                    }
                    .fixedSize()
                }
                FollowButton(follow: Follow(run: run, repo: repoStore.fullName), runActive: run.isActive)
                Button { NSWorkspace.shared.open(run.htmlUrl) } label: { Image(systemName: "safari") }.help("Open on GitHub")
            }
            HStack(spacing: 12) {
                if let branch = run.headBranch { BranchChip(name: branch) }
                Label(String(run.headSha.prefix(7)), systemImage: "number").font(.system(.caption, design: .monospaced))
                Label(run.event, systemImage: "bolt").font(.caption)
                HStack(spacing: 4) {
                    AvatarView(url: run.triggeringActor?.avatarUrl ?? run.actor?.avatarUrl, size: 14)
                    Text(run.triggeringActor?.login ?? run.actor?.login ?? "").font(.caption)
                }
                Spacer()
                Label { Ago(date: run.createdAt) } icon: { Image(systemName: "calendar") }.font(.caption)
                if let d = run.duration { Label(d.durationString, systemImage: "timer").font(.caption.monospacedDigit()) }
            }
            .foregroundStyle(.secondary)
            if let message = run.headCommit?.message, message.contains("\n") {
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
        }
        .padding(16)
    }

    private func jobCard(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(job.id) { expanded.remove(job.id) } else { expanded.insert(job.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded.contains(job.id) ? 90 : 0))
                        .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    CIStatusIcon(state: job.state, size: 15)
                    Text(job.name).fontWeight(.medium)
                    Spacer()
                    if let start = job.startedAt {
                        Text(((job.completedAt ?? .now).timeIntervalSince(start)).durationString)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !job.state.isActive {
                        Button {
                            if logsShown.contains(job.id) { logsShown.remove(job.id) } else { logsShown.insert(job.id); expanded.insert(job.id) }
                        } label: { Image(systemName: logsShown.contains(job.id) ? "text.alignleft.circle.fill" : "text.alignleft") }
                            .buttonStyle(.borderless).help(logsShown.contains(job.id) ? "Hide log" : "Show log")
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.contains(job.id) {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(job.steps ?? []) { step in
                        HStack(spacing: 10) {
                            CIStatusIcon(state: step.state, size: 11)
                            Text(step.name).font(.callout)
                            Spacer()
                            if let s = step.startedAt, let e = step.completedAt {
                                Text(e.timeIntervalSince(s).durationString).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(step.state == .failure ? Color.ghRed.opacity(0.08) : .clear)
                    }
                }
                .padding(.vertical, 6)
                if logsShown.contains(job.id) {
                    JobLogView(repo: repoStore.fullName, jobID: job.id, webURL: job.htmlUrl)
                        .padding([.horizontal, .bottom], 12)
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(job.state == .failure ? Color.ghRed.opacity(0.4) : .primary.opacity(0.07)))
    }

    private func loadJobs() async {
        guard let client = store.client else { return }
        if let fetched = try? await client.jobs(repoStore.fullName, runID: run.id) {
            if jobs.isEmpty {
                expanded = Set(fetched.filter { $0.state == .failure || $0.state.isActive }.map(\.id))
            }
            // Show why it failed without a click, the first time each job is seen failing.
            for job in fetched where job.state == .failure && !jobs.contains(where: { $0.id == job.id && $0.state == .failure }) {
                logsShown.insert(job.id)
                expanded.insert(job.id)
            }
            jobs = fetched
        }
        loading = false
    }

    private func act(_ work: @escaping (GitHubClient) async throws -> Void) {
        guard let client = store.client else { return }
        runner.run {
            try await work(client)
            try? await Task.sleep(for: .seconds(1))
            repoStore.markRunsChanged()
        }
    }
}

// MARK: - Activity

struct RepoActivityView: View {
    let repoStore: RepoStore

    var body: some View {
        if repoStore.events.isEmpty {
            ContentUnavailableView("No recent activity", systemImage: "waveform.path.ecg")
        } else {
            List(repoStore.events) { event in
                EventRow(event: event, repoURL: repoStore.webURL)
            }
            .listStyle(.inset)
        }
    }
}

struct EventRow: View {
    let event: RepoEvent
    let repoURL: URL

    var body: some View {
        let d = EventDescription(event, repoURL: repoURL)
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: event.actor.avatarUrl, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(event.actor.login).fontWeight(.semibold)
                    Text(d.verb).foregroundStyle(.secondary)
                    Text(d.object).fontWeight(.medium).lineLimit(1)
                }
                if let detail = d.detail, !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: d.symbol).foregroundStyle(d.color)
            Ago(date: event.createdAt).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(d.url) }
        .contextMenu { Button("Open in Browser") { NSWorkspace.shared.open(d.url) } }
    }
}

struct EventDescription {
    var verb = "did something in"
    var object = ""
    var detail: String?
    var symbol = "circle"
    var color: Color = .secondary
    var url: URL

    init(_ event: RepoEvent, repoURL: URL) {
        let p = event.payload
        url = repoURL
        let action = p["action"]?.string ?? ""
        switch event.type {
        case "PushEvent":
            let branch = p["ref"]?.string?.replacingOccurrences(of: "refs/heads/", with: "") ?? "a branch"
            let count = p["size"]?.int ?? p["commits"]?.array?.count
            verb = count.map { "pushed \($0) commit\($0 == 1 ? "" : "s") to" } ?? "pushed to"
            object = branch
            detail = p["commits"]?.array?.compactMap { $0["message"]?.string?.components(separatedBy: "\n").first }.suffix(3).joined(separator: "\n")
            symbol = "arrow.up.circle.fill"; color = .ghBlue
            if let head = p["head"]?.string { url = repoURL.appending(path: "commit/\(head)") }
        case "PullRequestEvent":
            let pr = p["pull_request"]
            let merged = pr?["merged"]?.bool == true
            verb = merged ? "merged" : "\(action)"
            object = "#\(p["number"]?.int ?? pr?["number"]?.int ?? 0) \(pr?["title"]?.string ?? "")"
            symbol = merged ? "arrow.triangle.merge" : "arrow.triangle.pull"
            color = merged ? .ghPurple : action == "closed" ? .ghRed : .ghGreen
            url = pr?["html_url"]?.url ?? repoURL.appending(path: "pull/\(p["number"]?.int ?? 0)")
        case "PullRequestReviewEvent":
            let pr = p["pull_request"]
            let state = p["review"]?["state"]?.string?.lowercased() ?? ""
            verb = state == "approved" ? "approved" : state == "changes_requested" ? "requested changes on" : "reviewed"
            object = "#\(pr?["number"]?.int ?? 0) \(pr?["title"]?.string ?? "")"
            detail = p["review"]?["body"]?.string
            symbol = "eye.fill"; color = state == "approved" ? .ghGreen : .ghAmber
            url = p["review"]?["html_url"]?.url ?? pr?["html_url"]?.url ?? repoURL
        case "PullRequestReviewCommentEvent", "IssueCommentEvent":
            let issue = p["issue"] ?? p["pull_request"]
            verb = "commented on"
            object = "#\(issue?["number"]?.int ?? 0) \(issue?["title"]?.string ?? "")"
            detail = p["comment"]?["body"]?.string
            symbol = "bubble.left.fill"; color = .secondary
            url = p["comment"]?["html_url"]?.url ?? issue?["html_url"]?.url ?? repoURL
        case "IssuesEvent":
            let issue = p["issue"]
            verb = "\(action) issue"
            object = "#\(issue?["number"]?.int ?? 0) \(issue?["title"]?.string ?? "")"
            symbol = action == "closed" ? "checkmark.circle.fill" : "smallcircle.filled.circle"
            color = action == "closed" ? .ghPurple : .ghGreen
            url = issue?["html_url"]?.url ?? repoURL
        case "CreateEvent":
            verb = "created \(p["ref_type"]?.string ?? "")"
            object = p["ref"]?.string ?? ""
            symbol = p["ref_type"]?.string == "tag" ? "tag.fill" : "arrow.triangle.branch"; color = .ghGreen
            if let ref = p["ref"]?.string { url = repoURL.appending(path: "tree/\(ref)") }
        case "DeleteEvent":
            verb = "deleted \(p["ref_type"]?.string ?? "")"
            object = p["ref"]?.string ?? ""
            symbol = "trash"; color = .ghRed
        case "ReleaseEvent":
            verb = "\(action) release"
            object = p["release"]?["name"]?.string ?? p["release"]?["tag_name"]?.string ?? ""
            symbol = "shippingbox.fill"; color = .ghPurple
            url = p["release"]?["html_url"]?.url ?? repoURL.appending(path: "releases")
        case "WatchEvent":
            verb = "starred"; object = "the repository"; symbol = "star.fill"; color = .ghAmber
            url = URL(string: "https://github.com/\(event.actor.login)") ?? repoURL
        case "ForkEvent":
            verb = "forked to"; object = p["forkee"]?["full_name"]?.string ?? ""; symbol = "tuningfork"
            url = p["forkee"]?["html_url"]?.url ?? repoURL
        case "MemberEvent":
            verb = "\(action) member"; object = p["member"]?["login"]?.string ?? ""; symbol = "person.badge.plus"
        case "GollumEvent":
            verb = "edited the wiki"; symbol = "book"
        case "PublicEvent":
            verb = "made the repository public"; symbol = "globe"
        default:
            verb = (event.type ?? "Event").replacingOccurrences(of: "Event", with: "").lowercased()
        }
    }
}

// MARK: - Branches

struct RepoBranchesView: View {
    @Environment(AppStore.self) private var store
    let repoStore: RepoStore
    @State private var search = ""
    @State private var newPRHead: String?

    private var list: [BranchNode] {
        repoStore.branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter branches", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Spacer()
                if repoStore.branchesLoading { ProgressView().controlSize(.small) }
                Text("\(repoStore.branches.count) branches").foregroundStyle(.secondary).font(.callout)
            }
            .padding(10)
            Divider()
            Table(list) {
                TableColumn("Branch") { branch in
                    HStack(spacing: 6) {
                        CIStatusIcon(state: CIState(rollup: branch.target?.statusCheckRollup?.state), size: 11)
                        Text(branch.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                        if branch.name == repoStore.defaultBranch { Chip(text: "default", color: .ghBlue) }
                        if branch.branchProtectionRule != nil { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Protected") }
                    }
                }
                .width(min: 200, ideal: 280)
                TableColumn("Last commit") { branch in
                    HStack(spacing: 6) {
                        AvatarView(url: branch.target?.author?.user?.avatarUrl, size: 16)
                        Text(branch.target?.messageHeadline ?? "").lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Updated") { branch in
                    if let date = branch.target?.committedDate { Ago(date: date).foregroundStyle(.secondary) }
                }
                .width(90)
                TableColumn("Behind | Ahead") { branch in
                    if let c = branch.compare, branch.name != repoStore.defaultBranch {
                        AheadBehindBar(ahead: c.behindBy, behind: c.aheadBy)
                    }
                }
                .width(150)
                TableColumn("Pull request") { branch in
                    if let pr = branch.associatedPullRequests?.items.first {
                        Button("#\(pr.number)") { NSWorkspace.shared.open(pr.url) }.buttonStyle(.link).help(pr.title)
                    } else if branch.name != repoStore.defaultBranch {
                        Button("Create PR") { newPRHead = branch.name }.buttonStyle(.link)
                    }
                }
                .width(90)
            }
            .contextMenu(forSelectionType: BranchNode.ID.self) { ids in
                if let name = ids.first {
                    Button("Open on GitHub") { NSWorkspace.shared.open(repoStore.webURL.appending(path: "tree/\(name)")) }
                    Button("Compare with \(repoStore.defaultBranch)") {
                        NSWorkspace.shared.open(repoStore.webURL.appending(path: "compare/\(repoStore.defaultBranch)...\(name)"))
                    }
                    Button("Copy Name") { copyToPasteboard(name) }
                    if name != repoStore.defaultBranch { Button("Create Pull Request…") { newPRHead = name } }
                }
            }
        }
        .onAppear {
            repoStore.branchesVisible = true
            if repoStore.branches.isEmpty, let client = store.client { Task { await repoStore.loadBranches(client: client) } }
        }
        .onDisappear { repoStore.branchesVisible = false }
        .sheet(item: Binding(get: { newPRHead.map { IdentifiedString(value: $0) } }, set: { newPRHead = $0?.value })) { head in
            NewPRSheet(repoStore: repoStore, initialHead: head.value).environment(store)
        }
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

struct AheadBehindBar: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        let scale = { (n: Int) -> CGFloat in n == 0 ? 0 : min(40, 4 + log2(CGFloat(n) + 1) * 7) }
        HStack(spacing: 4) {
            Text("\(behind)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            HStack(spacing: 1) {
                HStack { Spacer(minLength: 0); Capsule().fill(Color.secondary.opacity(0.5)).frame(width: scale(behind), height: 5) }.frame(width: 40)
                Rectangle().fill(.separator).frame(width: 1, height: 10)
                HStack { Capsule().fill(Color.ghBlue).frame(width: scale(ahead), height: 5); Spacer(minLength: 0) }.frame(width: 40)
            }
            Text("\(ahead)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
        }
        .help("\(behind) behind, \(ahead) ahead of the default branch")
    }
}
