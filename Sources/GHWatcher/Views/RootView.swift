import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.isSignedIn {
                MainSplitView()
            } else if store.isBootstrapping {
                ProgressView("Connecting to GitHub…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SignInView()
            }
        }
        .onAppear {
            store.openMainWindowAction = { openWindow(id: "main") }
        }
    }
}

struct SignInView: View {
    @Environment(AppStore.self) private var store
    @State private var token = ""

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.linearGradient(colors: [.ghPurple, .ghBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 6) {
                Text("Welcome to GH Watcher").font(.largeTitle.bold())
                Text("Keep an eye on your repositories, pull requests and CI, live.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                Button {
                    Task { if let t = await store.auth.useGHCLI() { await store.signIn(token: t) } }
                } label: {
                    Label("Continue with GitHub CLI", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!store.auth.ghCLIAvailable || store.auth.isWorking)

                HStack {
                    VStack { Divider() }
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    VStack { Divider() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Personal access token (repo, workflow, notifications, read:org)", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signInWithToken)
                    Link("Create a token on GitHub…", destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow,notifications,read:org&description=GH%20Watcher")!)
                        .font(.caption)
                }
                Button("Sign In with Token", action: signInWithToken)
                    .controlSize(.large)
                    .disabled(token.isEmpty || store.auth.isWorking)
            }
            .frame(width: 380)

            if store.auth.isWorking { ProgressView().controlSize(.small) }
            if let error = store.auth.error {
                Text(error).foregroundStyle(Color.ghRed).font(.callout).multilineTextAlignment(.center).frame(width: 380)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signInWithToken() {
        let t = store.auth.useManual(token)
        Task { await store.signIn(token: t) }
    }
}

struct MainSplitView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            DetailRouter(item: store.selection)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RateLimitIndicator()
            }
        }
    }
}

struct DetailRouter: View {
    @Environment(AppStore.self) private var store
    let item: SidebarItem?

    var body: some View {
        switch item ?? .overview {
        case .overview:
            OverviewView()
        case .inbox:
            InboxView()
        case .myPRs:
            PRCollectionView(title: "My Pull Requests", subtitle: "Open pull requests you authored", prs: store.myPRs, emptySymbol: "arrow.triangle.pull")
        case .reviews:
            PRCollectionView(title: "Review Requests", subtitle: "Pull requests waiting on your review", prs: store.reviewRequests, emptySymbol: "eye")
        case .feed:
            FeedView()
        case .repo(let name):
            if let repoStore = store.repoStores[name] {
                RepoDetailView(repoStore: repoStore).id(name)
            } else {
                ContentUnavailableView("Repository not watched", systemImage: "eye.slash")
            }
        }
    }
}

struct RateLimitIndicator: View {
    @Environment(AppStore.self) private var store
    @State private var showDetails = false

    var body: some View {
        let core = store.coreRateLimit
        Button { showDetails.toggle() } label: {
            HStack(spacing: 5) {
                Gauge(value: core?.fraction ?? 1) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(gaugeColor(core?.fraction ?? 1))
                    .scaleEffect(0.42)
                    .frame(width: 20, height: 20)
            }
        }
        .help("API budget: \(core?.remaining ?? 0) of \(core?.limit ?? 5000) requests left")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            RateLimitDetails().environment(store).padding().frame(width: 280)
        }
    }

    private func gaugeColor(_ f: Double) -> Color { f > 0.5 ? .ghGreen : f > 0.2 ? .ghAmber : .ghRed }
}

struct RateLimitDetails: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API Budget").font(.headline)
            ForEach(store.rateLimits.values.sorted { $0.resource < $1.resource }, id: \.resource) { limit in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(limit.resource.capitalized).font(.callout.weight(.medium))
                        Spacer()
                        Text("\(limit.remaining) / \(limit.limit)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: limit.fraction)
                    Text("Resets \(limit.reset, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Polls use ETags, so unchanged responses come back as 304 and don't count against your limit. Intervals stretch automatically when the budget runs low or the app is in the background.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
