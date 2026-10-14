import SwiftUI

/// "Metadata" section below a file entry that the reader web view doesn't
/// show itself (PDF entries render natively, see `PDFArticleView`). Same
/// content and grouping as the HTML section from the server.
struct FileMetadataSection: View {
    let title: String
    let groups: [FileMetadataGroup]

    @State private var collapsed: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsed.contains(group.id) },
                    set: { expanded in
                        if expanded { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.label)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(0)
                                Text(entry.value)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(1)
                            }
                            .font(.footnote)
                            .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }
}
