import SwiftUI

/// Sheet zum Verwalten ausgeblendeter Tags.
/// Tags in dieser Liste werden aus ArticleListView / ArticleCardView herausgefiltert.
struct TagFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let allTags: [Tag]
    let excludedTagIds: Set<Int>
    let onToggle: (Int) -> Void
    let onClearAll: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if allTags.isEmpty {
                    emptyView
                } else {
                    tagList
                }
            }
            .navigationTitle(L("tagFilterSheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.done")) { dismiss() }
                }
                if !excludedTagIds.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L("tagFilterSheet.clearAll")) {
                            onClearAll()
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: – Sub-views

    /// Ein ausgeblendeter Tag blendet auch seine Unter-Tags aus; diese sind
    /// deshalb abgeblendet, auch wenn sie selbst nicht ausgeblendet sind.
    private var inheritedHiddenIds: Set<Int> {
        let tree = TagTree(allTags)
        return excludedTagIds.reduce(into: Set<Int>()) { $0.formUnion(tree.descendantIds(of: $1)) }
    }

    private var tagList: some View {
        let inherited = inheritedHiddenIds
        return List(TagTree(allTags).rows()) { row in
            let tag = row.tag
            let isExcluded = excludedTagIds.contains(tag.id)
            Button {
                onToggle(tag.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tag.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Text(tag.name)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: isExcluded || inherited.contains(tag.id) ? "eye.slash" : "eye")
                        .font(.subheadline)
                        .foregroundStyle(isExcluded ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                }
                .padding(.leading, CGFloat(row.depth) * 20)
                .opacity(!isExcluded && inherited.contains(tag.id) ? 0.5 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if !excludedTagIds.isEmpty {
                filterSummary
            }
        }
    }

    /// Hinweiszeile am unteren Rand: wie viele Tags gerade ausgeblendet sind.
    private var filterSummary: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(String(format: L("tagFilterSheet.hiddenSummary"), excludedTagIds.count))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L("tagFilterSheet.emptyTitle"))
                .font(.headline)
            Text(L("tagFilterSheet.emptyMessage"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
