import Foundation

/// One entry in the layer tree: a raster layer, a group (folder) or an adjustment layer.
public struct LayerNode: Identifiable, Codable, Equatable {
    public enum Content: Codable, Equatable {
        case raster
        case group(children: [LayerNode], expanded: Bool)
        case adjustment(AdjustmentSettings)
    }

    public var id = UUID()
    public var name: String
    public var content: Content
    public var isVisible = true
    public var opacity: Float = 1
    public var blendMode: BlendMode = .normal
    /// Locked layers can't be painted, moved or deleted.
    public var isLocked = false
    /// Painting changes colour only where the layer already has paint.
    public var alphaLocked = false
    /// Clipping mask: this layer only shows through the opaque parts of the layer below it.
    public var clipsToBelow = false
    /// Reference layer: the fill tool reads boundaries from it (Procreate's "Reference").
    public var isReference = false
    /// Has a greyscale layer mask (white shows, black hides).
    public var hasMask = false
    public var maskEnabled = true

    public init(name: String, content: Content = .raster) {
        self.name = name
        self.content = content
    }

    public var isRaster: Bool { if case .raster = content { return true }; return false }
    public var isGroup: Bool { if case .group = content { return true }; return false }
    public var isAdjustment: Bool { if case .adjustment = content { return true }; return false }

    public var children: [LayerNode] {
        get { if case .group(let c, _) = content { return c }; return [] }
        set { if case .group(_, let e) = content { content = .group(children: newValue, expanded: e) } }
    }

    public var isExpanded: Bool {
        get { if case .group(_, let e) = content { return e }; return false }
        set { if case .group(let c, _) = content { content = .group(children: c, expanded: newValue) } }
    }

    public var adjustment: AdjustmentSettings? {
        get { if case .adjustment(let a) = content { return a }; return nil }
        set { if let a = newValue, isAdjustment { content = .adjustment(a) } }
    }
}

/// The layer tree. `nodes` (and every group's children) run **bottom → top**, the compositing order;
/// the layers panel shows them reversed.
public struct LayerStack: Codable, Equatable {
    public var nodes: [LayerNode]

    public init(nodes: [LayerNode] = []) { self.nodes = nodes }

    // MARK: Lookup

    public func node(_ id: UUID) -> LayerNode? {
        func find(_ list: [LayerNode]) -> LayerNode? {
            for n in list {
                if n.id == id { return n }
                if let f = find(n.children) { return f }
            }
            return nil
        }
        return find(nodes)
    }

    /// Index path from the root to `id` (e.g. [2, 0] = first child of the third root node).
    public func path(to id: UUID) -> [Int]? {
        func search(_ list: [LayerNode], _ prefix: [Int]) -> [Int]? {
            for (i, n) in list.enumerated() {
                if n.id == id { return prefix + [i] }
                if let p = search(n.children, prefix + [i]) { return p }
            }
            return nil
        }
        return search(nodes, [])
    }

    public func parentID(of id: UUID) -> UUID? {
        guard let p = path(to: id), p.count > 1 else { return nil }
        return node(at: Array(p.dropLast()))?.id
    }

    public func node(at path: [Int]) -> LayerNode? {
        var list = nodes
        var current: LayerNode?
        for i in path {
            guard list.indices.contains(i) else { return nil }
            current = list[i]
            list = list[i].children
        }
        return current
    }

    /// Siblings of `id`, bottom → top, including itself.
    public func siblings(of id: UUID) -> [LayerNode] {
        if let parent = parentID(of: id) { return node(parent)?.children ?? [] }
        return nodes
    }

    /// Every node, depth-first, bottom → top.
    public var allNodes: [LayerNode] {
        func walk(_ list: [LayerNode]) -> [LayerNode] { list.flatMap { [$0] + walk($0.children) } }
        return walk(nodes)
    }

    public var rasterIDs: [UUID] { allNodes.filter(\.isRaster).map(\.id) }
    public var count: Int { allNodes.count }

    /// Hidden if the node or any enclosing group is hidden.
    public func isEffectivelyVisible(_ id: UUID) -> Bool {
        guard let p = path(to: id) else { return false }
        for k in 1...p.count where node(at: Array(p.prefix(k)))?.isVisible == false { return false }
        return true
    }

    /// Locked if the node or any enclosing group is locked.
    public func isEffectivelyLocked(_ id: UUID) -> Bool {
        guard let p = path(to: id) else { return true }
        for k in 1...p.count where node(at: Array(p.prefix(k)))?.isLocked == true { return true }
        return false
    }

    /// The sibling directly below `id`, if any.
    public func nodeBelow(_ id: UUID) -> LayerNode? {
        let s = siblings(of: id)
        guard let i = s.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
        return s[i - 1]
    }

    public func nodeAbove(_ id: UUID) -> LayerNode? {
        let s = siblings(of: id)
        guard let i = s.firstIndex(where: { $0.id == id }), i + 1 < s.count else { return nil }
        return s[i + 1]
    }

    // MARK: Editing

    private static func modify(_ list: inout [LayerNode], path: ArraySlice<Int>, _ body: (inout [LayerNode], Int) -> Void) {
        guard let first = path.first, list.indices.contains(first) else { return }
        if path.count == 1 {
            body(&list, first)
        } else {
            var kids = list[first].children
            modify(&kids, path: path.dropFirst(), body)
            list[first].children = kids
        }
    }

    public mutating func update(_ id: UUID, _ body: (inout LayerNode) -> Void) {
        guard let p = path(to: id) else { return }
        Self.modify(&nodes, path: p[...]) { list, i in body(&list[i]) }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> LayerNode? {
        guard let p = path(to: id) else { return nil }
        var removed: LayerNode?
        Self.modify(&nodes, path: p[...]) { list, i in removed = list.remove(at: i) }
        return removed
    }

    /// Inserts `node` directly above `sibling` (same parent), or at the top of the root if nil/missing.
    public mutating func insert(_ node: LayerNode, above sibling: UUID?) {
        guard let sibling, let p = path(to: sibling) else { nodes.append(node); return }
        Self.modify(&nodes, path: p[...]) { list, i in list.insert(node, at: i + 1) }
    }

    /// Inserts `node` directly below `sibling` (same parent).
    public mutating func insert(_ node: LayerNode, below sibling: UUID) {
        guard let p = path(to: sibling) else { nodes.insert(node, at: 0); return }
        Self.modify(&nodes, path: p[...]) { list, i in list.insert(node, at: i) }
    }

    /// Inserts `node` as the top child of group `groupID`.
    public mutating func insert(_ node: LayerNode, intoGroup groupID: UUID) {
        update(groupID) { g in
            guard g.isGroup else { return }
            g.children.append(node)
        }
    }

    /// Moves `id` to sit directly above `target` (or top of root when nil). No-op for invalid moves
    /// (e.g. into its own descendant).
    public mutating func move(_ id: UUID, above target: UUID?) {
        guard id != target, let moving = node(id) else { return }
        if let target, moving.isGroup, LayerStack(nodes: moving.children).node(target) != nil { return }
        remove(id)
        insert(moving, above: target)
    }

    public mutating func move(_ id: UUID, below target: UUID) {
        guard id != target, let moving = node(id) else { return }
        if moving.isGroup, LayerStack(nodes: moving.children).node(target) != nil { return }
        remove(id)
        insert(moving, below: target)
    }

    public mutating func move(_ id: UUID, intoGroup groupID: UUID) {
        guard id != groupID, let moving = node(id), node(groupID)?.isGroup == true else { return }
        if moving.isGroup, LayerStack(nodes: moving.children).node(groupID) != nil { return }
        remove(id)
        insert(moving, intoGroup: groupID)
    }

    /// Wraps the given sibling nodes into a new group placed where the topmost one was.
    @discardableResult
    public mutating func group(_ ids: [UUID], name: String) -> UUID? {
        let members = ids.compactMap { node($0) }
        guard let top = ids.last, !members.isEmpty, let anchorPath = path(to: top) else { return nil }
        let parent = parentID(of: top)
        guard members.allSatisfy({ parentID(of: $0.id) == parent }) else { return nil }
        let ordered = siblings(of: top).filter { ids.contains($0.id) }
        let group = LayerNode(name: name, content: .group(children: ordered, expanded: true))
        let placeholder = LayerNode(name: "__placeholder__")
        Self.modify(&nodes, path: anchorPath[...]) { list, i in list.insert(placeholder, at: i + 1) }
        for id in ids { remove(id) }
        if let p = path(to: placeholder.id) {
            Self.modify(&nodes, path: p[...]) { list, i in list[i] = group }
        }
        return group.id
    }

    /// Replaces a group with its children (in place).
    public mutating func ungroup(_ groupID: UUID) {
        guard let g = node(groupID), g.isGroup, let p = path(to: groupID) else { return }
        Self.modify(&nodes, path: p[...]) { list, i in
            list.remove(at: i)
            list.insert(contentsOf: g.children, at: i)
        }
    }
}
