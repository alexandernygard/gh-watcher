import SwiftUI

struct RepoDetailView: View {
    @Environment(AppStore.self) private var store
    @Bindable var repoStore: RepoStore
    @State private var showNewIssue = false
    @State private var showNewPR = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = repoStore.lastError {
                ErrorBanner(message: error).padding(.horizontal, 12).padding(.top, 8)
            }
            Group {
                switch repoStore.tab {
                case .overview: RepoOverviewView(repoStore: repoStore)
                case .graph: RepoGraphView(repoStore: repoStore)
                case .pulls: RepoPullRequestsView(repoStore: repoStore)
                case .issues: RepoIssuesView(repoStore: repoStore)
                case .actions: RepoActionsView(repoStore: repoStore)
                case .activity: RepoActivityView(repoStore: repoStore)
                case .branches: RepoBranchesView(repoStore: repoStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(repoStore.name)
        .navigationSubtitle(repoStore.owner)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $repoStore.tab) {
                    ForEach(RepoTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help(repoStore.tab.title)
            }
            ToolbarItemGroup {
                if repoStore.isPolling { ProgressView().controlSize(.small) }
                Menu {
                    Button("New Issue…") { showNewIssue = true }
                    Button("New Pull Request…") { showNewPR = true }
                } label: {
                    Label("New", systemImage: "plus")
                }
                Button { repoStore.markAllDirty() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh now")
                Button { NSWorkspace.shared.open(repoStore.webURL) } label: { Label("Open on GitHub", systemImage: "safari") }
                    .help("Open on GitHub")
            }
        }
        .onChange(of: repoStore.tab) { repoStore.nextPoll = .distantPast }
        .sheet(isPresented: $showNewIssue) { NewIssueSheet(repoStore: repoStore).environment(store) }
        .sheet(isPresented: $showNewPR) { NewPRSheet(repoStore: repoStore).environment(store) }
    }
}

struct RepoOverviewView: View {
    @Environment(AppStore.self) private var store
    let repoStore: RepoStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        ciCard
                        prsCard
                        issuesCard
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        activityCard
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .frame(maxWidth: 1300)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        let repo = repoStore.repo
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AvatarView(url: repo?.owner.avatarUrl, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(repoStore.fullName).font(.title.bold())
                        if repo?.isPrivate == true { Chip(text: "Private", systemImage: "lock.fill") }
                        if repo?.archived == true { Chip(text: "Archived", color: .ghAmber, systemImage: "archivebox") }
                        if repo?.fork == true { Chip(text: "Fork", systemImage: "tuningfork") }
                    }
                    if let d = repo?.description { Text(d).foregroundStyle(.secondary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        CIStatusIcon(state: repoStore.ciState, size: 16)
                        Text(repoStore.ciState.label).fontWeight(.semibold)
                    }
                    if let polled = repoStore.lastPolled {
                        HStack(spacing: 3) { Text("Updated"); Ago(date: polled) }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let topics = repo?.topics, !topics.isEmpty {
                HStack(spacing: 5) {
                    ForEach(topics.prefix(10), id: \.self) { Chip(text: $0, color: .ghBlue) }
                }
            }
            HStack(spacing: 18) {
                stat("star", "\(repo?.stargazersCount ?? 0)", "stars")
                stat("tuningfork", "\(repo?.forksCount ?? 0)", "forks")
                stat("eye", "\(repo?.subscribersCount ?? repo?.watchersCount ?? 0)", "watching")
                stat("arrow.triangle.branch", repoStore.defaultBranch, "default")
                if let lang = repo?.language { stat("chevron.left.forwardslash.chevron.right", lang, "") }
                if let pushed = repo?.pushedAt {
                    Label { HStack(spacing: 3) { Text("Pushed"); Ago(date: pushed) } } icon: { Image(systemName: "arrow.up.circle") }
                }
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func stat(_ symbol: String, _ value: String, _ label: String) -> some View {
        Label {
            HStack(spacing: 3) {
                Text(value).foregroundStyle(.primary).fontWeight(.semibold)
                if !label.isEmpty { Text(label) }
            }
        } icon: { Image(systemName: symbol) }
    }

    private var ciCard: some View {
        Card("CI on \(repoStore.defaultBranch)", systemImage: "gearshape.2", trailing: {
            Button("All runs") { repoStore.tab = .actions }.buttonStyle(.link)
        }) {
            if repoStore.defaultBranchRuns.isEmpty {
                Text("No workflow runs on the default branch yet.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(repoStore.defaultBranchRuns) { run in
                HStack(spacing: 10) {
                    CIStatusIcon(state: run.state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.workflowName).fontWeight(.medium)
                        Text(run.displayTitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Ago(date: run.updatedAt).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { NSWorkspace.shared.open(run.htmlUrl) }
            }
            if !repoStore.activeRuns.isEmpty {
                Divider()
                Label("\(repoStore.activeRuns.count) running on other branches", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(Color.ghAmber)
            }
        }
    }

    private var prsCard: some View {
        Card("Open pull requests", systemImage: "arrow.triangle.pull", trailing: {
            Button("See all \(repoStore.prs.count)") { repoStore.tab = .pulls }.buttonStyle(.link)
        }) {
            if repoStore.prs.isEmpty { Text("None open.").foregroundStyle(.secondary).font(.callout) }
            ForEach(repoStore.prs.prefix(5)) { pr in
                PRRow(pr: pr)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(pr.url) }
            }
        }
    }

    private var issuesCard: some View {
        Card("Recent issues", systemImage: "smallcircle.filled.circle", trailing: {
            Button("See all \(repoStore.issues.count)") { repoStore.tab = .issues }.buttonStyle(.link)
        }) {
            if repoStore.issues.isEmpty { Text("No open issues.").foregroundStyle(.secondary).font(.callout) }
            ForEach(repoStore.issues.prefix(5)) { issue in
                IssueRow(issue: issue)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(issue.htmlUrl) }
            }
        }
    }

    private var activityCard: some View {
        Card("Recent activity", systemImage: "waveform.path.ecg", trailing: {
            Button("See all") { repoStore.tab = .activity }.buttonStyle(.link)
        }) {
            if repoStore.events.isEmpty { Text("Nothing recent.").foregroundStyle(.secondary).font(.callout) }
            ForEach(repoStore.events.prefix(14)) { event in
                EventRow(event: event, repoURL: repoStore.webURL)
            }
        }
    }
}
