import SwiftUI

// MARK: - Avatars

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let task = inflight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 20
    @State private var image: NSImage?

    init(url: URL?, size: CGFloat = 20) {
        self.url = url
        self.size = size
        _image = State(initialValue: Self.sized(url, size).flatMap { ImageCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Circle().fill(.quaternary)
                    .overlay(Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: url) {
            guard let sized = Self.sized(url, size) else { return }
            if let loaded = await ImageCache.shared.load(sized) { image = loaded }
        }
    }

    static func sized(_ url: URL?, _ size: CGFloat) -> URL? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (c.queryItems ?? []).filter { $0.name != "s" }
        items.append(URLQueryItem(name: "s", value: "\(Int(size * 2))"))
        c.queryItems = items
        return c.url
    }
}

// MARK: - Status

struct CIStatusIcon: View {
    let state: CIState
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state.color)
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state == .running)
            .help(state.label)
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct LabelChip: View {
    let name: String
    let hex: String

    var body: some View {
        let color = Color(hex: hex)
        Text(name)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color.mix(with: .primary, by: 0.35))
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
    }
}

struct BranchChip: View {
    let name: String
    var color: Color = .ghBlue

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
            Text(name).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(.caption2, design: .monospaced).weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct PRStateBadge: View {
    let state: String
    let isDraft: Bool

    var body: some View {
        let (label, color, icon): (String, Color, String) = {
            if isDraft && state == "OPEN" { return ("Draft", .secondary, "pencil.circle") }
            switch state {
            case "MERGED": return ("Merged", .ghPurple, "arrow.triangle.merge")
            case "CLOSED": return ("Closed", .ghRed, "xmark.circle")
            default: return ("Open", .ghGreen, "arrow.triangle.pull")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(color.gradient, in: Capsule())
    }
}

struct PRIcon: View {
    let state: String
    let isDraft: Bool

    var body: some View {
        let color: Color = isDraft ? .secondary : state == "MERGED" ? .ghPurple : state == "CLOSED" ? .ghRed : .ghGreen
        Image(systemName: state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull")
            .foregroundStyle(color)
            .font(.system(size: 13, weight: .semibold))
    }
}

struct ReviewDecisionBadge: View {
    let decision: String?

    var body: some View {
        switch decision {
        case "APPROVED": Chip(text: "Approved", color: .ghGreen, systemImage: "checkmark")
        case "CHANGES_REQUESTED": Chip(text: "Changes requested", color: .ghRed, systemImage: "exclamationmark.bubble")
        case "REVIEW_REQUIRED": Chip(text: "Review required", color: .ghAmber, systemImage: "eye")
        default: EmptyView()
        }
    }
}

struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Color.ghGreen)
            Text("−\(deletions)").foregroundStyle(Color.ghRed)
            DiffBar(additions: additions, deletions: deletions)
        }
        .font(.caption.monospacedDigit().weight(.medium))
    }
}

struct DiffBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = max(additions + deletions, 1)
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(additions + deletions == 0 ? Color.secondary.opacity(0.3) : i < green ? Color.ghGreen : Color.ghRed)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Layout helpers

struct Card<Content: View, Trailing: View>: View {
    let title: String?
    var systemImage: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    if let systemImage {
                        Label(title, systemImage: systemImage).font(.headline)
                    } else {
                        Text(title).font(.headline)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title2.weight(.bold)).monospacedDigit().contentTransition(.numericText())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

struct Ago: View {
    let date: Date
    var body: some View {
        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

extension TimeInterval {
    var durationString: String {
        let s = Int(self)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ghRed.gradient, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Runs an async GitHub action and surfaces errors.
@MainActor
@Observable
final class ActionRunner {
    var isRunning = false
    var error: String?

    func run(_ work: @escaping () async throws -> Void) {
        isRunning = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            isRunning = false
        }
    }
}

extension View {
    func openOnClick(_ url: URL?) -> some View {
        self.contentShape(Rectangle()).onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
    }

    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// Bell toggle that follows a run or pull request and notifies on its next change.
struct FollowButton: View {
    @Environment(AppStore.self) private var store
    let follow: Follow
    var runActive = true

    var body: some View {
        let on = store.isFollowing(follow)
        Button { store.toggleFollow(follow) } label: {
            Image(systemName: on ? "bell.fill" : "bell")
                .foregroundStyle(on ? Color.ghAmber : .primary)
        }
        .help(on ? "Following — click to stop (⌘⇧F)" : follow.isRun
              ? (runActive ? "Notify me when this run finishes (⌘⇧F)" : "Notify me when the next attempt of this run finishes (⌘⇧F)")
              : "Notify me about reviews, comments, checks and merges (⌘⇧F)")
    }
}
