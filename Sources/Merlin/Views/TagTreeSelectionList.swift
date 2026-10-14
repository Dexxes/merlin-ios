import SwiftUI

/// Tag-Auswahl als eingerückter Baum (Unter-Tags unter ihrem Eltern-Tag),
/// wie in der Share-Extension. Antippen folgt `TagTree.toggling`: Ein
/// Unter-Tag wählt seine Eltern-Tags mit aus, Abwählen nimmt die Unter-Tags
/// mit. Genutzt von `ArticleTagSheet` („Tags bearbeiten“) und `AddArticleSheet`.
struct TagTreeSelectionList: View {
    let tree: TagTree
    @Binding var selection: Set<Int>

    var body: some View {
        let rows = tree.rows()
        TagRowGroup {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let tag = row.tag
                TagSelectionRow(name: tag.name, color: tag.color, depth: row.depth,
                                isSelected: selection.contains(tag.id)) {
                    selection = tree.toggling(tag.id, in: selection)
                }
                if index < rows.count - 1 {
                    Divider().padding(.leading, 12 + CGFloat(row.depth) * 22)
                }
            }
        }
    }
}

/// Vorschläge zur Tag-Eingabe im selben Zeilenstil (statt Pillen).
struct TagSuggestionList: View {
    let tags: [Tag]
    let onPick: (Tag) -> Void

    var body: some View {
        TagRowGroup {
            ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                TagSelectionRow(name: tag.name, color: tag.color, depth: 0, isSelected: false) {
                    onPick(tag)
                }
                if index < tags.count - 1 { Divider().padding(.leading, 12) }
            }
        }
    }
}

/// Neu eingegebene Tags (werden beim Speichern angelegt) als ausgewählte Zeilen;
/// Antippen nimmt sie wieder heraus.
struct PendingTagList: View {
    let names: [String]
    let onRemove: (String) -> Void

    var body: some View {
        TagRowGroup {
            ForEach(Array(names.enumerated()), id: \.element) { index, name in
                TagSelectionRow(name: name, color: nil, depth: 0, isSelected: true) {
                    onRemove(name)
                }
                if index < names.count - 1 { Divider().padding(.leading, 12) }
            }
        }
    }
}

/// Eine Zeile wie in der Share-Extension: Kreis/Häkchen, Name, eingerückt nach Tiefe.
struct TagSelectionRow: View {
    let name: String
    let color: String?
    let depth: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let tagColor: Color = color.flatMap { Color(hexString: $0) } ?? .accentColor
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? tagColor : Color.secondary)
                Text(name)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12 + CGFloat(depth) * 22)
            .padding(.trailing, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Gemeinsamer Rahmen der Tag-Zeilen.
private struct TagRowGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Tags eines Artikels in Listen und Kacheln: farbiger Punkt und Name als
/// schlichter Text, ohne Pillen-Hintergrund.
struct ArticleTagLine: View {
    let tags: [Tag]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tags) { tag in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tag.color.flatMap { Color(hexString: $0) } ?? Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(tag.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
