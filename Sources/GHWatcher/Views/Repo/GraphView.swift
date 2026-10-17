import SwiftUI

enum GraphPalette {
    static let colors: [Color] = [
        .ghBlue, .ghPurple, Color(red: 0.95, green: 0.38, blue: 0.62), .ghAmber, Color(red: 0.13, green: 0.72, blue: 0.70),
        .ghGreen, Color(red: 0.42, green: 0.45, blue: 0.95), Color(red: 0.95, green: 0.52, blue: 0.25), .mint, .cyan,
    ]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

struct RepoGraphView: View {
    @Environment(AppStore.self) private var store
    let repoStore: RepoStore
    @State private var selection: String?
    @State private var search = ""
    @State private var branchFilter: String?

    private let rowHeight: CGFloat = 30
    private let laneWidth: CGFloat = 16

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let graph = repoStore.graph {
                    graphList(graph)
                } else if repoStore.graphLoading {
                    ProgressView("Building graph…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No commits", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if let sha = selection, let row = repoStore.graph?.rows.first(where: { $0.id == sha }) {
                    CommitInspector(repoStore: repoStore, row: row).id(sha)
                } else {
                    ContentUnavailableView("Select a commit", systemImage: "smallcircle.filled.circle",
                                           description: Text("Shows the latest commits across the most recently active branches."))
                }
            }
            .frame(minWidth: 240, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
        }
        .onAppear {
            repoStore.graphVisible = true
            if repoStore.graph == nil, let client = store.client { Task { await repoStore.loadGraph(client: client) } }
        }
        .onDisappear { repoStore.graphVisible = false }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search commits", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            Picker("Jump to", selection: $branchFilter) {
                Text("Jump to branch…").tag(String?.none)
                Divider()
                ForEach(repoStore.graph?.branchNames ?? [], id: \.self) { Text($0).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            Spacer()
            if repoStore.graphLoading { ProgressView().controlSize(.small) }
            if let graph = repoStore.graph {
                Text("\(graph.rows.count) commits · \(graph.branchNames.count) branches").font(.callout).foregroundStyle(.secondary)
            }
            Button {
                if let client = store.client { Task { await repoStore.loadGraph(client: client) } }
            } label: { Image(systemName: "arrow.clockwise") }
            .help("Reload graph")
        }
        .padding(10)
    }

    private func graphList(_ graph: CommitGraph) -> some View {
        let graphWidth = CGFloat(max(graph.laneCount, 1)) * laneWidth + 12
        let rows = graph.rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        let dimmed = !search.isEmpty && !(row.commit.message.localizedCaseInsensitiveContains(search) ||
                                                          row.commit.id.hasPrefix(search.lowercased()) ||
                                                          row.commit.authorName.localizedCaseInsensitiveContains(search))
                        GraphRowView(row: row, graphWidth: graphWidth, rowHeight: rowHeight, laneWidth: laneWidth,
                                     isSelected: selection == row.id, isDefault: { $0 == graph.defaultBranch },
                                     prForBranch: { branch in repoStore.prs.first { $0.headRef == branch } })
                            .opacity(dimmed ? 0.3 : 1)
                            .id(row.id)
                            .onTapGesture { selection = row.id }
                            .contextMenu {
                                if let url = row.commit.url { Button("Open Commit on GitHub") { NSWorkspace.shared.open(url) } }
                                Button("Copy SHA") { copyToPasteboard(row.commit.id) }
                                ForEach(row.branches, id: \.self) { b in
                                    Button("Open Branch \(b)") { NSWorkspace.shared.open(repoStore.webURL.appending(path: "tree/\(b)")) }
                                }
                            }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: branchFilter) { _, branch in
                guard let branch, let row = rows.first(where: { $0.branches.contains(branch) }) else { return }
                selection = row.id
                withAnimation { proxy.scrollTo(row.id, anchor: .center) }
            }
        }
    }
}

struct GraphRowView: View {
    let row: GraphRow
    let graphWidth: CGFloat
    let rowHeight: CGFloat
    let laneWidth: CGFloat
    let isSelected: Bool
    let isDefault: (String) -> Bool
    let prForBranch: (String) -> PRItem?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            GraphLanes(row: row, laneWidth: laneWidth, isHead: !row.branches.isEmpty)
                .frame(width: graphWidth, height: rowHeight)

            HStack(spacing: 5) {
                ForEach(row.branches, id: \.self) { branch in
                    let color = GraphPalette.color(row.color)
                    HStack(spacing: 3) {
                        Image(systemName: isDefault(branch) ? "star.fill" : "arrow.triangle.branch").font(.system(size: 8, weight: .bold))
                        Text(branch).lineLimit(1)
                        if let pr = prForBranch(branch) {
                            Text("#\(pr.number)").opacity(0.75)
                        }
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(color.gradient, in: Capsule())
                }
                ForEach(row.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Image(systemName: "tag.fill").font(.system(size: 8))
                        Text(tag).lineLimit(1)
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(Color.ghAmber)
                    .background(Color.ghAmber.opacity(0.15), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.ghAmber.opacity(0.5), lineWidth: 0.5))
                }
                Text(row.commit.message)
                    .lineLimit(1)
                    .foregroundStyle(row.isMerge ? .secondary : .primary)
            }
            Spacer(minLength: 8)
            if row.commit.checkState != .none { CIStatusIcon(state: row.commit.checkState, size: 11) }
            AvatarView(url: row.commit.avatar, size: 16)
            Text(row.commit.authorLogin ?? row.commit.authorName)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 100, alignment: .leading)
            Text(row.commit.shortSha).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
            Ago(date: row.commit.date).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .padding(.trailing, 12)
        .frame(height: rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 4)
            } else if hovering {
                RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.05)).padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Draws one row's slice of the commit graph. Rows tile vertically into continuous lanes.
struct GraphLanes: View {
    let row: GraphRow
    let laneWidth: CGFloat
    let isHead: Bool

    var body: some View {
        Canvas { context, size in
            let h = size.height
            let mid = h / 2
            func x(_ lane: Int) -> CGFloat { 10 + CGFloat(lane) * laneWidth }
            let node = CGPoint(x: x(row.lane), y: mid)
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)

            for segment in row.segments {
                var path = Path()
                let color: Color
                switch segment {
                case .through(let lane, let c):
                    path.move(to: CGPoint(x: x(lane), y: 0))
                    path.addLine(to: CGPoint(x: x(lane), y: h))
                    color = GraphPalette.color(c)
                case .into(let from, let c):
                    let start = CGPoint(x: x(from), y: 0)
                    path.move(to: start)
                    if from == row.lane {
                        path.addLine(to: node)
                    } else {
                        path.addCurve(to: node, control1: CGPoint(x: start.x, y: mid * 0.9), control2: CGPoint(x: node.x, y: mid * 0.2))
                    }
                    color = GraphPalette.color(c)
                case .out(let to, let c):
                    let end = CGPoint(x: x(to), y: h)
                    path.move(to: node)
                    if to == row.lane {
                        path.addLine(to: end)
                    } else {
                        path.addCurve(to: end, control1: CGPoint(x: node.x, y: mid + mid * 0.8), control2: CGPoint(x: end.x, y: mid + mid * 0.1))
                    }
                    color = GraphPalette.color(c)
                case .stub(let lane, let c):
                    path.move(to: node)
                    path.addLine(to: CGPoint(x: x(lane), y: h))
                    context.stroke(path, with: .color(GraphPalette.color(c).opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 3]))
                    continue
                }
                context.stroke(path, with: .color(color), style: style)
            }

            let color = GraphPalette.color(row.color)
            let radius: CGFloat = isHead ? 5.5 : 4.5
            let rect = CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2)
            if row.isMerge {
                context.fill(Path(ellipseIn: rect), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(Path(ellipseIn: rect.insetBy(dx: 1, dy: 1)), with: .color(color), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.fill(Path(ellipseIn: rect), with: .color(color))
                if isHead {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(color.opacity(0.4)), lineWidth: 1.5)
                }
            }
        }
    }
}

struct CommitInspector: View {
    @Environment(AppStore.self) private var store
    let repoStore: RepoStore
    let row: GraphRow
    @State private var detail: CommitDetail?
    @State private var expandedFile: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    AvatarView(url: row.commit.avatar, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.commit.authorLogin ?? row.commit.authorName).fontWeight(.semibold)
                        Text(row.commit.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = row.commit.url {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }.help("Open on GitHub")
                    }
                }

                Text(detail?.commit.message ?? row.commit.message)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button { copyToPasteboard(row.commit.id) } label: {
                        Label(row.commit.shortSha, systemImage: "doc.on.doc").font(.system(.caption, design: .monospaced))
                    }
                    .buttonStyle(.borderless)
                    if row.isMerge { Chip(text: "Merge", color: .ghPurple, systemImage: "arrow.triangle.merge") }
                    ForEach(row.branches, id: \.self) { BranchChip(name: $0) }
                    Spacer()
                    if let stats = detail?.stats { DiffStat(additions: stats.additions, deletions: stats.deletions) }
                }

                let runs = repoStore.runs(forSha: row.commit.id)
                if !runs.isEmpty {
                    Card("Workflow runs", systemImage: "gearshape.2") {
                        ForEach(runs) { run in
                            HStack {
                                CIStatusIcon(state: run.state)
                                Text(run.workflowName)
                                Spacer()
                                if let d = run.duration { Text(d.durationString).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                Button { NSWorkspace.shared.open(run.htmlUrl) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if let files = detail?.files {
                    Card("\(files.count) files changed", systemImage: "doc.text") {
                        VStack(spacing: 0) {
                            ForEach(files) { file in
                                VStack(alignment: .leading, spacing: 0) {
                                    Button {
                                        expandedFile = expandedFile == file.filename ? nil : file.filename
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                                                .rotationEffect(.degrees(expandedFile == file.filename ? 90 : 0))
                                                .foregroundStyle(.tertiary)
                                            Text(file.filename).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                            Spacer()
                                            DiffStat(additions: file.additions, deletions: file.deletions)
                                        }
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if expandedFile == file.filename, let patch = file.patch {
                                        DiffText(patch: patch)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .task {
            guard let client = store.client else { return }
            detail = try? await client.commit(repoStore.fullName, sha: row.commit.id)
        }
    }
}

struct DiffText: View {
    let patch: String

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(patch.components(separatedBy: "\n").prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("@@") ? Color.ghBlue : .primary)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.hasPrefix("+") ? Color.ghGreen.opacity(0.14) : line.hasPrefix("-") ? Color.ghRed.opacity(0.14) : .clear)
                }
            }
            .textSelection(.enabled)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 6)
    }
}
