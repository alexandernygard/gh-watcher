import SwiftUI

struct InboxView: View {
    @Environment(AppStore.self) private var store
    @State private var reasonFilter: String?
    @State private var search = ""

    private var filtered: [NotificationThread] {
        store.inbox.filter { thread in
            (reasonFilter == nil || thread.reason == reasonFilter) &&
            (search.isEmpty || thread.subject.title.localizedCaseInsensitiveContains(search) ||
             thread.repository.fullName.localizedCaseInsensitiveContains(search))
        }
    }

    private var grouped: [(String, [NotificationThread])] {
        Dictionary(grouping: filtered, by: \.repository.fullName)
            .map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { ($0.1.first?.updatedAt ?? .distantPast) > ($1.1.first?.updatedAt ?? .distantPast) }
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(store.inbox.isEmpty ? "Inbox zero" : "No matches",
                                       systemImage: store.inbox.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(store.inbox.isEmpty ? "You're all caught up." : "Try a different filter."))
            } else {
                List {
                    ForEach(grouped, id: \.0) { repo, threads in
                        Section {
                            ForEach(threads) { thread in
                                InboxRow(thread: thread)
                                    .contextMenu {
                                        Button("Open in Browser") { store.open(thread) }
                                        Button("Mark as Read") { Task { await store.markRead(thread) } }
                                        Button("Show Repository") { store.show(repo: thread.repository.fullName) }
                                    }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                AvatarView(url: threads.first?.repository.owner.avatarUrl, size: 16)
                                Text(repo)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter notifications")
        .navigationTitle("Inbox")
        .navigationSubtitle("\(store.unreadCount) unread")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Reason", selection: $reasonFilter) {
                        Text("All reasons").tag(String?.none)
                        Divider()
                        ForEach(Array(Set(store.inbox.map(\.reason))).sorted(), id: \.self) { reason in
                            Text(reason.replacingOccurrences(of: "_", with: " ").capitalized).tag(Optional(reason))
                        }
                    }
                    .pickerStyle(.inline)
                    Toggle("Include read", isOn: $store.inboxShowsAll)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem {
                Button { Task { await store.markAllRead() } } label: {
                    Label("Mark All Read", systemImage: "checkmark.circle")
                }
                .disabled(store.unreadCount == 0)
            }
        }
        .onChange(of: store.inboxShowsAll) { Task { await store.pollInbox() } }
    }
}

struct InboxRow: View {
    @Environment(AppStore.self) private var store
    let thread: NotificationThread
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(thread.unread ? Color.ghBlue : .clear).frame(width: 7, height: 7)
            Image(systemName: thread.typeSymbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.subject.title).fontWeight(thread.unread ? .semibold : .regular).lineLimit(1)
                HStack(spacing: 6) {
                    Chip(text: thread.reasonLabel, color: reasonColor)
                    Text(thread.subject.type.replacingOccurrences(of: "PullRequest", with: "Pull request"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hovering {
                Button { Task { await store.markRead(thread) } } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless).help("Mark as read")
            }
            Ago(date: thread.updatedAt).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.open(thread) }
    }

    private var reasonColor: Color {
        switch thread.reason {
        case "review_requested": .ghPurple
        case "mention", "team_mention": .ghBlue
        case "assign": .ghGreen
        case "ci_activity": .ghAmber
        case "security_alert": .ghRed
        default: .secondary
        }
    }
}

struct FeedView: View {
    @Environment(AppStore.self) private var store
    @State private var kinds: Set<EventKind> = []

    var body: some View {
        Group {
            if store.feed.isEmpty {
                ContentUnavailableView("Listening for activity", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Changes in your watched repositories will stream in here as they happen."))
            } else {
                List(store.feed.filter { kinds.isEmpty || kinds.contains($0.kind) }) { event in
                    FeedRow(event: event)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Live Feed")
        .navigationSubtitle("Everything GH Watcher detected this session")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Show Everything") { kinds = [] }
                    Divider()
                    ForEach(EventKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { kinds.contains(kind) },
                            set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }
                        ))
                    }
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
            }
        }
    }
}

struct FeedRow: View {
    let event: WatchEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.kind.color)
                .frame(width: 26, height: 26)
                .background(event.kind.color.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).lineLimit(1).fontWeight(.medium)
                    if event.notified {
                        Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary).help("A notification was sent")
                    }
                }
                HStack(spacing: 6) {
                    Text(event.repo).foregroundStyle(.secondary)
                    if let branch = event.branch { BranchChip(name: branch) }
                    if !event.subtitle.isEmpty { Text(event.subtitle).foregroundStyle(.tertiary).lineLimit(1) }
                }
                .font(.caption)
            }
            Spacer()
            if let actor = event.actorAvatar { AvatarView(url: actor, size: 18) }
            Ago(date: event.date).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let url = event.url { NSWorkspace.shared.open(url) } }
        .contextMenu {
            if let url = event.url { Button("Open in Browser") { NSWorkspace.shared.open(url) } }
            Button("Show Repository") { AppStore.shared.show(repo: event.repo) }
        }
    }
}
