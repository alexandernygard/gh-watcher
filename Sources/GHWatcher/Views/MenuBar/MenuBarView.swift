import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let state = store.isSignedIn ? store.overallState : .none
        let count = store.attentionCount + store.unreadCount
        HStack(spacing: 3) {
            Image(nsImage: Self.icon(for: state))
            if store.prefs.menuBarShowsCount && count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
    }

    static func icon(for state: CIState) -> NSImage {
        let (name, color): (String, NSColor?) = switch state {
        case .failure: ("xmark.seal.fill", .systemRed)
        case .running, .queued: ("arrow.triangle.2.circlepath.circle.fill", .systemOrange)
        case .success: ("checkmark.seal", nil)
        default: ("point.3.connected.trianglepath.dotted", nil)
        }
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "GH Watcher")?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = color == nil
        return image
    }
}

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isSignedIn {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if store.attentionCount > 0 { attention }
                        if !store.prefs.follows.isEmpty { following }
                        if !store.runningRuns.isEmpty { running }
                        repos
                        if !store.myPRs.isEmpty { myPRs }
                        if !store.inbox.isEmpty { inbox }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 560)
            } else {
                VStack(spacing: 10) {
                    Text("Not signed in").font(.headline)
                    Button("Open GH Watcher") { openMain() }
                }
                .padding(30)
            }
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func show(_ item: SidebarItem) {
        store.selection = item
        openMain()
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(url: store.me?.avatarUrl, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.me?.login ?? "GH Watcher").font(.headline)
                HStack(spacing: 4) {
                    CIStatusIcon(state: store.overallState, size: 10)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let core = store.coreRateLimit {
                Text("\(core.remaining)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .glassEffect(.regular, in: Capsule())
                    .help("API requests left this hour")
            }
        }
        .padding(12)
    }

    private var statusLine: String {
        let failing = store.failingStores.count
        let running = store.runningRuns.count
        var parts: [String] = []
        if failing > 0 { parts.append("\(failing) failing") }
        if running > 0 { parts.append("\(running) running") }
        if store.unreadCount > 0 { parts.append("\(store.unreadCount) unread") }
        return parts.isEmpty ? "All quiet and green" : parts.joined(separator: " · ")
    }

    private func sectionTitle(_ title: String, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Spacer()
            if let action {
                Button("Show", action: action).buttonStyle(.link).font(.caption)
            }
        }
    }

    private var attention: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Needs attention")
            ForEach(store.failingStores) { s in
                let run = s.defaultBranchRuns.first { $0.state == .failure }
                MenuRow(icon: AnyView(CIStatusIcon(state: .failure)), title: s.fullName,
                        subtitle: "\(run?.workflowName ?? "CI") failing on \(s.defaultBranch)", date: run?.updatedAt) {
                    if let url = run?.htmlUrl { NSWorkspace.shared.open(url) }
                }
            }
            ForEach(store.reviewRequests) { pr in
                MenuRow(icon: AnyView(Image(systemName: "eye.circle.fill").foregroundStyle(Color.ghPurple)), title: pr.title,
                        subtitle: "Review requested · \(pr.repo)#\(pr.number)", date: pr.updatedAt) {
                    NSWorkspace.shared.open(pr.url)
                }
            }
            ForEach(store.myFailingPRs) { pr in
                MenuRow(icon: AnyView(CIStatusIcon(state: .failure)), title: pr.title,
                        subtitle: "Your PR is failing · \(pr.repo)#\(pr.number)", date: pr.updatedAt) {
                    NSWorkspace.shared.open(pr.url)
                }
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Running")
            ForEach(store.runningRuns.prefix(6), id: \.1.id) { s, run in
                MenuRow(icon: AnyView(CIStatusIcon(state: run.state)), title: "\(run.workflowName) · \(run.headBranch ?? "")",
                        subtitle: s.fullName, date: run.runStartedAt,
                        trailing: store.isFollowing(Follow(run: run, repo: s.fullName)) ? "following" : nil) {
                    NSWorkspace.shared.open(run.htmlUrl)
                }
                .contextMenu {
                    let follow = Follow(run: run, repo: s.fullName)
                    Button(store.isFollowing(follow) ? "Stop Following" : "Notify When Finished") { store.toggleFollow(follow) }
                    Button("Show in GH Watcher") {
                        s.selectedRun = run.id
                        store.show(repo: s.fullName, tab: .actions)
                        openMain()
                    }
                }
            }
        }
    }

    private var following: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Following")
            ForEach(store.prefs.follows) { follow in
                let state = CIState(rawValue: follow.snapshot?.isRunActiveOrChecks ?? "") ?? .none
                MenuRow(icon: AnyView(Image(systemName: follow.isRun ? "bell.fill" : "arrow.triangle.pull")
                            .foregroundStyle(state.isActive ? Color.ghAmber : Color.ghBlue)),
                        title: follow.title,
                        subtitle: "\(follow.repo) · \(follow.statusLine)", date: follow.created) {
                    NSWorkspace.shared.open(follow.url)
                }
                .contextMenu {
                    Button("Stop Following") { store.unfollow(follow.id) }
                }
            }
        }
    }

    private var repos: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Repositories") { show(.overview) }
            ForEach(store.watchedStores) { s in
                let latest = s.runs.first
                MenuRow(icon: AnyView(CIStatusIcon(state: s.ciState)), title: s.fullName,
                        subtitle: latest.map { "\($0.workflowName): \($0.state.label.lowercased()) · \($0.headBranch ?? "")" } ?? "No runs",
                        date: latest?.updatedAt,
                        trailing: s.prs.isEmpty ? nil : "\(s.prs.count) PR\(s.prs.count == 1 ? "" : "s")") {
                    store.show(repo: s.fullName)
                    openMain()
                }
            }
        }
    }

    private var myPRs: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Your pull requests") { show(.myPRs) }
            ForEach(store.myPRs.prefix(6)) { pr in
                MenuRow(icon: AnyView(CIStatusIcon(state: pr.checkState)), title: pr.title,
                        subtitle: "\(pr.repo)#\(pr.number)\(pr.reviewDecision == "APPROVED" ? " · approved" : "")", date: pr.updatedAt,
                        trailing: store.isFollowing(Follow(pr: pr)) ? "following" : nil) {
                    NSWorkspace.shared.open(pr.url)
                }
                .contextMenu {
                    let follow = Follow(pr: pr)
                    Button(store.isFollowing(follow) ? "Stop Following" : "Follow (Notify on Changes)") { store.toggleFollow(follow) }
                }
            }
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Inbox") { show(.inbox) }
            ForEach(store.inbox.prefix(6)) { thread in
                MenuRow(icon: AnyView(Image(systemName: thread.typeSymbol).foregroundStyle(thread.unread ? Color.ghBlue : .secondary)),
                        title: thread.subject.title, subtitle: "\(thread.repository.fullName) · \(thread.reasonLabel)", date: thread.updatedAt) {
                    store.open(thread)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button { openMain() } label: { Label("Open GH Watcher", systemImage: "macwindow") }
            Spacer()
            Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh all")
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: { Image(systemName: "gearshape") }.help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct MenuRow: View {
    let icon: AnyView
    let title: String
    let subtitle: String
    let date: Date?
    var trailing: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon.frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    if let date { Ago(date: date).font(.caption2).foregroundStyle(.tertiary) }
                    if let trailing { Text(trailing).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
