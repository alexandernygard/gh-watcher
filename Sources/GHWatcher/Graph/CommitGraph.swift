import Foundation

struct GraphCommit: Identifiable, Hashable, Sendable {
    let id: String
    let message: String
    let date: Date
    let authorName: String
    let authorLogin: String?
    let avatar: URL?
    let parents: [String]
    let checkState: CIState
    let url: URL?

    var shortSha: String { String(id.prefix(7)) }
}

struct GraphRow: Identifiable, Hashable, Sendable {
    enum Segment: Hashable, Sendable {
        /// Vertical line passing through the row in a lane not touching this commit.
        case through(lane: Int, color: Int)
        /// Line from the top of the row in `from` into the node.
        case into(from: Int, color: Int)
        /// Line from the node to the bottom of the row in lane `to`.
        case out(to: Int, color: Int)
        /// Parent that is outside the loaded window.
        case stub(lane: Int, color: Int)
    }

    var id: String { commit.id }
    let commit: GraphCommit
    let lane: Int
    let color: Int
    let segments: [Segment]
    let branches: [String]
    let tags: [String]
    var isMerge: Bool { commit.parents.count > 1 }
}

struct CommitGraph: Sendable {
    let rows: [GraphRow]
    let laneCount: Int
    let defaultBranch: String?
    let branchNames: [String]

    static func build(from response: GraphResponse) -> CommitGraph {
        guard let repo = response.repository else {
            return CommitGraph(rows: [], laneCount: 0, defaultBranch: nil, branchNames: [])
        }
        var commits: [String: GraphCommit] = [:]
        var heads: [String: [String]] = [:]
        var tags: [String: [String]] = [:]
        var branchNames: [String] = []

        var refs = repo.refs.items
        if let def = repo.defaultBranchRef {
            refs.removeAll { $0.name == def.name }
            refs.insert(def, at: 0)
        }
        for ref in refs {
            guard let target = ref.target else { continue }
            branchNames.append(ref.name)
            heads[target.oid, default: []].append(ref.name)
            for c in target.history?.items ?? [] where commits[c.oid] == nil {
                commits[c.oid] = GraphCommit(
                    id: c.oid,
                    message: c.messageHeadline,
                    date: c.committedDate,
                    authorName: c.author?.name ?? c.author?.user?.login ?? "Unknown",
                    authorLogin: c.author?.user?.login,
                    avatar: c.author?.user?.avatarUrl,
                    parents: c.parents?.items.map(\.oid) ?? [],
                    checkState: CIState(rollup: c.statusCheckRollup?.state),
                    url: c.url
                )
            }
        }
        for tag in repo.tags.items {
            if let oid = tag.commitOid { tags[oid, default: []].append(tag.name) }
        }
        return layout(Array(commits.values), heads: heads, tags: tags, defaultBranch: repo.defaultBranchRef?.name, branchNames: branchNames)
    }

    static func layout(_ commits: [GraphCommit], heads: [String: [String]], tags: [String: [String]],
                       defaultBranch: String?, branchNames: [String]) -> CommitGraph {
        let byID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = topoSort(commits, byID: byID)

        // Keep the default branch on lane 0 by seeding its head first.
        var lanes: [String?] = []
        var laneColors: [Int] = []
        var nextColor = 0
        var maxLanes = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(ordered.count)

        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            laneColors.append(0)
            return lanes.count - 1
        }

        for commit in ordered {
            var segments: [GraphRow.Segment] = []
            let matching = lanes.indices.filter { lanes[$0] == commit.id }

            let lane: Int
            let color: Int
            if let first = matching.first {
                lane = first
                color = laneColors[first]
            } else {
                lane = freeLane()
                color = nextColor
                nextColor += 1
                laneColors[lane] = color
            }

            for m in matching {
                segments.append(.into(from: m, color: laneColors[m]))
                lanes[m] = nil
            }
            for (i, sha) in lanes.enumerated() where sha != nil {
                segments.append(.through(lane: i, color: laneColors[i]))
            }

            for (index, parent) in commit.parents.enumerated() {
                guard byID[parent] != nil else {
                    if index == 0 { segments.append(.stub(lane: lane, color: color)) }
                    continue
                }
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    segments.append(.out(to: existing, color: index == 0 ? color : laneColors[existing]))
                } else if index == 0 {
                    lanes[lane] = parent
                    laneColors[lane] = color
                    segments.append(.out(to: lane, color: color))
                } else {
                    let newLane = freeLane()
                    lanes[newLane] = parent
                    laneColors[newLane] = nextColor
                    nextColor += 1
                    segments.append(.out(to: newLane, color: laneColors[newLane]))
                }
            }

            maxLanes = max(maxLanes, lanes.count, lane + 1)
            rows.append(GraphRow(commit: commit, lane: lane, color: color, segments: segments,
                                 branches: heads[commit.id] ?? [], tags: tags[commit.id] ?? []))

            while let last = lanes.last, last == nil {
                lanes.removeLast()
                laneColors.removeLast()
            }
        }
        return CommitGraph(rows: rows, laneCount: maxLanes, defaultBranch: defaultBranch, branchNames: branchNames)
    }

    /// Children always before parents; among ready commits, newest first.
    static func topoSort(_ commits: [GraphCommit], byID: [String: GraphCommit]) -> [GraphCommit] {
        var pendingChildren: [String: Int] = [:]
        for c in byID.values {
            for p in c.parents where byID[p] != nil { pendingChildren[p, default: 0] += 1 }
        }
        var ready = byID.values.filter { pendingChildren[$0.id, default: 0] == 0 }
        var result: [GraphCommit] = []
        result.reserveCapacity(byID.count)
        while !ready.isEmpty {
            var best = 0
            for i in ready.indices where ready[i].date > ready[best].date { best = i }
            let c = ready.remove(at: best)
            result.append(c)
            for p in c.parents where byID[p] != nil {
                pendingChildren[p, default: 0] -= 1
                if pendingChildren[p] == 0, let parent = byID[p] { ready.append(parent) }
            }
        }
        return result
    }
}
