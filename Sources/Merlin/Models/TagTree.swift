import Foundation

/// Verschachtelte Tags: Baumregeln über der flachen Tag-Liste vom Server
/// (`Tag.parentId`). Gegenstück zu `TagTree.php`/`tag-tree.js` in
/// merlin-nextcloud. Ein Tag, dessen Eltern-Tag fehlt, gilt als oberste
/// Ebene, damit er nie aus der Liste verschwindet.
struct TagTree {
    /// Ein Tag in Baumreihenfolge mit seiner Tiefe (0 = oberste Ebene).
    struct Row: Identifiable {
        let tag: Tag
        let depth: Int
        let hasChildren: Bool
        var id: Int { tag.id }
    }

    let tags: [Tag]
    private let byId: [Int: Tag]
    /// Kinder je Eltern-Id, nach Name sortiert; Schlüssel `nil` = oberste Ebene.
    private let children: [Int?: [Tag]]

    init(_ tags: [Tag]) {
        self.tags = tags
        let byId = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.byId = byId
        var children: [Int?: [Tag]] = [:]
        for tag in tags {
            let parent = tag.parentId.flatMap { byId[$0] != nil ? $0 : nil }
            children[parent, default: []].append(tag)
        }
        for key in children.keys {
            children[key]?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        self.children = children
    }

    func hasChildren(_ id: Int) -> Bool {
        !(children[id] ?? []).isEmpty
    }

    /// Ids aller Nachfahren von `id` (ohne `id` selbst).
    func descendantIds(of id: Int) -> Set<Int> {
        var result = Set<Int>()
        var queue = children[id] ?? []
        while !queue.isEmpty {
            let tag = queue.removeFirst()
            guard tag.id != id, result.insert(tag.id).inserted else { continue }
            queue.append(contentsOf: children[tag.id] ?? [])
        }
        return result
    }

    /// `id` plus alle Nachfahren: was ein Filter auf diesen Tag umfasst.
    func scope(of id: Int) -> Set<Int> {
        descendantIds(of: id).union([id])
    }

    /// Ids aller Vorfahren von `id` (Eltern-Tag, dessen Eltern-Tag, …).
    func ancestorIds(of id: Int) -> Set<Int> {
        var result = Set<Int>()
        var parent = byId[id]?.parentId.flatMap { byId[$0] }
        while let p = parent, p.id != id, result.insert(p.id).inserted {
            parent = p.parentId.flatMap { byId[$0] }
        }
        return result
    }

    /// Auswahl nach Antippen von `id`: Ein ausgewählter Unter-Tag wählt seine
    /// Eltern-Tags mit aus, ein abgewählter Tag nimmt seine Unter-Tags mit,
    /// damit nie ein Unter-Tag ohne seinen Eltern-Tag ausgewählt bleibt.
    func toggling(_ id: Int, in selection: Set<Int>) -> Set<Int> {
        selection.contains(id)
            ? selection.subtracting(scope(of: id))
            : selecting(id, in: selection)
    }

    /// `selection` plus `id` und alle seine Eltern-Tags.
    func selecting(_ id: Int, in selection: Set<Int>) -> Set<Int> {
        selection.union(ancestorIds(of: id)).union([id])
    }

    /// Alle Tags in Baumreihenfolge (Eltern vor Kindern, Geschwister nach
    /// Name). Mit `collapsed` werden die Kinder dieser Tags ausgelassen.
    func rows(collapsed: Set<Int> = []) -> [Row] {
        var result: [Row] = []
        var seen = Set<Int>()
        func walk(_ parent: Int?, _ depth: Int) {
            for tag in children[parent] ?? [] where seen.insert(tag.id).inserted {
                let hasKids = hasChildren(tag.id)
                result.append(Row(tag: tag, depth: depth, hasChildren: hasKids))
                if hasKids, !collapsed.contains(tag.id) { walk(tag.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return result
    }

    /// Pfad eines Tags von der obersten Ebene bis zu ihm, z. B. "Reisen › Japan".
    func path(of tag: Tag) -> String {
        var names = [tag.name]
        var seen: Set<Int> = [tag.id]
        var parent = tag.parentId.flatMap { byId[$0] }
        while let p = parent, seen.insert(p.id).inserted {
            names.insert(p.name, at: 0)
            parent = p.parentId.flatMap { byId[$0] }
        }
        return names.joined(separator: " › ")
    }

    /// Darf `id` unter `newParent` hängen? Nicht unter sich selbst und nicht
    /// unter einen eigenen Nachfahren; `nil` (oberste Ebene) geht immer.
    func canMove(_ id: Int, under newParent: Int?) -> Bool {
        guard let newParent else { return true }
        return newParent != id && !descendantIds(of: id).contains(newParent)
    }
}
