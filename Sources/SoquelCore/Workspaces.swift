import AppKit

/// A saved arrangement of panes and tabs, reopened by name.
///
/// Session restore already brings back whatever was open; this is the step
/// beyond that the research records as a stated purchase reason — named
/// layouts per project, switched deliberately rather than inherited from
/// whatever happened to be open last.
struct Workspace: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// One entry per pane; each is that pane's tab paths, in order.
    var panes: [[String]]
    /// Which tab was in front, per pane.
    var activeTabs: [Int]
    /// The orientation of the outermost split. Kept for workspaces saved
    /// before `layout` existed, and as the shape to fall back to.
    var isVerticalSplit: Bool
    /// How the panes are arranged, as indices into `panes`.
    ///
    /// Absent in anything saved before nested splits, which reopens as a
    /// single row or column — the old format could not express a tree.
    var layout: LayoutNode?

    /// A saved arrangement. Panes are indices rather than identifiers because
    /// identifiers are made fresh each run.
    indirect enum LayoutNode: Codable, Equatable {
        case pane(Int)
        case split(vertical: Bool, children: [LayoutNode])

        /// Every pane index, in reading order.
        var indices: [Int] {
            switch self {
            case .pane(let index): return [index]
            case .split(_, let children): return children.flatMap(\.indices)
            }
        }

        /// Drops panes whose folders have gone, collapsing any split left
        /// holding one child. Returns nil when nothing survives.
        func keeping(_ surviving: Set<Int>) -> LayoutNode? {
            switch self {
            case .pane(let index):
                return surviving.contains(index) ? self : nil
            case .split(let vertical, let children):
                let remaining = children.compactMap { $0.keeping(surviving) }
                switch remaining.count {
                case 0: return nil
                case 1: return remaining[0]
                default: return .split(vertical: vertical, children: remaining)
                }
            }
        }

        /// Renumbers after panes have been dropped, so the indices line up
        /// with the shortened list.
        func renumbered(_ mapping: [Int: Int]) -> LayoutNode? {
            switch self {
            case .pane(let index):
                return mapping[index].map { .pane($0) }
            case .split(let vertical, let children):
                let remaining = children.compactMap { $0.renumbered(mapping) }
                switch remaining.count {
                case 0: return nil
                case 1: return remaining[0]
                default: return .split(vertical: vertical, children: remaining)
                }
            }
        }
    }

    /// Only the folders that still exist, so a workspace survives a moved
    /// project rather than failing to open at all.
    func survivingPanes() -> [[String]] {
        survivingPanesWithIndices().map(\.tabs)
    }

    /// The surviving panes, each with the position it had when saved, so the
    /// arrangement can be rebuilt around the gaps.
    func survivingPanesWithIndices() -> [(index: Int, tabs: [String])] {
        panes.enumerated().compactMap { index, tabs in
            let present = tabs.filter { FileManager.default.fileExists(atPath: $0) }
            return present.isEmpty ? nil : (index, present)
        }
    }

    /// The arrangement to rebuild, with dropped panes removed and the rest
    /// renumbered. Nil when the workspace predates nested splits or nothing of
    /// its arrangement survives, in which case a flat row is the answer.
    func survivingLayout(
        _ precomputed: [(index: Int, tabs: [String])]? = nil
    ) -> LayoutNode? {
        guard let layout else { return nil }
        // Callers that already scanned pass their result in, so the layout is
        // built from the same snapshot the panes were.
        let surviving = precomputed ?? survivingPanesWithIndices()
        let mapping = Dictionary(
            uniqueKeysWithValues: surviving.enumerated().map { ($1.index, $0) }
        )
        return layout.keeping(Set(mapping.keys))?.renumbered(mapping)
    }

    var isUsable: Bool { !survivingPanes().isEmpty }

    /// "3 panes · Website" for the menu subtitle.
    var summary: String {
        let count = panes.count
        return "\(count) pane\(count == 1 ? "" : "s")"
    }
}

/// Loads and saves workspaces as readable JSON, as the spec asks.
enum WorkspaceStore {
    static var fileURL: URL {
        ThemeConfig.directoryURL.appendingPathComponent("workspaces.json")
    }

    static var all: [Workspace] = load() {
        didSet {
            guard all != oldValue else { return }
            save()
            NotificationCenter.default.post(name: .soquelWorkspacesChanged, object: nil)
        }
    }

    private static func load() -> [Workspace] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Workspace].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save() {
        try? FileManager.default.createDirectory(
            at: ThemeConfig.directoryURL, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func add(_ workspace: Workspace) {
        // Saving under a name that already exists replaces it, which is what
        // "save workspace" means when you have rearranged the panes.
        var current = all
        current.removeAll { $0.name.caseInsensitiveCompare(workspace.name) == .orderedSame }
        current.append(workspace)
        all = current
    }

    static func remove(id: UUID) {
        all.removeAll { $0.id == id }
    }

    static func rename(id: UUID, to name: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        var current = all
        current[index].name = name
        all = current
    }

    static func workspace(named name: String) -> Workspace? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

extension Notification.Name {
    static let soquelWorkspacesChanged = Notification.Name("app.soquel.workspacesChanged")
}
