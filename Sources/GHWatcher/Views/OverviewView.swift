import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    StatTile(title: "Watched repos", value: "\(store.watchedStores.count)", systemImage: "eye", tint: .ghBlue)
                    StatTile(title: "Failing on default branch", value: "\(store.failingStores.count)", systemImage: "xmark.octagon",
                             tint: store.failingStores.isEmpty ? .ghGreen : .ghRed)
                    StatTile(title: "Workflows running", value: "\(store.runningRuns.count)", systemImage: "gearshape.2", tint: .ghAmber)
                    StatTile(title: "Reviews requested", value: "\(store.reviewRequests.count)", systemImage: "eye.circle", tint: .ghPurple)
                    StatTile(title: "Unread notifications", value: "\(store.unreadCount)", systemImage: "tray.full", tint: .pink)
                }

                if store.attentionCount > 0 { attention }
                if !store.runningRuns.isEmpty { running }

                Text("Repositories").font(.title3.bold()).padding(.top, 4)
                if store.watchedStores.isEmpty {
                    ContentUnavailableView("No repositories watched", systemImage: "eye.slash",
                                           description: Text("Add repositories from the sidebar to start monitoring."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(store.watchedStores) { repoStore in
                            RepoCard(repoStore: repoStore)
                                .onTapGesture { store.selection = .repo(repoStore.fullName) }
                        }
                    }
                }

                if !store.feed.isEmpty {
                    Card("Live Feed", systemImage: "dot.radiowaves.left.and.right", trailing: {
                        Button("See all") { store.selection = .feed }.buttonStyle(.link)
                    }) {
                        VStack(spacing: 0) {
                            ForEach(store.feed.prefix(8)) { event in
                                FeedRow(event: event)
                                if event.id != store.feed.prefix(8).last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button { store.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "Working late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = store.me?.name?.split(separator: " ").first.map(String.init) ?? store.me?.login ?? ""
        return "\(part), \(name)"
    }

    private var summary: String {
        let failing = store.failingStores.count
        let running = store.runningRuns.count
        if failing > 0 { return "\(failing) repositor\(failing == 1 ? "y is" : "ies are") failing CI on the default branch." }
        if running > 0 { return "\(running) workflow\(running == 1 ? " is" : "s are") running right now." }
        if store.watchedStores.isEmpty { return "Pick some repositories to watch." }
        return "Everything is green. Nice."
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AvatarView(url: store.me?.avatarUrl, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting).font(.largeTitle.bold())
                HStack(spacing: 6) {
                    CIStatusIcon(state: store.overallState)
                    Text(summary).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var attention: some View {
        Card("Needs your attention", systemImage: "exclamationmark.bubble.fill") {
            VStack(spacing: 6) {
                ForEach(store.failingStores) { repoStore in
                    let run = repoStore.defaultBranchRuns.first { $0.state == .failure }
                    AttentionRow(symbol: "xmark.circle.fill", tint: .ghRed,
                                 title: "\(repoStore.fullName): \(run?.workflowName ?? "CI") failing on \(repoStore.defaultBranch)",
                                 subtitle: run?.displayTitle ?? "", date: run?.updatedAt) {
                        store.show(repo: repoStore.fullName, tab: .actions)
                    }
                }
                ForEach(store.reviewRequests) { pr in
                    AttentionRow(symbol: "eye.circle.fill", tint: .ghPurple,
                                 title: "Review requested: \(pr.title)",
                                 subtitle: "\(pr.repo)#\(pr.number) by \(pr.author)", date: pr.updatedAt) {
                        store.selection = .reviews
                    }
                }
                ForEach(store.myFailingPRs) { pr in
                    AttentionRow(symbol: "xmark.circle.fill", tint: .ghRed,
                                 title: "Checks failing on your PR: \(pr.title)",
                                 subtitle: "\(pr.repo)#\(pr.number)", date: pr.updatedAt) {
                        store.selection = .myPRs
                    }
                }
            }
        }
    }

    private var running: some View {
        Card("Running now", systemImage: "gearshape.2.fill") {
            VStack(spacing: 6) {
                ForEach(store.runningRuns, id: \.1.id) { repoStore, run in
                    HStack(spacing: 10) {
                        CIStatusIcon(state: run.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(run.workflowName) · \(run.displayTitle ?? "")").lineLimit(1)
                            Text(repoStore.fullName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let branch = run.headBranch { BranchChip(name: branch) }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(run.duration?.durationString ?? "–").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(width: 60, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.show(repo: repoStore.fullName, tab: .actions) }
                }
            }
        }
    }
}

struct AttentionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let date: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if let date { Ago(date: date).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RepoCard: View {
    let repoStore: RepoStore
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(url: repoStore.repo?.owner.avatarUrl, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(repoStore.name).font(.headline).lineLimit(1)
                    Text(repoStore.owner).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if repoStore.repo?.isPrivate == true { Chip(text: "Private", systemImage: "lock.fill") }
                CIStatusIcon(state: repoStore.ciState, size: 18)
            }

            Text(repoStore.repo?.description ?? " ")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)

            if !repoStore.defaultBranchRuns.isEmpty {
                HStack(spacing: 6) {
                    ForEach(repoStore.defaultBranchRuns.prefix(5)) { run in
                        HStack(spacing: 3) {
                            CIStatusIcon(state: run.state, size: 10)
                            Text(run.workflowName).lineLimit(1)
                        }
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(run.state.color.opacity(0.1), in: Capsule())
                    }
                }
            }

            HStack(spacing: 14) {
                Label("\(repoStore.prs.count)", systemImage: "arrow.triangle.pull")
                Label("\(repoStore.issues.count)", systemImage: "smallcircle.filled.circle")
                Label("\(repoStore.repo?.stargazersCount ?? 0)", systemImage: "star")
                if let lang = repoStore.repo?.language { Label(lang, systemImage: "chevron.left.forwardslash.chevron.right") }
                Spacer()
                if let pushed = repoStore.repo?.pushedAt { Ago(date: pushed) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                .fill(repoStore.ciState.color.gradient)
                .frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(hovering ? 0.18 : 0.06)))
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
