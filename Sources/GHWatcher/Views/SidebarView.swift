import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var showPicker = false

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.overview)
                Label("Inbox", systemImage: "tray")
                    .badge(store.unreadCount)
                    .tag(SidebarItem.inbox)
                Label("My Pull Requests", systemImage: "arrow.triangle.pull")
                    .badge(store.myPRs.count)
                    .tag(SidebarItem.myPRs)
                Label("Review Requests", systemImage: "eye")
                    .badge(store.reviewRequests.count)
                    .tag(SidebarItem.reviews)
                Label("Live Feed", systemImage: "dot.radiowaves.left.and.right")
                    .tag(SidebarItem.feed)
            }

            Section("Watching") {
                ForEach(store.watchedStores) { repoStore in
                    RepoSidebarRow(repoStore: repoStore)
                        .tag(SidebarItem.repo(repoStore.fullName))
                        .contextMenu {
                            Button("Open on GitHub") { NSWorkspace.shared.open(repoStore.webURL) }
                            Button("Refresh") { repoStore.markAllDirty() }
                            Divider()
                            Button("Stop Watching", role: .destructive) { store.unwatch(repoStore.fullName) }
                        }
                }
                .onMove { from, to in store.prefs.watched.move(fromOffsets: from, toOffset: to) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { showPicker = true } label: {
                    Label("Add Repositories", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                Spacer()
                if let me = store.me {
                    Menu {
                        Button("Open Profile") { if let url = me.htmlUrl { NSWorkspace.shared.open(url) } }
                        SettingsLink { Text("Settings…") }
                        Divider()
                        Button("Sign Out") { store.signOut() }
                    } label: {
                        AvatarView(url: me.avatarUrl, size: 22)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showPicker) {
            RepoPickerView().environment(store)
        }
    }
}

struct RepoSidebarRow: View {
    let repoStore: RepoStore

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if repoStore.lastPolled == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    CIStatusIcon(state: repoStore.ciState, size: 12)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(repoStore.name).lineLimit(1)
                Text(repoStore.owner).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if repoStore.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ghAmber).font(.caption)
                    .help(repoStore.lastError ?? "")
            }
        }
        .badge(repoStore.prs.count)
    }
}
