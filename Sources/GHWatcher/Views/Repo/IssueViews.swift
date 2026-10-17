import SwiftUI

struct IssueRow: View {
    let issue: Issue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.isOpen ? "smallcircle.filled.circle" : "checkmark.circle")
                .foregroundStyle(issue.isOpen ? Color.ghGreen : issue.stateReason == "not_planned" ? .secondary : .ghPurple)
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).fontWeight(.medium).lineLimit(2)
                HStack(spacing: 6) {
                    Text("#\(issue.number)").monospacedDigit()
                    AvatarView(url: issue.user?.avatarUrl, size: 14)
                    Text(issue.user?.login ?? "")
                    Text("·").foregroundStyle(.tertiary)
                    Ago(date: issue.updatedAt)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !issue.labels.isEmpty || issue.milestone != nil {
                    HStack(spacing: 4) {
                        if let m = issue.milestone { Chip(text: m.title, systemImage: "signpost.right") }
                        ForEach(issue.labels.prefix(4), id: \.name) { LabelChip(name: $0.name, hex: $0.color ?? "8b949e") }
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: -4) {
                    ForEach((issue.assignees ?? []).prefix(3)) { AvatarView(url: $0.avatarUrl, size: 16) }
                }
                if issue.comments > 0 {
                    Label("\(issue.comments)", systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct RepoIssuesView: View {
    @Environment(AppStore.self) private var store
    let repoStore: RepoStore
    @State private var selection: Issue.ID?
    @State private var showClosed = false
    @State private var search = ""
    @State private var label: String?
    @State private var showNew = false

    private var source: [Issue] { showClosed ? repoStore.closedIssues : repoStore.issues }

    private var list: [Issue] {
        source.filter { issue in
            (search.isEmpty || issue.title.localizedCaseInsensitiveContains(search) || "\(issue.number)".hasPrefix(search)) &&
            (label == nil || issue.labels.contains { $0.name == label })
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("", selection: $showClosed) {
                        Text("Open \(repoStore.issues.count)").tag(false)
                        Text("Closed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Menu {
                        Button("Any label") { label = nil }
                        Divider()
                        ForEach(Array(Set(source.flatMap { $0.labels.map(\.name) })).sorted(), id: \.self) { name in
                            Button(name) { label = name }
                        }
                    } label: {
                        Image(systemName: label == nil ? "tag" : "tag.fill")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    TextField("Filter", text: $search).textFieldStyle(.roundedBorder)
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                        .help("New issue")
                }
                .padding(10)
                Divider()
                if list.isEmpty {
                    ContentUnavailableView(showClosed ? "No closed issues" : "No open issues", systemImage: "checkmark.circle")
                } else {
                    List(list, selection: $selection) { issue in
                        IssueRow(issue: issue).tag(issue.id)
                            .contextMenu {
                                Button("Open in Browser") { NSWorkspace.shared.open(issue.htmlUrl) }
                                Button("Copy URL") { copyToPasteboard(issue.htmlUrl.absoluteString) }
                            }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 400, maxWidth: 560)

            Group {
                if let issue = list.first(where: { $0.id == selection }) {
                    IssueDetailView(repo: repoStore.fullName, issue: issue).id(issue.id)
                } else {
                    ContentUnavailableView("Select an issue", systemImage: "smallcircle.filled.circle")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: showClosed) {
            if showClosed, let client = store.client { await repoStore.loadClosed(client: client) }
        }
        .sheet(isPresented: $showNew) {
            NewIssueSheet(repoStore: repoStore).environment(store)
        }
    }
}

struct IssueDetailView: View {
    @Environment(AppStore.self) private var store
    let repo: String
    @State var issue: Issue
    @State private var comments: [IssueComment] = []
    @State private var comment = ""
    @State private var runner = ActionRunner()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = runner.error { ErrorBanner(message: error) }
                    TimelineCard(author: GQLActor(login: issue.user?.login ?? "ghost", avatarUrl: issue.user?.avatarUrl),
                                 date: issue.createdAt, badge: "opened") {
                        if let body = issue.body, !body.isEmpty {
                            MarkdownView(text: body)
                        } else {
                            Text("No description provided.").foregroundStyle(.secondary).italic()
                        }
                    }
                    ForEach(comments) { c in
                        TimelineCard(author: GQLActor(login: c.user?.login ?? "ghost", avatarUrl: c.user?.avatarUrl),
                                     date: c.createdAt, badge: "commented") {
                            MarkdownView(text: c.body ?? "")
                        }
                    }
                    CommentComposer(text: $comment, isSending: runner.isRunning) {
                        let body = comment
                        perform { client in
                            try await client.comment(repo, number: issue.number, body: body)
                            await MainActor.run { comment = "" }
                        }
                    }
                }
                .padding(16)
            }
        }
        .task(id: issue.updatedAt) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(issue.title).font(.title2.bold()).textSelection(.enabled)
                Text("#\(issue.number)").font(.title2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: issue.isOpen ? "smallcircle.filled.circle" : "checkmark.circle")
                    Text(issue.isOpen ? "Open" : "Closed")
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(.white)
                .background((issue.isOpen ? Color.ghGreen : .ghPurple).gradient, in: Capsule())
                Text("\(issue.user?.login ?? "") opened this").foregroundStyle(.secondary)
                Ago(date: issue.createdAt).foregroundStyle(.secondary)
                Text("· \(issue.comments) comments").foregroundStyle(.secondary)
                Spacer()
                if runner.isRunning { ProgressView().controlSize(.small) }
                if issue.isOpen {
                    Menu {
                        Button("Close as Completed") { setState(open: false, reason: "completed") }
                        Button("Close as Not Planned") { setState(open: false, reason: "not_planned") }
                    } label: {
                        Label("Close", systemImage: "checkmark.circle")
                    } primaryAction: {
                        setState(open: false, reason: "completed")
                    }
                    .fixedSize()
                } else {
                    Button("Reopen") { setState(open: true, reason: nil) }
                }
                Button { NSWorkspace.shared.open(issue.htmlUrl) } label: { Image(systemName: "safari") }
                    .help("Open on GitHub")
            }
            .font(.callout)
            if !issue.labels.isEmpty || !(issue.assignees ?? []).isEmpty {
                HStack(spacing: 6) {
                    ForEach(issue.labels, id: \.name) { LabelChip(name: $0.name, hex: $0.color ?? "8b949e") }
                    Spacer()
                    ForEach(issue.assignees ?? []) { user in
                        HStack(spacing: 4) { AvatarView(url: user.avatarUrl, size: 16); Text(user.login).font(.caption) }
                    }
                }
            }
        }
        .padding(16)
    }

    private func load() async {
        guard let client = store.client else { return }
        comments = (try? await client.issueComments(repo, number: issue.number)) ?? comments
    }

    private func setState(open: Bool, reason: String?) {
        perform { client in try await client.setIssueState(repo, number: issue.number, open: open, reason: reason) }
    }

    private func perform(_ work: @escaping (GitHubClient) async throws -> Void) {
        guard let client = store.client else { return }
        runner.run {
            try await work(client)
            issue = try await client.issue(repo, number: issue.number)
            await load()
            store.repoStores[repo]?.markIssuesDirty()
        }
    }
}

struct NewIssueSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let repoStore: RepoStore
    @State private var title = ""
    @State private var bodyText = ""
    @State private var labels: [GQLLabel] = []
    @State private var selectedLabels: Set<String> = []
    @State private var assignMe = false
    @State private var runner = ActionRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New issue in \(repoStore.fullName)", systemImage: "smallcircle.filled.circle").font(.title3.bold())
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(.title3)
            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
            if !labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(labels, id: \.name) { label in
                            LabelChip(name: label.name, hex: label.color)
                                .opacity(selectedLabels.contains(label.name) ? 1 : 0.45)
                                .overlay(alignment: .topTrailing) {
                                    if selectedLabels.contains(label.name) {
                                        Image(systemName: "checkmark.circle.fill").font(.caption2).offset(x: 4, y: -4)
                                    }
                                }
                                .onTapGesture {
                                    if selectedLabels.contains(label.name) { selectedLabels.remove(label.name) } else { selectedLabels.insert(label.name) }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Toggle("Assign to me", isOn: $assignMe)
            if let error = runner.error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Issue") {
                    guard let client = store.client else { return }
                    let assignees = assignMe ? [store.me?.login].compactMap { $0 } : []
                    runner.run {
                        let issue = try await client.createIssue(repoStore.fullName, title: title, body: bodyText,
                                                                 labels: Array(selectedLabels), assignees: assignees)
                        repoStore.markIssuesDirty()
                        NSWorkspace.shared.open(issue.htmlUrl)
                        dismiss()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || runner.isRunning)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            if let client = store.client { labels = (try? await client.labels(repoStore.fullName)) ?? [] }
        }
    }
}

struct NewPRSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let repoStore: RepoStore
    var initialHead: String? = nil
    @State private var head = ""
    @State private var base = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var draft = false
    @State private var runner = ActionRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New pull request in \(repoStore.fullName)", systemImage: "arrow.triangle.pull").font(.title3.bold())
            HStack {
                Picker("Base", selection: $base) {
                    ForEach(repoStore.branches) { Text($0.name).tag($0.name) }
                }
                Image(systemName: "arrow.left")
                Picker("Compare", selection: $head) {
                    ForEach(repoStore.branches) { Text($0.name).tag($0.name) }
                }
            }
            if repoStore.branchesLoading && repoStore.branches.isEmpty { ProgressView("Loading branches…").controlSize(.small) }
            if let branch = repoStore.branches.first(where: { $0.name == head }), let pr = branch.associatedPullRequests?.items.first {
                Label("There is already an open pull request for this branch: #\(pr.number) \(pr.title)", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(.title3)
            TextEditor(text: $bodyText)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
            Toggle("Create as draft", isOn: $draft)
            if let error = runner.error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft ? "Create Draft" : "Create Pull Request") {
                    guard let client = store.client else { return }
                    runner.run {
                        let pr = try await client.createPR(repoStore.fullName, title: title, body: bodyText, head: head, base: base, draft: draft)
                        repoStore.markPRsDirty()
                        NSWorkspace.shared.open(pr.htmlUrl)
                        dismiss()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || head.isEmpty || base.isEmpty || head == base || runner.isRunning)
            }
        }
        .padding(20)
        .frame(width: 580)
        .task {
            base = repoStore.defaultBranch
            head = initialHead ?? repoStore.branches.first { $0.name != base }?.name ?? ""
            if title.isEmpty && !head.isEmpty { title = Self.title(from: head) }
            if repoStore.branches.isEmpty, let client = store.client {
                await repoStore.loadBranches(client: client)
                if head.isEmpty { head = repoStore.branches.first { $0.name != base }?.name ?? "" }
            }
        }
        .onChange(of: head) { _, new in
            if title.isEmpty || title == Self.title(from: oldHead) { title = Self.title(from: new) }
            oldHead = new
        }
    }

    @State private var oldHead = ""

    static func title(from branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
