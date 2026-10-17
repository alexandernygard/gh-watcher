import SwiftUI

/// Parsed GitHub Actions job log.
struct JobLog {
    struct Line: Identifiable, Hashable {
        enum Level { case normal, error, warning, group, command }
        let id: Int
        let text: String
        let level: Level
    }

    let lines: [Line]

    private nonisolated(unsafe) static let ansi = try! Regex(#"\x1B\[[0-9;?]*[A-Za-z]"#)

    init(raw: String) {
        var out: [Line] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = Substring(rawLine)
            if text.last == "\r" { text = text.dropLast() }
            // Each line starts with an ISO timestamp: 2024-05-01T12:00:00.1234567Z
            if text.count > 28, text.dropFirst(4).first == "-", let space = text.firstIndex(of: " "),
               text.distance(from: text.startIndex, to: space) <= 34, text[text.index(before: space)] == "Z" {
                text = text[text.index(after: space)...]
            }
            var line = String(text)
            if line.contains("\u{1B}") { line = line.replacing(Self.ansi, with: "") }
            let level: Line.Level
            if line.hasPrefix("##[endgroup]") { continue }
            if line.hasPrefix("##[group]") {
                line.removeFirst("##[group]".count); level = .group
            } else if line.hasPrefix("##[error]") {
                line.removeFirst("##[error]".count); level = .error
            } else if line.hasPrefix("##[warning]") {
                line.removeFirst("##[warning]".count); level = .warning
            } else if line.hasPrefix("[command]") {
                line.removeFirst("[command]".count); level = .command
            } else if line.hasPrefix("##[") {
                if let close = line.firstIndex(of: "]") { line = String(line[line.index(after: close)...]) }
                level = .normal
            } else {
                level = .normal
            }
            out.append(Line(id: out.count, text: line, level: level))
        }
        while out.last?.text.isEmpty == true { out.removeLast() }
        lines = out
    }

    var errorCount: Int { lines.filter { $0.level == .error }.count }

    /// The part that explains the failure: from the start of the failing step (or up to 60 lines
    /// before the last error) to just after that error. Falls back to the tail of the log.
    var excerpt: ArraySlice<Line> {
        guard let lastError = lines.lastIndex(where: { $0.level == .error }) else {
            return lines.suffix(40)
        }
        // "Process completed with exit code 1" is usually the last error; the real output sits above it.
        let floor = max(0, lastError - 60)
        let groupStart = lines[floor...lastError].lastIndex(where: { $0.level == .group }) ?? floor
        let start = lastError - groupStart > 3 ? groupStart : floor
        var end = lastError
        while end + 1 < lines.count, end < lastError + 2, lines[end + 1].level == .normal || lines[end + 1].level == .error { end += 1 }
        return lines[start...end]
    }
}

/// Inline log viewer for a failed (or any finished) job.
struct JobLogView: View {
    @Environment(AppStore.self) private var store
    let repo: String
    let jobID: Int
    var webURL: URL?

    @State private var log: JobLog?
    @State private var error: String?
    @State private var showFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(showFull ? "Full log" : "Why it failed", systemImage: "text.alignleft")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let log, log.errorCount > 0 {
                    Chip(text: "\(log.errorCount) error\(log.errorCount == 1 ? "" : "s")", color: .ghRed)
                }
                Spacer()
                if let log {
                    Button(showFull ? "Show Less" : "Full Log (\(log.lines.count) lines)") { showFull.toggle() }
                        .buttonStyle(.link).font(.caption)
                    Button { copyToPasteboard(lines(log).map(\.text).joined(separator: "\n")) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy shown lines")
                }
                if let webURL {
                    Button { NSWorkspace.shared.open(webURL) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless).help("Open log on GitHub")
                }
            }
            Group {
                if let log {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines(log)) { line in
                                    text(line).id(line.id)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        }
                        .frame(height: showFull ? 460 : min(CGFloat(log.excerpt.count) * 15 + 24, 340))
                        .onAppear { proxy.scrollTo(log.excerpt.last?.id, anchor: .bottom) }
                        .onChange(of: showFull) { proxy.scrollTo(log.excerpt.last?.id, anchor: .bottom) }
                    }
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(10)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
        }
        .task(id: jobID) { await load() }
    }

    private func lines(_ log: JobLog) -> [JobLog.Line] {
        showFull ? Array(log.lines.suffix(4000)) : Array(log.excerpt)
    }

    private func text(_ line: JobLog.Line) -> some View {
        let color: Color = switch line.level {
        case .error: .ghRed
        case .warning: .ghAmber
        case .group: .primary
        case .command: .ghBlue
        case .normal: .primary.opacity(0.85)
        }
        return Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 11, weight: line.level == .group || line.level == .error ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .padding(.top, line.level == .group ? 4 : 0)
    }

    private func load() async {
        guard let client = store.client else { return }
        do {
            log = JobLog(raw: try await client.jobLog(repo, jobID: jobID))
            error = nil
        } catch GitHubError.http(404, _), GitHubError.http(410, _) {
            error = "The log isn't available (it may have expired or the job is still running)."
        } catch {
            self.error = "Couldn't load the log: \(error.localizedDescription)"
        }
    }
}

extension URL {
    /// Job ID from an Actions check run URL like …/actions/runs/123/job/456.
    var actionsJobID: Int? {
        let parts = pathComponents
        guard let i = parts.firstIndex(of: "job"), i + 1 < parts.count else { return nil }
        return Int(parts[i + 1])
    }
}
