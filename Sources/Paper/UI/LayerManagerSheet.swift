import SwiftUI

/// The layers panel: a tree (top layer first) with thumbnails, visibility, drag-to-reorder, groups,
/// blend modes, opacity, clipping, alpha lock, reference, lock, masks and adjustment layers.
public struct LayerManagerSheet: View {
    let document: CanvasDocument
    @State private var renaming: UUID?
    @State private var renameText = ""

    public init(document: CanvasDocument) { self.document = document }

    /// Rows top → bottom with their nesting depth.
    private var rows: [(node: LayerNode, depth: Int)] {
        func walk(_ list: [LayerNode], _ depth: Int) -> [(LayerNode, Int)] {
            list.reversed().flatMap { n -> [(LayerNode, Int)] in
                [(n, depth)] + (n.isGroup && n.isExpanded ? walk(n.children, depth + 1) : [])
            }
        }
        return walk(document.layers.nodes, 0)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Menu {
                    ForEach(AdjustmentKind.allCases) { k in
                        Button(k.displayName) { document.addAdjustmentLayer(k) }
                    }
                } label: { Image(systemName: "camera.filters") }
                    .menuStyle(.borderlessButton).fixedSize().help("New adjustment layer")
                Button { document.addGroup() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless).help("New group")
                Button { document.addLayer() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New layer (⇧⌘N)")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows, id: \.node.id) { row in
                        layerRow(row.node, depth: row.depth)
                    }
                    backgroundRow
                }
                .padding(.horizontal, 6)
            }

            if let active = document.activeLayer {
                Divider()
                activeLayerControls(active).padding(12)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func layerRow(_ node: LayerNode, depth: Int) -> some View {
        let active = document.activeLayerID == node.id
        HStack(spacing: 6) {
            if node.clipsToBelow {
                Image(systemName: "arrow.turn.left.down").font(.caption).foregroundStyle(.secondary)
            }
            if node.isGroup {
                Button { document.setExpanded(node.id, !node.isExpanded) } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right").font(.caption.bold())
                }
                .buttonStyle(.plain).frame(width: 14)
            }
            thumbnail(node)
            if node.hasMask { maskBadge(node) }
            VStack(alignment: .leading, spacing: 1) {
                if renaming == node.id {
                    TextField("Name", text: $renameText, onCommit: {
                        document.rename(node.id, to: renameText)
                        renaming = nil
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    Text(node.name).lineLimit(1).font(.callout.weight(active ? .semibold : .regular))
                }
                HStack(spacing: 4) {
                    Text(node.blendMode == .normal ? "" : node.blendMode.displayName)
                    if node.opacity < 0.999 { Text("\(Int(node.opacity * 100))%") }
                    if node.isReference { Text("Reference").foregroundStyle(Color.accentColor) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if node.alphaLocked { Image(systemName: "checkerboard.rectangle").font(.caption).foregroundStyle(.secondary) }
            if node.isLocked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            Button { document.setVisible(node.id, !node.isVisible) } label: {
                Image(systemName: node.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(node.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 16)
        .background(active ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { renameText = node.name; renaming = node.id }
        .onTapGesture { document.activeLayerID = node.id; document.editingMask = false }
        .draggable(node.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s), id != node.id else { return false }
            if node.isGroup && node.isExpanded { document.moveLayer(id, intoGroup: node.id) }
            else { document.moveLayer(id, above: node.id) }
            return true
        }
        .contextMenu { contextMenu(node) }
    }

    private func thumbnail(_ node: LayerNode) -> some View {
        ZStack {
            CheckerboardView().clipShape(RoundedRectangle(cornerRadius: 4))
            if let img = document.thumbnails[node.id] {
                Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
            } else if node.isGroup {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
            } else if node.isAdjustment {
                Image(systemName: "camera.filters").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 34)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.35)))
    }

    private func maskBadge(_ node: LayerNode) -> some View {
        let editing = document.editingMask && document.activeLayerID == node.id
        return Button {
            document.activeLayerID = node.id
            document.editingMask = true
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [.white, .black], startPoint: .leading, endPoint: .trailing))
                .frame(width: 24, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(editing ? Color.accentColor : .secondary.opacity(0.4),
                                                                   lineWidth: editing ? 2 : 1))
                .opacity(node.maskEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help("Layer mask — click to paint on it (white shows, black hides)")
    }

    private var backgroundRow: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(Color(p3: document.background)).frame(width: 44, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.35)))
            Text("Background color").font(.callout)
            Spacer()
            ColorPicker("", selection: Binding(get: { Color(p3: document.background) },
                                               set: { if let c = $0.p3Components { document.setBackground(c, visible: document.backgroundVisible) } }),
                        supportsOpacity: false).labelsHidden()
            Button { document.setBackground(document.background, visible: !document.backgroundVisible) } label: {
                Image(systemName: document.backgroundVisible ? "checkmark.square" : "square")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }

    @ViewBuilder
    private func contextMenu(_ node: LayerNode) -> some View {
        Button("Rename") { renameText = node.name; renaming = node.id }
        Button("Duplicate") { document.duplicateLayer(node.id) }
        Button("Merge Down") { document.mergeDown(node.id) }
        Divider()
        Button(node.clipsToBelow ? "Release Clipping Mask" : "Clipping Mask") { document.setClipping(node.id, !node.clipsToBelow) }
        if node.isRaster {
            Button(node.alphaLocked ? "Unlock Alpha" : "Alpha Lock") { document.setAlphaLocked(node.id, !node.alphaLocked) }
            Button(node.isReference ? "Stop Using as Reference" : "Reference") { document.setReference(node.id, !node.isReference) }
        }
        Button(node.isLocked ? "Unlock" : "Lock") { document.setLocked(node.id, !node.isLocked) }
        Divider()
        if node.hasMask {
            Button(node.maskEnabled ? "Disable Mask" : "Enable Mask") { document.setMaskEnabled(node.id, !node.maskEnabled) }
            if node.isRaster { Button("Apply Mask") { document.applyMask(node.id) } }
            Button("Delete Mask") { document.deleteMask(node.id) }
        } else {
            Button("Add Layer Mask") { document.addMask(node.id) }
        }
        Divider()
        if node.isGroup {
            Button("Ungroup") { document.ungroup(node.id) }
            Button("Flatten Group") { document.flattenGroup(node.id) }
        } else {
            Button("Group") { document.activeLayerID = node.id; document.groupActiveLayer() }
        }
        Button("Delete", role: .destructive) { document.deleteLayer(node.id) }
    }

    // MARK: Active layer controls

    private func activeLayerControls(_ node: LayerNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Opacity").font(.caption)
                Slider(value: Binding(get: { node.opacity }, set: { document.setOpacity(node.id, $0) }), in: 0...1)
                Text("\(Int(node.opacity * 100))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
            Picker("Blend", selection: Binding(get: { node.blendMode }, set: { document.setBlendMode(node.id, $0) })) {
                if node.isGroup { Text(BlendMode.passThrough.displayName).tag(BlendMode.passThrough) }
                ForEach(Array(BlendMode.menuGroups.enumerated()), id: \.offset) { _, group in
                    ForEach(group) { Text($0.displayName).tag($0) }
                    Divider()
                }
            }
            .font(.caption)
            HStack(spacing: 12) {
                toggle("Clip", "arrow.turn.left.down", node.clipsToBelow) { document.setClipping(node.id, $0) }
                if node.isRaster {
                    toggle("Alpha", "checkerboard.rectangle", node.alphaLocked) { document.setAlphaLocked(node.id, $0) }
                    toggle("Ref", "scope", node.isReference) { document.setReference(node.id, $0) }
                }
                toggle("Lock", "lock", node.isLocked) { document.setLocked(node.id, $0) }
                Spacer()
                Button { node.hasMask ? document.deleteMask(node.id) : document.addMask(node.id) } label: {
                    Image(systemName: node.hasMask ? "rectangle.slash" : "rectangle.lefthalf.inset.filled")
                }
                .buttonStyle(.borderless).help(node.hasMask ? "Delete mask" : "Add layer mask")
                Button { document.mergeDown(node.id) } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }
                    .buttonStyle(.borderless).help("Merge down (⌘E)")
                Button { document.duplicateLayer(node.id) } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(.borderless).help("Duplicate (⌘J)")
                Button(role: .destructive) { document.deleteLayer(node.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete layer")
            }
        }
    }

    private func toggle(_ title: String, _ symbol: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(title).font(.caption2)
            }
            .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// Grey/white checkerboard for transparency.
public struct CheckerboardView: View {
    public init() {}
    public var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color(white: 0.78)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}
