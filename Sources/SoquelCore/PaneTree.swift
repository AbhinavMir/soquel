import Foundation

/// How the panes in a window are arranged.
///
/// One `NSSplitView` per window means one orientation for the whole window:
/// asking for a horizontal split when the window is already split vertically
/// has to reflow everything. A tree lets the two mix, so splitting the
/// right-hand pane horizontally leaves the left one alone.
indirect enum PaneNode: Equatable {
    /// One pane, identified by the controller it stands for.
    case leaf(UUID)
    /// Several nodes side by side (`vertical`) or stacked.
    case split(id: UUID, vertical: Bool, children: [PaneNode])

    // MARK: - Reading

    /// Every pane, left to right and top to bottom. This is the order the
    /// focus shortcuts and the saved session use.
    var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let children): return children.flatMap(\.leaves)
        }
    }

    var leafCount: Int { leaves.count }

    func contains(_ leaf: UUID) -> Bool { leaves.contains(leaf) }

    /// How deeply nested the arrangement is. A single pane is 0.
    var depth: Int {
        switch self {
        case .leaf: return 0
        case .split(_, _, let children): return 1 + (children.map(\.depth).max() ?? 0)
        }
    }

    /// Every split in the tree, for restoring divider positions after a rebuild.
    var splitIDs: [UUID] {
        switch self {
        case .leaf: return []
        case .split(let id, _, let children): return [id] + children.flatMap(\.splitIDs)
        }
    }

    // MARK: - Editing

    /// Splits `target` in two, putting `newLeaf` after it.
    ///
    /// When the pane's own container already runs in the requested direction
    /// the new pane joins it as a sibling; nesting a vertical split inside a
    /// vertical split would add a divider and change nothing.
    func splitting(_ target: UUID, vertical: Bool, into newLeaf: UUID, splitID: UUID) -> PaneNode {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(id: splitID, vertical: vertical, children: [.leaf(id), .leaf(newLeaf)])

        case .split(let id, let isVertical, let children):
            guard contains(target) else { return self }

            if isVertical == vertical,
               let index = children.firstIndex(of: .leaf(target)) {
                var updated = children
                updated.insert(.leaf(newLeaf), at: index + 1)
                return .split(id: id, vertical: isVertical, children: updated)
            }

            return .split(id: id, vertical: isVertical, children: children.map {
                $0.splitting(target, vertical: vertical, into: newLeaf, splitID: splitID)
            })
        }
    }

    /// Removes a pane. Returns nil when the tree had nothing else in it.
    ///
    /// A split left holding one child is replaced by that child: an
    /// arrangement should never keep a divider with nothing on one side of it.
    func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self

        case .split(let id, let vertical, let children):
            let remaining = children.compactMap { $0.removing(target) }
            switch remaining.count {
            case 0: return nil
            case 1: return remaining[0]
            default: return .split(id: id, vertical: vertical, children: remaining)
            }
        }
    }

    /// The pane after `leaf` in reading order, wrapping at the end.
    func leaf(after leaf: UUID) -> UUID? {
        let all = leaves
        guard let index = all.firstIndex(of: leaf), !all.isEmpty else { return all.first }
        return all[(index + 1) % all.count]
    }

    func leaf(before leaf: UUID) -> UUID? {
        let all = leaves
        guard let index = all.firstIndex(of: leaf), !all.isEmpty else { return all.last }
        return all[(index - 1 + all.count) % all.count]
    }

    /// Flips the orientation of the split directly holding `leaf`, which is
    /// what "rotate" means when the window is a tree rather than a row.
    func rotatingContainer(of leaf: UUID) -> PaneNode {
        switch self {
        case .leaf: return self
        case .split(let id, let vertical, let children):
            if children.contains(.leaf(leaf)) {
                return .split(id: id, vertical: !vertical, children: children)
            }
            return .split(id: id, vertical: vertical, children: children.map {
                $0.rotatingContainer(of: leaf)
            })
        }
    }
}

// MARK: - Saving and restoring an arrangement

extension PaneNode {
    /// The arrangement as indices into a flat pane list, for a workspace.
    /// Identifiers are made fresh each run, so they cannot be what is stored.
    func indexed(by order: [UUID]) -> Workspace.LayoutNode? {
        switch self {
        case .leaf(let id):
            return order.firstIndex(of: id).map { .pane($0) }
        case .split(_, let vertical, let children):
            let mapped = children.compactMap { $0.indexed(by: order) }
            switch mapped.count {
            case 0: return nil
            case 1: return mapped[0]
            default: return .split(vertical: vertical, children: mapped)
            }
        }
    }

    /// Rebuilds an arrangement from saved indices. `paneIDs` maps each index to
    /// the pane created for it; an index with no pane is dropped, and a split
    /// left holding one child collapses.
    static func rebuilt(from node: Workspace.LayoutNode, paneIDs: [Int: UUID]) -> PaneNode? {
        switch node {
        case .pane(let index):
            return paneIDs[index].map { .leaf($0) }
        case .split(let vertical, let children):
            let mapped = children.compactMap { rebuilt(from: $0, paneIDs: paneIDs) }
            switch mapped.count {
            case 0: return nil
            case 1: return mapped[0]
            default: return .split(id: UUID(), vertical: vertical, children: mapped)
            }
        }
    }
}
