import SwiftUI

struct RepoPickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var search = ""
    @State private var manual = ""
    @State private var hideArchived = true
    @State private var manualError: String?

    private var filtered: [Repo] {
        store.allRepos.filter { repo in
            (!hideArchived || repo.archived != true) &&
            (search.isEmpty || repo.fullName.localizedCaseInsensitiveContains(search) || (repo.description ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                HStack {
                    Text("Watch Repositories").font(.title2.bold())
                    Spacer()
                    Text("\(store.prefs.watched.count) watched").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Search your repositories", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Hide archived", isOn: $hideArchived).toggleStyle(.checkbox)
                if store.allReposLoading { ProgressView().controlSize(.small) }
                Menu("Bulk") {
                    Button("Watch All \(filtered.count) Shown") { store.watch(all: filtered.map(\.fullName)) }
                    Button("Unwatch All Shown") { store.unwatch(all: filtered.map(\.fullName)) }
                }
                .fixedSize()
                Button { Task { await store.loadAllRepos() } } label: { Image(systemName: "arrow.clockwise") }
            }
            List(filtered) { repo in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { store.isWatched(repo.fullName) }, set: { _ in store.toggleWatch(repo.fullName) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    AvatarView(url: repo.owner.avatarUrl, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(repo.fullName).fontWeight(.medium)
                            if repo.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                            if repo.fork == true { Image(systemName: "tuningfork").font(.caption2).foregroundStyle(.secondary) }
                            if repo.archived == true { Chip(text: "Archived", color: .ghAmber) }
                        }
                        if let d = repo.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if let lang = repo.language { Text(lang).font(.caption).foregroundStyle(.secondary) }
                    if let pushed = repo.pushedAt { Ago(date: pushed).font(.caption).foregroundStyle(.tertiary).frame(width: 70, alignment: .trailing) }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.toggleWatch(repo.fullName) }
            }
            .frame(minHeight: 320)
            .overlay {
                if store.allRepos.isEmpty && store.allReposLoading { ProgressView("Loading repositories…") }
            }

            HStack {
                TextField("Watch any public repo: owner/name", text: $manual)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManual)
                Button("Watch", action: addManual).disabled(!manual.contains("/"))
            }
            if let manualError { Text(manualError).font(.caption).foregroundStyle(Color.ghRed) }

            if !embedded {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                }
            }
        }
        .padding(embedded ? 0 : 20)
        .frame(width: embedded ? nil : 640, height: embedded ? nil : 560)
        .task { if store.allRepos.isEmpty { await store.loadAllRepos() } }
    }

    private func addManual() {
        var name = manual.trimmingCharacters(in: .whitespaces)
        name = name.replacingOccurrences(of: "https://github.com/", with: "")
        if name.hasSuffix("/") { name.removeLast() }
        guard name.split(separator: "/").count == 2, let client = store.client else { manualError = "Use the form owner/name"; return }
        Task {
            do {
                _ = try await client.get("/repos/\(name)", as: Repo.self)
                store.watch(name)
                manual = ""
                manualError = nil
            } catch {
                manualError = error.localizedDescription
            }
        }
    }
}
