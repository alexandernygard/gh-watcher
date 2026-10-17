import SwiftUI

/// ⌘K: fuzzy jump to any section, repository, pull request, issue or workflow run.
struct QuickOpenView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    struct Item: Identifiable {
        enum Kind: String { case section = "Go", repo = "Repository", tab = "Tab", pr = "Pull Request", issue = "Issue", run = "Run" }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let icon: AnyView
        /// Extra text that matches but isn't shown (e.g. "#123", branch names).
        var keywords = ""
        var url: URL?
        var rank = 0
        let go: @MainActor () -> Void
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Jump to repo, PR, issue or run…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { activate(results, inBrowser: false) }
                    .onKeyPress(.downArrow) { move(1, results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, results.count); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        activate(results, inBrowser: true)
                        return .handled
                    }
                    .onKeyPress(keys: [.init("n"), .init("p")], phases: [.down, .repeat]) { press in
                        guard press.modifiers == .control else { return .ignored }
                        move(press.key == .init("n") ? 1 : -1, results.count)
                        return .handled
                    }
            }
            .padding(14)
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 200)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == highlighted)
                                    .id(index)
                                    .onTapGesture { highlighted = index; activate(results, inBrowser: false) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(results.count) * 46 + 12, 420))
                    .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "navigate")
                hint("↩", "open")
                hint("⌘↩", "open on GitHub")
                hint("esc", "close")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 620)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .onExitCommand { dismiss() }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            item.icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(item.kind.rawValue).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func activate(_ results: [Item], inBrowser: Bool) {
        guard results.indices.contains(highlighted) else { return }
        let item = results[highlighted]
        dismiss()
        if inBrowser, let url = item.url { NSWorkspace.shared.open(url) } else { item.go() }
    }

    // MARK: Matching

    private var results: [Item] {
        let items = allItems
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return Array(items.filter { $0.kind == .section || $0.rank > 0 }.prefix(40))
        }
        let scored = items.compactMap { item -> (Item, Int)? in
            guard let s = Fuzzy.score(q, "\(item.title) \(item.subtitle) \(item.keywords)") else { return nil }
            return (item, s + item.rank * 4 + (item.kind == .tab ? -6 : 0))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
    }

    private var allItems: [Item] {
        var out: [Item] = []
        func icon(_ name: String, _ color: Color = .secondary) -> AnyView { AnyView(Image(systemName: name).foregroundStyle(color)) }

        let sections: [(String, String, SidebarItem)] = [
            ("Overview", "square.grid.2x2", .overview), ("Inbox", "tray", .inbox), ("My Pull Requests", "arrow.triangle.pull", .myPRs),
            ("Review Requests", "eye", .reviews), ("Live Feed", "dot.radiowaves.left.and.right", .feed),
        ]
        for (title, symbol, item) in sections {
            out.append(Item(id: "section:\(title)", kind: .section, title: title, subtitle: "", icon: icon(symbol)) { store.selection = item })
        }

        for s in store.watchedStores {
            out.append(Item(id: "repo:\(s.fullName)", kind: .repo, title: s.fullName, subtitle: s.repo?.description ?? "",
                            icon: AnyView(CIStatusIcon(state: s.ciState)), url: s.webURL, rank: 1) { store.show(repo: s.fullName, tab: .overview) })
            for tab in RepoTab.allCases where tab != .overview {
                out.append(Item(id: "tab:\(s.fullName):\(tab)", kind: .tab, title: "\(s.fullName) › \(tab.title)", subtitle: "",
                                icon: icon(tab.symbol), url: s.webURL) { store.show(repo: s.fullName, tab: tab) })
            }
            for pr in s.prs {
                out.append(prItem(pr, rank: pr.author == store.me?.login ? 1 : 0) {
                    s.selectedPR = pr.id
                    store.show(repo: s.fullName, tab: .pulls)
                })
            }
            for issue in s.issues {
                out.append(Item(id: "issue:\(s.fullName)#\(issue.number)", kind: .issue, title: issue.title,
                                subtitle: "\(s.fullName)#\(issue.number) · \(issue.user?.login ?? "")",
                                icon: icon("smallcircle.filled.circle", .ghGreen), keywords: "#\(issue.number) \(issue.number)", url: issue.htmlUrl) {
                    s.selectedIssue = issue.id
                    store.show(repo: s.fullName, tab: .issues)
                })
            }
            for run in s.runs.prefix(12) {
                out.append(Item(id: "run:\(run.id)", kind: .run, title: "\(run.workflowName) #\(run.runNumber) · \(run.headBranch ?? "")",
                                subtitle: "\(s.fullName) · \(run.state.label.lowercased()) · \(run.displayTitle ?? "")",
                                icon: AnyView(CIStatusIcon(state: run.state)), keywords: run.event, url: run.htmlUrl,
                                rank: run.isActive || run.state == .failure ? 1 : 0) {
                    s.selectedRun = run.id
                    store.show(repo: s.fullName, tab: .actions)
                })
            }
        }

        // PRs in repos you don't watch (your own and review requests).
        let known = Set(out.map(\.id))
        for (pr, section) in store.reviewRequests.map({ ($0, SidebarItem.reviews) }) + store.myPRs.map({ ($0, SidebarItem.myPRs) })
        where !known.contains("pr:\(pr.id)") {
            out.append(prItem(pr, rank: 2) {
                store.collectionSelection = pr.id
                store.selection = section
            })
        }

        let watched = Set(store.prefs.watched)
        for repo in store.allRepos where !watched.contains(repo.fullName) && repo.archived != true {
            out.append(Item(id: "repo:\(repo.fullName)", kind: .repo, title: repo.fullName, subtitle: "Not watched · open to start watching",
                            icon: icon("eye.slash"), url: repo.htmlUrl, rank: -1) { store.show(repo: repo.fullName) })
        }
        return out
    }

    private func prItem(_ pr: PRItem, rank: Int, go: @escaping @MainActor () -> Void) -> Item {
        Item(id: "pr:\(pr.id)", kind: .pr, title: pr.title, subtitle: "\(pr.repo)#\(pr.number) · \(pr.author) · \(pr.headRef)",
             icon: AnyView(PRIcon(state: pr.state, isDraft: pr.isDraft)), keywords: "#\(pr.number) \(pr.number)", url: pr.url, rank: rank, go: go)
    }
}

enum Fuzzy {
    /// Subsequence match, case-insensitive. Higher is better; nil means no match.
    /// Contiguous runs and matches at word starts score more; whole-word prefixes score most.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var score = 0
        var qi = 0
        var lastMatch = -2
        var firstMatch = -1
        for (ti, ch) in t.enumerated() where qi < q.count {
            if q[qi] == " " { qi += 1; if qi == q.count { break } }
            guard ch == q[qi] else { continue }
            if firstMatch < 0 { firstMatch = ti }
            let wordStart = ti == 0 || " /#-_.›·".contains(t[ti - 1])
            score += 1
            if ti == lastMatch + 1 { score += 4 }
            if wordStart { score += 6 }
            lastMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        if text.lowercased().contains(query.lowercased()) { score += 15 }
        return score - min(firstMatch, 20) / 4
    }
}
