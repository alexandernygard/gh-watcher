import SwiftUI

/// Lightweight GitHub-flavoured markdown renderer: headings, lists, task lists, quotes,
/// fenced code and inline formatting. Good enough for issue and PR bodies.
struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, checked: Bool?, indent: Int)
        case numbered(String, String)
        case quote(String)
        case code(String, String?)
        case rule
    }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let s):
            inline(s)
        case .bullet(let s, let checked, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.ghGreen : .secondary)
                } else {
                    Text("•").foregroundStyle(.secondary)
                }
                inline(s)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n + ".").foregroundStyle(.secondary).monospacedDigit()
                inline(s)
            }
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                inline(s).foregroundStyle(.secondary)
            }
        case .code(let s, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: s, options: options) {
            return Text(attributed)
        }
        return Text(s)
    }

    private static func parse(_ raw: String) -> [Block] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // Strip HTML comments (PR templates are full of them).
        while let start = text.range(of: "<!--"), let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var blocks: [Block] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLang: String?
        var code: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n"), codeLang))
                    code = []
                    inCode = false
                } else {
                    flush()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3))
                }
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flush(); continue }

            let indent = (line.prefix(while: { $0 == " " }).count) / 2
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).first == " " {
                    flush()
                    blocks.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); blocks.append(.rule); continue }
            if trimmed.hasPrefix("> ") || trimmed == ">" { flush(); blocks.append(.quote(String(trimmed.dropFirst(2)))); continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush()
                var item = String(trimmed.dropFirst(2))
                var checked: Bool?
                if item.hasPrefix("[ ] ") { checked = false; item.removeFirst(4) }
                else if item.lowercased().hasPrefix("[x] ") { checked = true; item.removeFirst(4) }
                blocks.append(.bullet(item, checked: checked, indent: indent))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(String(trimmed[..<dot]), String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
                continue
            }
            // Images become links; bare HTML tags are dropped.
            var cleaned = line.replacingOccurrences(of: "![", with: "[")
            cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !cleaned.trimmingCharacters(in: .whitespaces).isEmpty { paragraph.append(cleaned) }
        }
        if inCode { blocks.append(.code(code.joined(separator: "\n"), codeLang)) }
        flush()
        return blocks
    }
}
