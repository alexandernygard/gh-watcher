import SwiftUI

/// The item shown in the frontmost detail pane, for ⌘O / ⌘⇧C / follow shortcuts.
struct FocusedItem {
    let url: URL
    var branch: String?
    var follow: Follow?
}

/// Actions the open pull request offers to the menu bar.
struct PRCommands {
    var approve: (() -> Void)?
    var merge: (() -> Void)?
}

/// Actions the open workflow run offers to the menu bar.
struct RunCommands {
    var rerunFailed: (() -> Void)?
    var rerunAll: (() -> Void)?
    var cancel: (() -> Void)?
}

// Written out by hand: the @Entry macro needs Xcode's macro plugins.
private struct FocusedItemKey: FocusedValueKey { typealias Value = FocusedItem }
private struct PRCommandsKey: FocusedValueKey { typealias Value = PRCommands }
private struct RunCommandsKey: FocusedValueKey { typealias Value = RunCommands }

extension FocusedValues {
    var focusedItem: FocusedItem? {
        get { self[FocusedItemKey.self] }
        set { self[FocusedItemKey.self] = newValue }
    }
    var prCommands: PRCommands? {
        get { self[PRCommandsKey.self] }
        set { self[PRCommandsKey.self] = newValue }
    }
    var runCommands: RunCommands? {
        get { self[RunCommandsKey.self] }
        set { self[RunCommandsKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    let store: AppStore
    @FocusedValue(\.focusedItem) private var item
    @FocusedValue(\.prCommands) private var pr
    @FocusedValue(\.runCommands) private var run

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Issue…") { store.selectedRepoStore?.presentingNewIssue = true }
                .keyboardShortcut("n")
                .disabled(store.selectedRepoStore == nil)
            Button("New Pull Request…") { store.selectedRepoStore?.presentingNewPR = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.selectedRepoStore == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh All") { store.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command])
        }
        CommandGroup(after: .textEditing) {
            Button("Filter List") { store.filterFocusToken += 1 }
                .keyboardShortcut("f")
        }
        CommandMenu("Go") {
            Button("Quick Open…") {
                store.activateMainWindow()
                store.showQuickOpen = true
            }
            .keyboardShortcut("k")
            Divider()
            Button("Overview") { store.selection = .overview }.keyboardShortcut("1")
            Button("Inbox") { store.selection = .inbox }.keyboardShortcut("2")
            Button("My Pull Requests") { store.selection = .myPRs }.keyboardShortcut("3")
            Button("Review Requests") { store.selection = .reviews }.keyboardShortcut("4")
            Button("Live Feed") { store.selection = .feed }.keyboardShortcut("5")
            Divider()
            Button("Next Repository Tab") { moveTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(store.selectedRepoStore == nil)
            Button("Previous Repository Tab") { moveTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(store.selectedRepoStore == nil)
            Divider()
            Button("Next Repository") { moveRepo(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Repository") { moveRepo(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
        CommandMenu("Item") {
            Button("Open on GitHub") { if let url = item?.url { NSWorkspace.shared.open(url) } }
                .keyboardShortcut("o")
                .disabled(item == nil)
            Button("Copy URL") { if let url = item?.url { copyToPasteboard(url.absoluteString) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(item == nil)
            Button("Copy Branch Name") { if let branch = item?.branch { copyToPasteboard(branch) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(item?.branch == nil)
            Divider()
            let following = item?.follow.map(store.isFollowing) ?? false
            Button(following ? "Stop Following" : "Follow (Notify on Changes)") { if let f = item?.follow { store.toggleFollow(f) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(item?.follow == nil)
            Divider()
            Button("Approve Pull Request") { pr?.approve?() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(pr?.approve == nil)
            Button("Merge Pull Request…") { pr?.merge?() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(pr?.merge == nil)
            Divider()
            Button("Re-run Failed Jobs") { run?.rerunFailed?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(run?.rerunFailed == nil)
            Button("Re-run All Jobs") { run?.rerunAll?() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(run?.rerunAll == nil)
            Button("Cancel Run") { run?.cancel?() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(run?.cancel == nil)
        }
    }

    private func moveTab(_ delta: Int) {
        guard let repo = store.selectedRepoStore else { return }
        repo.tab = repo.tab.offset(delta)
    }

    private func moveRepo(_ delta: Int) {
        let names = store.prefs.watched
        guard !names.isEmpty else { return }
        let current = if case .repo(let name) = store.selection { names.firstIndex(of: name) } else { nil as Int? }
        let next = current.map { ($0 + delta + names.count) % names.count } ?? (delta > 0 ? 0 : names.count - 1)
        store.selection = .repo(names[next])
    }
}

extension View {
    /// j / k move the selection (like ↓ / ↑), and Return opens the selected item.
    func listKeyNavigation<ID: Hashable>(_ selection: Binding<ID?>, ids: [ID], open: @escaping (ID) -> Void) -> some View {
        self
            .onKeyPress(characters: CharacterSet(charactersIn: "jk"), phases: [.down, .repeat]) { press in
                guard press.modifiers.isEmpty, !ids.isEmpty else { return .ignored }
                let current = selection.wrappedValue.flatMap { ids.firstIndex(of: $0) }
                let down = press.characters == "j"
                let next = current.map { down ? min($0 + 1, ids.count - 1) : max($0 - 1, 0) } ?? 0
                selection.wrappedValue = ids[next]
                return .handled
            }
            .onKeyPress(.return) {
                guard let id = selection.wrappedValue else { return .ignored }
                open(id)
                return .handled
            }
    }
}
