import SwiftUI

/// Tag-Auswahl als eingerückter Baum (Unter-Tags unter ihrem Eltern-Tag),
/// wie in der Share-Extension. Antippen folgt `TagTree.toggling`: Ein
/// Unter-Tag wählt seine Eltern-Tags mit aus, Abwählen nimmt die Unter-Tags
/// mit. Genutzt von `ArticleTagSheet` („Tags bearbeiten“).
struct TagTreeSelectionList: View {
    let tree: TagTree
    @Binding var selection: Set<Int>

    var body: some View {
        let rows = tree.rows()
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let tag = row.tag
                let isSelected = selection.contains(tag.id)
                let tagColor: Color = tag.color.flatMap { Color(hexString: $0) } ?? .accentColor
                Button {
                    selection = tree.toggling(tag.id, in: selection)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .foregroundStyle(isSelected ? tagColor : Color.secondary)
                        Text(tag.name)
                            .font(.body)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 12 + CGFloat(row.depth) * 22)
                    .padding(.trailing, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                if index < rows.count - 1 {
                    Divider().padding(.leading, 12 + CGFloat(row.depth) * 22)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
