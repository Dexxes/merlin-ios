import SwiftUI

struct AddArticleSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: ArticlesViewModel

    @State private var urlText        = ""
    @State private var newTagInput    = ""
    @State private var selectedTagIds: Set<Int> = []
    @State private var pendingTags:   [String]  = []
    @State private var isSaving       = false
    @State private var errorMessage: String? = nil
    @FocusState private var isUrlFocused: Bool

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
                        tagChipGrid
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
                        suggestionsRow
                    }
                    if !pendingTags.isEmpty {
                        pendingTagsRow
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
                isUrlFocused = true
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

    @ViewBuilder
    private var tagChipGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
            ForEach(viewModel.allTags) { tag in
                let sel = selectedTagIds.contains(tag.id)
                AddSheetTagChip(name: tag.name, color: tag.color, isSelected: sel) {
                    if sel { selectedTagIds.remove(tag.id) }
                    else   { selectedTagIds.insert(tag.id) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tagSuggestions) { tag in
                    let chipColor: Color = {
                        guard let hex = tag.color, let c = Color(hexString: hex) else { return .accentColor }
                        return c
                    }()
                    Button {
                        selectedTagIds.insert(tag.id)
                        newTagInput = ""
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.caption2.weight(.semibold))
                            Text(tag.name).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(chipColor.opacity(0.10))
                        .foregroundStyle(chipColor)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(chipColor.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var pendingTagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingTags, id: \.self) { name in
                    HStack(spacing: 4) {
                        Text(name).font(.caption)
                        Button { pendingTags.removeAll { $0 == name } } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5))
                }
            }
            .padding(.vertical, 2)
        }
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
                var tagIds = Array(selectedTagIds)
                if !pendingTags.isEmpty {
                    let created = try await MerlinAPI.shared.resolveTagIds(for: pendingTags)
                    tagIds.append(contentsOf: created)
                }
                try await viewModel.addArticle(url: url, tagIds: tagIds)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: – Tag chip

private struct AddSheetTagChip: View {
    let name: String
    let color: String?
    let isSelected: Bool
    let action: () -> Void

    private var chipColor: Color {
        guard let hex = color, let c = Color(hexString: hex) else { return .accentColor }
        return c
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(name).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isSelected ? chipColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
            .foregroundStyle(isSelected ? chipColor : Color.secondary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isSelected ? chipColor : Color(.separator),
                                      lineWidth: isSelected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
    }
}
