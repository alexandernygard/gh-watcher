import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettings() }
            Tab("Repositories", systemImage: "eye") {
                RepoPickerView(embedded: true).padding(20)
            }
            Tab("Account", systemImage: "person.crop.circle") { AccountSettings() }
        }
        .frame(width: 680, height: 560)
        .environment(store)
    }
}

struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var prefs = store.prefs
        Form {
            Section("App") {
                Toggle("Show in Dock", isOn: $prefs.showInDock)
                    .onChange(of: prefs.showInDock) { store.applyDockPreference() }
                Toggle("Show attention count in menu bar", isOn: $prefs.menuBarShowsCount)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                        }
                    }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(Color.ghRed) }
            }

            Section {
                LabeledContent("Idle repositories") {
                    Picker("", selection: $prefs.baseInterval) {
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledContent("While workflows run") {
                    Picker("", selection: $prefs.activeInterval) {
                        Text("10 seconds").tag(10.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledContent("In the background") {
                    Picker("", selection: $prefs.backgroundMultiplier) {
                        Text("Same speed").tag(1.0)
                        Text("2× slower").tag(2.0)
                        Text("4× slower").tag(4.0)
                    }
                    .labelsHidden().fixedSize()
                }
            } header: {
                Text("Polling")
            } footer: {
                Text("Every request is conditional (ETag), so unchanged data costs nothing against your 5,000 requests/hour budget. The repository you're looking at is polled faster, and everything slows down automatically when the budget runs low.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("API budget") {
                RateLimitDetails()
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            if let me = store.me {
                Section("Signed in") {
                    HStack(spacing: 12) {
                        AvatarView(url: me.avatarUrl, size: 44)
                        VStack(alignment: .leading) {
                            Text(me.name ?? me.login).font(.headline)
                            Text("@\(me.login)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign Out", role: .destructive) { store.signOut() }
                    }
                    LabeledContent("Token source", value: store.auth.source == .ghCLI ? "GitHub CLI (gh auth token)" : "Personal access token (Keychain)")
                }
            } else {
                Section { Text("Not signed in. Open the main window to sign in.") }
            }
        }
        .formStyle(.grouped)
    }
}

struct NotificationSettings: View {
    @Environment(AppStore.self) private var store
    @State private var editing: NotificationRule?

    var body: some View {
        @Bindable var prefs = store.prefs
        Form {
            Section {
                Toggle("Send notifications", isOn: $prefs.notificationsEnabled)
                Toggle("Quiet hours", isOn: $prefs.quietHoursEnabled)
                if prefs.quietHoursEnabled {
                    HStack {
                        Picker("From", selection: $prefs.quietStart) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
                        Picker("To", selection: $prefs.quietEnd) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
                    }
                }
                HStack {
                    Button("Send Test Notification") { store.notifier.postTest() }
                    Button("Open System Notification Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }

            Section {
                ForEach($prefs.rules) { $rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Image(systemName: rule.kind.symbol).foregroundStyle(rule.kind.color).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.kind.title)
                            Text(rule.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = rule }.buttonStyle(.borderless)
                        Button { prefs.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    .opacity(rule.enabled ? 1 : 0.55)
                }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Menu("Add Rule") {
                        ForEach(Dictionary(grouping: EventKind.allCases, by: \.category).sorted { $0.key < $1.key }, id: \.key) { category, kinds in
                            Section(category) {
                                ForEach(kinds) { kind in
                                    Button { editing = NotificationRule(kind: kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    Button("Reset") { prefs.resetRules() }
                }
            } footer: {
                Text("An event notifies you when any enabled rule matches it. Add several rules of the same kind to cover different repositories or branches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { updated in
                if let i = prefs.rules.firstIndex(where: { $0.id == updated.id }) {
                    prefs.rules[i] = updated
                } else {
                    prefs.rules.append(updated)
                }
            }
            .environment(store)
        }
    }

    private func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        return Calendar.current.date(from: c)?.formatted(date: .omitted, time: .shortened) ?? "\(h):00"
    }
}

struct RuleEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var rule: NotificationRule
    let save: (NotificationRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: rule.kind.symbol).font(.title2).foregroundStyle(rule.kind.color)
                Text(rule.kind.title).font(.title3.bold())
            }
            .padding(20)

            Form {
                Picker("Event", selection: $rule.kind) {
                    ForEach(EventKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Toggle("Enabled", isOn: $rule.enabled)
                Toggle("Only when it involves me", isOn: $rule.onlyInvolvingMe)
                    .help("My PRs, my issues, runs I triggered, comments on things I opened, or mentions")
                Toggle("Ignore my own actions", isOn: $rule.ignoreMyOwn)
                Toggle("Play sound", isOn: $rule.playSound)
                if rule.kind.supportsBranchFilter {
                    TextField("Branches", text: $rule.branchPattern, prompt: Text("Any branch, or e.g. main, release/*"))
                }
                Section("Repositories") {
                    Toggle("All watched repositories", isOn: Binding(
                        get: { rule.repos.isEmpty },
                        set: { if $0 { rule.repos = [] } else { rule.repos = Array(store.prefs.watched.prefix(1)) } }
                    ))
                    if !rule.repos.isEmpty {
                        ForEach(store.prefs.watched, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { rule.repos.contains(name) },
                                set: { if $0 { rule.repos.append(name) } else { rule.repos.removeAll { $0 == name } } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
    }
}
