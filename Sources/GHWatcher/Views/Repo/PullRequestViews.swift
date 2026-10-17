import SwiftUI

struct PRRow: View {
    let pr: PRItem
    var showRepo = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PRIcon(state: pr.state, isDraft: pr.isDraft).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(pr.title).fontWeight(.medium).lineLimit(2)
                HStack(spacing: 6) {
                    if showRepo { Text(pr.repo).foregroundStyle(.secondary) }
                    Text("#\(pr.number)").foregroundStyle(.secondary).monospacedDigit()
                    AvatarView(url: pr.authorAvatar, size: 14)
                    Text(pr.author).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Ago(date: pr.updatedAt).foregroundStyle(.secondary)
                }
                .font(.caption)
                HStack(spacing: 5) {
                    BranchChip(name: pr.headRef, color: .secondary)
                    ReviewDecisionBadge(decision: pr.reviewDecision)
                    if pr.mergeable == "CONFLICTING" { Chip(text: "Conflicts", color: .ghRed, systemImage: "exclamationmark.triangle") }
                    ForEach(pr.labels.prefix(3), id: \.name) { LabelChip(name: $0.name, hex: $0.color) }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                CIStatusIcon(state: pr.checkState)
                if pr.commentCount > 0 {
                    Label("\(pr.commentCount)", systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Cross-repo PR list (My PRs, Review requests) with a detail pane.
struct PRCollectionView: View {
    @Environment(AppStore.self) private var store
    let title: String
    let subtitle: String
    let prs: [PRItem]
    let emptySymbol: String
    @State private var selection: PRItem.ID?

    var body: some View {
        HSplitView {
            Group {
                if prs.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: emptySymbol, description: Text(subtitle))
                } else {
                    List(selection: $selection) {
                        ForEach(Dictionary(grouping: prs, by: \.repo).sorted { $0.key < $1.key }, id: \.key) { repo, items in
                            Section(repo) {
                                ForEach(items) { pr in PRRow(pr: pr).tag(pr.id) }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)

            Group {
                if let pr = prs.first(where: { $0.id == selection }) {
                    PRDetailView(repo: pr.repo, number: pr.number, updatedAt: pr.updatedAt).id(pr.id)
                } else {
                    ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .onAppear { if selection == nil { selection = prs.first?.id } }
    }
}

/// Per-repo PR tab.
struct RepoPullRequestsView: View {
    @Environment(AppStore.self) private var store
    let repoStore: RepoStore
    @State private var selection: PRItem.ID?
    @State private var showClosed = false
    @State private var search = ""
    @State private var onlyMine = false

    private var list: [PRItem] {
        (showClosed ? repoStore.closedPRs : repoStore.prs).filter { pr in
            (search.isEmpty || pr.title.localizedCaseInsensitiveContains(search) || "\(pr.number)".hasPrefix(search) || pr.author.localizedCaseInsensitiveContains(search)) &&
            (!onlyMine || pr.author == store.me?.login)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("", selection: $showClosed) {
                        Text("Open \(repoStore.prs.count)").tag(false)
                        Text("Closed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Toggle(isOn: $onlyMine) { Image(systemName: "person") }
                        .toggleStyle(.button).help("Only mine")
                    TextField("Filter", text: $search).textFieldStyle(.roundedBorder)
                }
                .padding(10)
                Divider()
                if list.isEmpty {
                    ContentUnavailableView(showClosed ? "No closed pull requests" : "No open pull requests", systemImage: "arrow.triangle.pull")
                } else {
                    List(list, selection: $selection) { pr in
                        PRRow(pr: pr).tag(pr.id)
                            .contextMenu {
                                Button("Open in Browser") { NSWorkspace.shared.open(pr.url) }
                                Button("Copy Branch Name") { copyToPasteboard(pr.headRef) }
                                Button("Copy URL") { copyToPasteboard(pr.url.absoluteString) }
                            }
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)

            Group {
                if let pr = list.first(where: { $0.id == selection }) {
                    PRDetailView(repo: repoStore.fullName, number: pr.number, updatedAt: pr.updatedAt).id(pr.id)
                } else {
                    ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: showClosed) {
            if showClosed, let client = store.client { await repoStore.loadClosed(client: client) }
        }
    }
}

// MARK: - Detail

struct PRDetailView: View {
    @Environment(AppStore.self) private var store
    let repo: String
    let number: Int
    let updatedAt: Date

    enum Section: String, CaseIterable { case conversation = "Conversation", commits = "Commits", checks = "Checks", files = "Files" }

    @State private var pr: GQLPR?
    @State private var loading = true
    @State private var error: String?
    @State private var section: Section = .conversation
    @State private var comment = ""
    @State private var runner = ActionRunner()
    @State private var confirmMerge: String?

    var body: some View {
        Group {
            if let pr {
                content(pr)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Couldn't load pull request", systemImage: "exclamationmark.triangle", description: Text(error ?? ""))
            }
        }
        .task(id: updatedAt) { await load() }
        .task {
            // Keep checks fresh while they run.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if let pr, CIState(rollup: pr.checks?.items.first?.commit.statusCheckRollup?.state).isActive { await load() }
            }
        }
    }

    private func load() async {
        guard let client = store.client else { return }
        do {
            pr = try await client.pullRequestDetail(repo, number: number)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func perform(_ work: @escaping (GitHubClient) async throws -> Void) {
        guard let client = store.client else { return }
        runner.run {
            try await work(client)
            try? await Task.sleep(for: .milliseconds(600))
            await load()
            store.repoStores[repo]?.markPRsDirty()
        }
    }

    @ViewBuilder
    private func content(_ pr: GQLPR) -> some View {
        VStack(spacing: 0) {
            header(pr)
            Divider()
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { s in
                    Text(label(for: s, pr)).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = runner.error { ErrorBanner(message: error) }
                    switch section {
                    case .conversation: conversation(pr)
                    case .commits: commits(pr)
                    case .checks: checks(pr)
                    case .files: files(pr)
                    }
                }
                .padding(16)
            }
        }
        .confirmationDialog("Merge pull request #\(pr.number)?", isPresented: Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } })) {
            Button(mergeTitle(confirmMerge)) {
                let method = confirmMerge ?? "merge"
                perform { try await $0.merge(repo, number: number, method: method) }
            }
        } message: {
            Text("\(pr.headRefName) → \(pr.baseRefName)")
        }
    }

    private func label(for section: Section, _ pr: GQLPR) -> String {
        switch section {
        case .conversation: "Conversation \(pr.conversation?.items.count ?? 0)"
        case .commits: "Commits \(pr.commitsList?.items.count ?? 0)"
        case .checks: "Checks \(pr.checks?.items.first?.commit.statusCheckRollup?.contexts?.items.count ?? 0)"
        case .files: "Files \(pr.changedFiles)"
        }
    }

    private func mergeTitle(_ method: String?) -> String {
        switch method {
        case "squash": "Squash and Merge"
        case "rebase": "Rebase and Merge"
        default: "Create Merge Commit"
        }
    }

    private func header(_ pr: GQLPR) -> some View {
        let state = pr.mergedAt != nil ? "MERGED" : pr.state
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(pr.title).font(.title2.bold()).textSelection(.enabled)
                Text("#\(pr.number)").font(.title2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                PRStateBadge(state: state, isDraft: pr.isDraft)
                AvatarView(url: pr.author?.avatarUrl, size: 18)
                Text(pr.author?.login ?? "ghost").fontWeight(.semibold)
                Text("wants to merge").foregroundStyle(.secondary)
                BranchChip(name: pr.headRefName)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption)
                BranchChip(name: pr.baseRefName, color: .secondary)
                Spacer()
                DiffStat(additions: pr.additions, deletions: pr.deletions)
            }
            .font(.callout)

            HStack(spacing: 8) {
                CIStatusIcon(state: pr.item.checkState)
                Text(pr.item.checkState.label).font(.callout)
                ReviewDecisionBadge(decision: pr.reviewDecision)
                if pr.mergeable == "CONFLICTING" { Chip(text: "Merge conflicts", color: .ghRed, systemImage: "exclamationmark.triangle") }
                if pr.mergeStateStatus == "BEHIND" { Chip(text: "Behind base", color: .ghAmber, systemImage: "arrow.down") }
                ForEach(pr.labels?.items ?? [], id: \.name) { LabelChip(name: $0.name, hex: $0.color) }
                Spacer()
                actions(pr, state: state)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func actions(_ pr: GQLPR, state: String) -> some View {
        HStack(spacing: 6) {
            if runner.isRunning { ProgressView().controlSize(.small) }
            if state == "OPEN" {
                if pr.isDraft {
                    Button("Ready for Review") { perform { try await $0.markReady(prNodeID: pr.id) } }
                } else {
                    Menu {
                        Button("Create Merge Commit") { confirmMerge = "merge" }
                        Button("Squash and Merge") { confirmMerge = "squash" }
                        Button("Rebase and Merge") { confirmMerge = "rebase" }
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    } primaryAction: {
                        confirmMerge = "squash"
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glassProminent)
                    .tint(.ghGreen)
                    .fixedSize()
                    .disabled(pr.mergeable == "CONFLICTING")
                }
                Menu {
                    if pr.author?.login != store.me?.login {
                        Button("Approve") { perform { try await $0.review(repo, number: number, event: "APPROVE") } }
                        Divider()
                    }
                    if pr.mergeStateStatus == "BEHIND" {
                        Button("Update Branch") { perform { try await $0.updateBranch(repo, number: number) } }
                    }
                    Button("Copy Branch Name") { copyToPasteboard(pr.headRefName) }
                    Button("Copy Checkout Command") { copyToPasteboard("gh pr checkout \(pr.number) -R \(repo)") }
                    Divider()
                    Button("Close Pull Request", role: .destructive) { perform { try await $0.setPRState(repo, number: number, open: false) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            } else if state == "CLOSED" {
                Button("Reopen") { perform { try await $0.setPRState(repo, number: number, open: true) } }
            }
            Button { NSWorkspace.shared.open(pr.url) } label: { Image(systemName: "safari") }
                .help("Open on GitHub")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func conversation(_ pr: GQLPR) -> some View {
        TimelineCard(author: pr.author, date: pr.createdAt, badge: "opened") {
            if let body = pr.body, !body.isEmpty {
                MarkdownView(text: body)
            } else {
                Text("No description provided.").foregroundStyle(.secondary).italic()
            }
        }

        let items: [(Date, AnyView)] =
            (pr.conversation?.items ?? []).map { c in
                (c.createdAt, AnyView(TimelineCard(author: c.author, date: c.createdAt, badge: "commented") { MarkdownView(text: c.body) }))
            } +
            (pr.reviews?.items ?? []).compactMap { r in
                guard let date = r.submittedAt else { return nil }
                return (date, AnyView(ReviewCard(review: r)))
            }
        ForEach(Array(items.sorted { $0.0 < $1.0 }.enumerated()), id: \.offset) { _, item in
            item.1
        }

        CommentComposer(text: $comment, isSending: runner.isRunning) {
            let body = comment
            perform { client in
                try await client.comment(repo, number: number, body: body)
                await MainActor.run { comment = "" }
            }
        }
    }

    @ViewBuilder
    private func commits(_ pr: GQLPR) -> some View {
        VStack(spacing: 0) {
            ForEach((pr.commitsList?.items ?? []).reversed(), id: \.commit.oid) { wrap in
                let c = wrap.commit
                HStack(spacing: 10) {
                    AvatarView(url: c.author?.user?.avatarUrl, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.messageHeadline).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(c.author?.user?.login ?? c.author?.name ?? "")
                            Text("·")
                            Ago(date: c.committedDate)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    CIStatusIcon(state: CIState(rollup: c.statusCheckRollup?.state))
                    Text(c.oid.prefix(7)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    if let url = c.url {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func checks(_ pr: GQLPR) -> some View {
        let contexts = pr.checks?.items.first?.commit.statusCheckRollup?.contexts?.items ?? []
        if contexts.isEmpty {
            ContentUnavailableView("No checks", systemImage: "checklist")
        } else {
            let groups = Dictionary(grouping: contexts, by: { $0.workflowName ?? "Status checks" }).sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { name, items in
                Card(name, systemImage: "gearshape.2") {
                    VStack(spacing: 6) {
                        ForEach(items) { check in
                            HStack(spacing: 10) {
                                CIStatusIcon(state: check.ciState)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(check.title)
                                    if let d = check.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                if let duration = check.duration {
                                    Text(duration.durationString).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                if let link = check.link {
                                    Button("Details") { NSWorkspace.shared.open(link) }.buttonStyle(.link)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func files(_ pr: GQLPR) -> some View {
        VStack(spacing: 0) {
            ForEach(pr.files?.items ?? []) { file in
                HStack(spacing: 8) {
                    Image(systemName: fileSymbol(file.changeType))
                        .foregroundStyle(fileColor(file.changeType))
                    Text(file.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    DiffStat(additions: file.additions, deletions: file.deletions)
                }
                .padding(.vertical, 5)
                Divider()
            }
            Button("View full diff on GitHub") { NSWorkspace.shared.open(pr.url.appending(path: "files")) }
                .buttonStyle(.link)
                .padding(.top, 10)
        }
    }

    private func fileSymbol(_ change: String) -> String {
        switch change {
        case "ADDED": "plus.square.fill"
        case "DELETED": "minus.square.fill"
        case "RENAMED", "COPIED": "arrow.right.square.fill"
        default: "pencil.and.outline"
        }
    }

    private func fileColor(_ change: String) -> Color {
        switch change {
        case "ADDED": .ghGreen
        case "DELETED": .ghRed
        case "RENAMED", "COPIED": .ghBlue
        default: .ghAmber
        }
    }
}

struct TimelineCard<Content: View>: View {
    let author: GQLActor?
    let date: Date
    let badge: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: author?.avatarUrl, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(author?.login ?? "ghost").fontWeight(.semibold)
                    Text(badge).foregroundStyle(.secondary)
                    Ago(date: date).foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4))
                content.padding(12)
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
    }
}

struct ReviewCard: View {
    let review: GQLReview

    var body: some View {
        let (verb, color, icon): (String, Color, String) = switch review.state {
        case "APPROVED": ("approved these changes", .ghGreen, "checkmark.circle.fill")
        case "CHANGES_REQUESTED": ("requested changes", .ghRed, "exclamationmark.circle.fill")
        case "DISMISSED": ("review dismissed", .secondary, "xmark.circle")
        default: ("reviewed", .secondary, "eye.circle.fill")
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color).font(.title3)
                AvatarView(url: review.author?.avatarUrl, size: 18)
                Text(review.author?.login ?? "ghost").fontWeight(.semibold)
                Text(verb).foregroundStyle(.secondary)
                if let date = review.submittedAt { Ago(date: date).foregroundStyle(.secondary) }
            }
            .font(.callout)
            if !review.body.isEmpty {
                MarkdownView(text: review.body)
                    .padding(10)
                    .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.leading, 40)
    }
}

struct CommentComposer: View {
    @Binding var text: String
    let isSending: Bool
    var placeholder = "Leave a comment (Markdown supported)"
    let send: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 70, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
            Button(action: send) {
                Label("Comment", systemImage: "paperplane.fill")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(.top, 6)
    }
}
