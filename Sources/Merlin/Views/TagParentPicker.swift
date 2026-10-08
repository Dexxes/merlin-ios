import SwiftUI

/// Auswahl „Unter“ für neu angelegte Tags (verschachtelte Tags): oberste
/// Ebene oder ein bestehender Tag, eingerückt in Baumreihenfolge. Genutzt von
/// `AddArticleSheet` und `ArticleTagSheet`.
struct TagParentPicker: View {
    let tree: TagTree
    @Binding var selection: Int?

    var body: some View {
        Picker(L("tagParentPicker.label"), selection: $selection) {
            Text(L("tagParentPicker.topLevel")).tag(nil as Int?)
            ForEach(tree.rows()) { row in
                Text(String(repeating: "\u{2003}", count: row.depth) + row.tag.name)
                    .tag(row.tag.id as Int?)
            }
        }
        .pickerStyle(.menu)
        .font(.subheadline)
    }
}
