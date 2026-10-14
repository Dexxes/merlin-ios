import SwiftUI

struct AddArticleSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: ArticlesViewModel

    @State private var urlText        = ""
    @State private var newTagInput    = ""
    @State private var selectedTagIds: Set<Int> = []
    @State private var pendingTags:   [String]  = []
    /// Eltern-Tag für neu angelegte Tags; `nil` = oberste Ebene.
    @State private var newTagParentId: Int?     = nil
    @State private var isSaving       = false
    @State private var errorMessage: String? = nil
    @FocusState private var isUrlFocused: Bool

    /// `initialURL` füllt das URL-Feld vor (z. B. aus dem Link-Dialog im Reader).
    init(viewModel: ArticlesViewModel, initialURL: String = "") {
        self.viewModel = viewModel
        _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                // URL
                Section {
                    TextField(L("addArticle.urlPlaceholder"), text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isUrlFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text(L("addArticle.urlSectionHeader"))
                } footer: {
                    Text(L("addArticle.urlFooter"))
                }

                // Tags
                Section {
                    if !viewModel.allTags.isEmpty {
                        tagTreeList
                    }
                    HStack {
                        TextField(L("addArticle.tagsPlaceholder"), text: $newTagInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { commitNewTag() }
                        if !newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(L("common.add")) { commitNewTag() }
                                .font(.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                    if !tagSuggestions.isEmpty {
                        suggestionsList
                    }
                    if !pendingTags.isEmpty {
                        pendingTagsList
                    }
                    if !viewModel.allTags.isEmpty,
                       !pendingTags.isEmpty || !newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TagParentPicker(tree: viewModel.tagTree, selection: $newTagParentId)
                    }
                } header: {
                    Text(L("addArticle.tagsSectionHeader"))
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L("addArticle.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        .overlay {
                            if isSaving { ProgressView().progressViewStyle(.circular) }
                        }
                }
            }
            .onAppear {
                // Vorbefüllt geht es um die Tags - keine Tastatur für die URL.
                isUrlFocused = urlText.isEmpty
                Task { await viewModel.loadTags() }
            }
        }
    }

    // MARK: – Computed

    /// Existing tags that match the current input and haven't been selected yet.
    private var tagSuggestions: [Tag] {
        let q = newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return viewModel.allTags.filter {
            !selectedTagIds.contains($0.id) &&
            $0.name.lowercased().contains(q)
        }
    }

    // MARK: – Sub-views

    // Zeilen wie in der Share-Extension; der Rahmen ersetzt den Form-Zellhintergrund.

    private var tagTreeList: some View {
        TagTreeSelectionList(tree: viewModel.tagTree, selection: $selectedTagIds)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    private var suggestionsList: some View {
        TagSuggestionList(tags: tagSuggestions) { tag in
            selectedTagIds = viewModel.tagTree.selecting(tag.id, in: selectedTagIds)
            newTagInput = ""
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var pendingTagsList: some View {
        PendingTagList(names: pendingTags) { name in
            pendingTags.removeAll { $0 == name }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    // MARK: – Actions

    private func commitNewTag() {
        let name = newTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !pendingTags.contains(where: { $0.lowercased() == name.lowercased() }),
              !viewModel.allTags.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { newTagInput = ""; return }
        pendingTags.append(name)
        newTagInput = ""
    }

    private func save() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                var tagIds = selectedTagIds
                if !pendingTags.isEmpty {
                    let created = try await MerlinAPI.shared.resolveTagIds(for: pendingTags, parentId: newTagParentId)
                    tagIds.formUnion(created)
                    // Neue Unter-Tags ziehen ihren Eltern-Tag mit, wie beim Antippen.
                    if let parent = newTagParentId {
                        tagIds = viewModel.tagTree.selecting(parent, in: tagIds)
                    }
                }
                try await viewModel.addArticle(url: url, tagIds: Array(tagIds))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
