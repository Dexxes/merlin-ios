import SwiftUI

/// "Rename…" for entries from "Merlin files": asks for the new name (without
/// extension, which the server keeps) and renames the file in Nextcloud and
/// the entry. Shared by list, cards and reader.
struct RenameFileAlert: ViewModifier {
    @Binding var article: Article?
    let viewModel: ArticlesViewModel

    @State private var name = ""
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert(L("fileRename.title"), isPresented: Binding(
                get: { article != nil },
                set: { if !$0 { article = nil } }
            ), presenting: article) { target in
                TextField(L("fileRename.placeholder"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L("common.cancel"), role: .cancel) {}
                Button(L("fileRename.confirm")) {
                    let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty, newName != Self.baseName(of: target.title) else { return }
                    Task {
                        if let message = await viewModel.renameFile(target, to: newName) {
                            errorMessage = message
                        }
                    }
                }
            } message: { target in
                let ext = (target.title as NSString).pathExtension
                if !ext.isEmpty {
                    Text(String(format: L("fileRename.message"), ext))
                }
            }
            .onChange(of: article?.id) { _, _ in
                name = article.map { Self.baseName(of: $0.title) } ?? ""
            }
            .alert(L("fileRename.errorTitle"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// File name without extension (what the text field edits).
    static func baseName(of fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? fileName : (fileName as NSString).deletingPathExtension
    }
}

extension View {
    func renameFileAlert(article: Binding<Article?>, viewModel: ArticlesViewModel) -> some View {
        modifier(RenameFileAlert(article: article, viewModel: viewModel))
    }
}
