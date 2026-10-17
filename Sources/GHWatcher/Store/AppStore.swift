import AppKit
import Observation

enum SidebarItem: Hashable {
    case overview, inbox, myPRs, reviews, feed
    case repo(String)
}

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    let prefs = Preferences()
    let auth = AuthManager()
    let notifier = Notifier()

    private(set) var client: GitHubClient?
    var me: GHUser?
    var isSignedIn: Bool { me != nil }
    var isBootstrapping = true

    var allRepos: [Repo] = []
    var allReposLoading = false
    var repoStores: [String: RepoStore] = [:]
    var inbox: [NotificationThread] = []
    var inboxShowsAll = false
    var myPRs: [PRItem] = []
    var reviewRequests: [PRItem] = []
    var rateLimits: [String: RateLimit] = [:]
    var feed: [WatchEvent] = []
    var selection: SidebarItem? = .overview
    var appActive = true
    var lastError: String?
    var lastGlobalPoll: Date?

    private var pollTask: Task<Void, Never>?
    private var nextInboxPoll = Date.distantPast
    private var nextViewerPoll = Date.distantPast
    private var inboxBaselineDone = false
    private var seenThreads: [String: Date] = [:]

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppStore.shared.appActive = true
                AppStore.shared.nudge()
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppStore.shared.appActive = false }
        }
    }

    // MARK: Auth

    func bootstrap() async {
        defer { isBootstrapping = false }
        if let token = await auth.resolveToken() {
            await signIn(token: token)
        }
    }

    func signIn(token: String) async {
        auth.isWorking = true
        defer { auth.isWorking = false }
        let client = GitHubClient(token: token)
        await client.setRateLimitHandler { limit in
            Task { @MainActor in AppStore.shared.rateLimits[limit.resource] = limit }
        }
        do {
            me = try await client.get("/user", as: GHUser.self).value
            self.client = client
            auth.error = nil
        } catch {
            auth.error = error.localizedDescription
            return
        }
        syncRepoStores()
        startPolling()
        notifier.requestAuthorization()
        Task { await loadAllRepos() }
    }

    func signOut() {
        pollTask?.cancel()
        auth.signOut()
        client = nil
        me = nil
        repoStores = [:]
        inbox = []
        myPRs = []
        reviewRequests = []
        feed = []
        allRepos = []
        inboxBaselineDone = false
        seenThreads = [:]
    }

    // MARK: Repositories

    var watchedStores: [RepoStore] { prefs.watched.compactMap { repoStores[$0] } }

    func loadAllRepos() async {
        guard let client else { return }
        allReposLoading = true
        defer { allReposLoading = false }
        do {
            let repos: [Repo] = try await client.getPaged("/user/repos", query: [
                "per_page": "100", "sort": "pushed", "affiliation": "owner,collaborator,organization_member",
            ], maxPages: 10)
            allRepos = repos
            if !prefs.didOnboard {
                prefs.didOnboard = true
                if prefs.watched.isEmpty {
                    prefs.watched = Array(repos.filter { $0.archived != true }.prefix(5).map(\.fullName))
                    syncRepoStores()
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func isWatched(_ fullName: String) -> Bool { prefs.watched.contains(fullName) }

    func watch(_ fullName: String) {
        guard !prefs.watched.contains(fullName) else { return }
        prefs.watched.append(fullName)
        syncRepoStores()
    }

    func unwatch(_ fullName: String) {
        prefs.watched.removeAll { $0 == fullName }
        if selection == .repo(fullName) { selection = .overview }
        syncRepoStores()
    }

    func toggleWatch(_ fullName: String) {
        isWatched(fullName) ? unwatch(fullName) : watch(fullName)
    }

    private func syncRepoStores() {
        for name in prefs.watched where repoStores[name] == nil {
            repoStores[name] = RepoStore(fullName: name)
        }
        for name in repoStores.keys where !prefs.watched.contains(name) {
            repoStores[name] = nil
        }
    }

    // MARK: Polling

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Ask for an immediate poll of whatever is due soonest.
    func nudge() {
        if let selected = selectedRepoStore { selected.nextPoll = .distantPast }
        nextViewerPoll = min(nextViewerPoll, Date.now.addingTimeInterval(5))
    }

    func refreshAll() {
        for store in repoStores.values { store.markAllDirty() }
        nextInboxPoll = .distantPast
        nextViewerPoll = .distantPast
    }

    var selectedRepoStore: RepoStore? {
        if case .repo(let name) = selection { return repoStores[name] }
        return nil
    }

    private var rateMultiplier: Double {
        guard let core = rateLimits["core"] else { return 1 }
        if core.remaining < 200 { return 6 }
        if core.remaining < 1000 { return 2.5 }
        return 1
    }

    func interval(for store: RepoStore) -> TimeInterval {
        var seconds = prefs.baseInterval
        if store.hasActiveRuns {
            seconds = prefs.activeInterval
        } else if store === selectedRepoStore && appActive {
            seconds = min(seconds, 30)
        }
        if !appActive && !store.hasActiveRuns { seconds *= prefs.backgroundMultiplier }
        return max(10, seconds * rateMultiplier)
    }

    private func tick() async {
        guard let client else { return }
        let now = Date.now
        for store in repoStores.values where store.nextPoll <= now && !store.isPolling {
            store.nextPoll = now.addingTimeInterval(3600)
            Task {
                let events = await store.poll(client: client, me: me?.login)
                store.nextPoll = Date.now.addingTimeInterval(interval(for: store))
                handle(events)
            }
        }
        if now >= nextInboxPoll {
            nextInboxPoll = now.addingTimeInterval(3600)
            Task { await pollInbox() }
        }
        if now >= nextViewerPoll {
            nextViewerPoll = now.addingTimeInterval(3600)
            Task { await pollViewer() }
        }
    }

    func pollInbox() async {
        guard let client else { return }
        var interval: TimeInterval = 60
        do {
            var query = ["per_page": "50"]
            if inboxShowsAll { query["all"] = "true" }
            let result = try await client.get("/notifications", query: query, as: [NotificationThread].self)
            interval = TimeInterval(result.pollInterval ?? 60)
            if result.changed || inbox.isEmpty {
                inbox = result.value
                handle(detectInbox(result.value))
            }
            lastGlobalPoll = .now
        } catch {
            lastError = error.localizedDescription
        }
        nextInboxPoll = Date.now.addingTimeInterval(max(interval, 30) * (appActive ? 1 : prefs.backgroundMultiplier) * rateMultiplier)
    }

    func pollViewer() async {
        guard let client, let login = me?.login else { return }
        do {
            let result = try await client.viewerPRs(login: login)
            myPRs = result.mine
            reviewRequests = result.reviews
        } catch {
            lastError = error.localizedDescription
        }
        let base: TimeInterval = myPRs.contains(where: { $0.checkState.isActive }) ? 45 : 120
        nextViewerPoll = Date.now.addingTimeInterval(base * (appActive ? 1 : prefs.backgroundMultiplier) * rateMultiplier)
    }

    private func detectInbox(_ threads: [NotificationThread]) -> [WatchEvent] {
        var out: [WatchEvent] = []
        for thread in threads where thread.unread {
            let previous = seenThreads[thread.id]
            seenThreads[thread.id] = thread.updatedAt
            guard inboxBaselineDone, previous == nil || thread.updatedAt > previous! else { continue }
            let kind: EventKind = switch thread.reason {
            case "review_requested": .prReviewRequested
            case "mention", "team_mention": .mention
            case "assign": .assigned
            default: .inboxOther
            }
            out.append(WatchEvent(kind: kind, repo: thread.repository.fullName, title: thread.subject.title,
                                  subtitle: thread.reasonLabel, url: thread.webURL, involvesMe: true, date: thread.updatedAt))
        }
        inboxBaselineDone = true
        return out
    }

    // MARK: Events → notifications

    func handle(_ events: [WatchEvent]) {
        guard !events.isEmpty else { return }
        var processed: [WatchEvent] = []
        for var event in events {
            if prefs.notificationsEnabled && !prefs.inQuietHours,
               let rule = prefs.rules.first(where: { $0.matches(event, me: me?.login) }) {
                notifier.post(event, sound: rule.playSound)
                event.notified = true
            }
            processed.append(event)
        }
        feed.insert(contentsOf: processed.sorted { $0.date > $1.date }, at: 0)
        if feed.count > 300 { feed.removeLast(feed.count - 300) }
    }

    // MARK: Inbox actions

    var unreadCount: Int { inbox.filter(\.unread).count }

    func markRead(_ thread: NotificationThread) async {
        guard let client else { return }
        try? await client.markThreadRead(thread.id)
        nextInboxPoll = .distantPast
        inbox.removeAll { $0.id == thread.id && !inboxShowsAll }
    }

    func markAllRead() async {
        guard let client else { return }
        try? await client.markAllNotificationsRead()
        if !inboxShowsAll { inbox.removeAll() }
        nextInboxPoll = Date.now.addingTimeInterval(3)
    }

    func open(_ thread: NotificationThread) {
        NSWorkspace.shared.open(thread.webURL)
        Task { await markRead(thread) }
    }

    // MARK: Aggregates

    var overallState: CIState {
        CIState.combine(watchedStores.map(\.ciState))
    }

    var failingStores: [RepoStore] { watchedStores.filter { $0.ciState == .failure } }
    var runningRuns: [(RepoStore, WorkflowRun)] {
        watchedStores.flatMap { s in s.activeRuns.map { (s, $0) } }
    }
    var myFailingPRs: [PRItem] { myPRs.filter { $0.checkState == .failure } }

    var attentionCount: Int { failingStores.count + reviewRequests.count + myFailingPRs.count }

    var coreRateLimit: RateLimit? { rateLimits["core"] }

    // MARK: Navigation

    func show(repo fullName: String, tab: RepoTab? = nil) {
        if !isWatched(fullName) { watch(fullName) }
        if let tab { repoStores[fullName]?.tab = tab }
        selection = .repo(fullName)
        activateMainWindow()
    }

    func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "GH Watcher" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    /// Set by the UI so non-view code can reopen the main window.
    @ObservationIgnored var openMainWindowAction: (() -> Void)?

    func applyDockPreference() {
        NSApp.setActivationPolicy(prefs.showInDock ? .regular : .accessory)
    }
}
