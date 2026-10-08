import SwiftUI

/// „Verschieben nach…“ für verschachtelte Tags: wählt den neuen Eltern-Tag.
/// Der Tag selbst und seine Unter-Tags stehen nicht zur Wahl (sonst entstünde
/// ein Kreis, siehe `TagTree.canMove`). `onMove(nil)` = oberste Ebene.
struct MoveTagSheet: View {
    @Environment(\.dismiss) private var dismiss

    let tag: Tag
    let tree: TagTree
    let onMove: (Int?) -> Void

    @State private var selection: Int?

    init(tag: Tag, tree: TagTree, onMove: @escaping (Int?) -> Void) {
        self.tag = tag
        self.tree = tree
        self.onMove = onMove
        _selection = State(initialValue: tag.parentId)
    }

    private var targets: [TagTree.Row] {
        let excluded = tree.scope(of: tag.id)
        return tree.rows().filter { !excluded.contains($0.tag.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    option(label: L("moveTagSheet.topLevel"), color: nil, depth: 0, value: nil)
                        .italic()
                    ForEach(targets) { row in
                        option(label: row.tag.name, color: row.tag.color, depth: row.depth, value: row.tag.id)
                    }
                } header: {
                    Text(tree.hasChildren(tag.id)
                         ? String(format: L("moveTagSheet.introWithSubTags"), tag.name)
                         : String(format: L("moveTagSheet.intro"), tag.name))
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("moveTagSheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("moveTagSheet.move")) {
                        onMove(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selection == tag.parentId)
                }
            }
        }
    }

    private func option(label: String, color: String?, depth: Int, value: Int?) -> some View {
        Button {
            selection = value
        } label: {
            HStack(spacing: 10) {
                if let color {
                    Circle()
                        .fill(Color(hexString: color) ?? .accentColor)
                        .frame(width: 10, height: 10)
                } else if value != nil {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                }
                Text(label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if selection == value {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
