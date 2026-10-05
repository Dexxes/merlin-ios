import SwiftUI

/// Kommentare eines Artikels: Threads mit Antworten, neuer Kommentar, Antwort,
/// Bearbeiten (eigene) und Löschen (alle – der Besitzer moderiert seinen
/// Artikel). Liest live aus dem `CommentStore`, neue Kommentare von Gästen
/// erscheinen also ohne Neuladen.
///
/// Mit `initialHighlightId` zeigt der Dialog zuerst nur die Threads dieser
/// Markierung und kommentiert neu an ihr; "Alle Kommentare" schaltet um.
struct CommentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: CommentStore
    let initialHighlightId: Int?
    /// Markierter Text, falls die Markierung gerade erst angelegt wurde und
    /// der Store sie noch nicht kennt.
    let initialQuote: String?
    var onShowInText: ((Int) -> Void)? = nil

    @State private var focusedHighlightId: Int?
    @State private var draft = ""
    @State private var replyTarget: Comment?
    @State private var editing: Comment?
    @State private var commentToDelete: Comment?
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    init(store: CommentStore, initialHighlightId: Int?, initialQuote: String?, onShowInText: ((Int) -> Void)? = nil) {
        self.store = store
        self.initialHighlightId = initialHighlightId
        self.initialQuote = initialQuote
        self.onShowInText = onShowInText
        _focusedHighlightId = State(initialValue: initialHighlightId)
    }

    private var visibleThreads: [Comment] {
        guard let hid = focusedHighlightId else { return store.threads }
        return store.threads.filter { $0.highlightId == hid }
    }

    private var focusedQuote: String? {
        guard let hid = focusedHighlightId else { return nil }
        if let text = store.highlight(hid)?.highlightedText { return text }
        return hid == initialHighlightId ? initialQuote : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let quote = focusedQuote, !quote.isEmpty {
                        QuoteView(text: quote)
                    }

                    if visibleThreads.isEmpty {
                        Text(focusedHighlightId != nil
                             ? L("articleReader.comments.noneOnPassage")
                             : L("articleReader.comments.none"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }

                    ForEach(visibleThreads) { thread in
                        threadView(thread)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(focusedHighlightId != nil
                             ? L("articleReader.comments.onPassageTitle")
                             : L("articleReader.comments.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
                if focusedHighlightId != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L("articleReader.comments.allComments")) {
                            focusedHighlightId = nil
                            replyTarget = nil
                        }
                    }
                }
            }
            .confirmationDialog(
                L("articleReader.comments.confirmDelete"),
                isPresented: .init(get: { commentToDelete != nil }, set: { if !$0 { commentToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(L("articleReader.comments.delete"), role: .destructive) {
                    if let c = commentToDelete { Task { await delete(c) } }
                    commentToDelete = nil
                }
                Button(L("common.cancel"), role: .cancel) { commentToDelete = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: – Thread

    @ViewBuilder
    private func threadView(_ thread: Comment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if focusedHighlightId == nil, let quote = thread.quotedText, !quote.isEmpty {
                Button {
                    if let hid = thread.highlightId { onShowInText?(hid) }
                } label: {
                    QuoteView(text: quote, removed: thread.highlightId == nil)
                }
                .buttonStyle(.plain)
                .disabled(thread.highlightId == nil)
            }

            CommentRow(
                comment: thread,
                replyToName: nil,
                canEdit: thread.isOwner,
                onReply: { startReply(to: thread) },
                onEdit: { startEdit(thread) },
                onDelete: { commentToDelete = thread })

            ForEach(thread.replies ?? []) { reply in
                CommentRow(
                    comment: reply,
                    replyToName: replyToName(of: reply, in: thread),
                    canEdit: reply.isOwner,
                    onReply: { startReply(to: reply) },
                    onEdit: { startEdit(reply) },
                    onDelete: { commentToDelete = reply })
                    .padding(.leading, 18)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Name dessen, dem geantwortet wurde – nur wenn es nicht die Wurzel ist
    /// (die ist ohnehin gemeint).
    private func replyToName(of reply: Comment, in thread: Comment) -> String? {
        guard let target = reply.replyToId, target != thread.id else { return nil }
        return thread.replies?.first { $0.id == target }?.authorName
    }

    // MARK: – Eingabe

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = errorMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let target = replyTarget {
                contextLine(String(format: L("articleReader.comments.replyTo"), target.authorName)) {
                    replyTarget = nil
                }
            } else if editing != nil {
                contextLine(L("articleReader.comments.edit")) {
                    editing = nil
                    draft = ""
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18))
                    .focused($inputFocused)

                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        ProgressView().frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                }
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L("articleReader.comments.send"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func contextLine(_ text: String, onCancel: @escaping () -> Void) -> some View {
        HStack {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(L("common.cancel"))
        }
    }

    private var placeholder: String {
        replyTarget != nil
            ? L("articleReader.comments.writeReply")
            : L("articleReader.comments.writeComment")
    }

    private func startReply(to comment: Comment) {
        editing = nil
        replyTarget = comment
        inputFocused = true
    }

    private func startEdit(_ comment: Comment) {
        replyTarget = nil
        editing = comment
        draft = comment.body
        inputFocused = true
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isSending = true
        errorMessage = nil
        do {
            if let comment = editing {
                try await store.update(comment.id, body: body)
                editing = nil
            } else if let target = replyTarget {
                try await store.create(body: body, highlightId: nil, parentId: target.id)
                replyTarget = nil
            } else {
                try await store.create(body: body, highlightId: focusedHighlightId, parentId: nil)
            }
            draft = ""
        } catch {
            errorMessage = (error as? CommentAPIError)?.errorDescription
                ?? L("articleReader.comments.saveFailed")
        }
        isSending = false
    }

    private func delete(_ comment: Comment) async {
        errorMessage = nil
        do {
            try await store.delete(comment.id)
            if editing?.id == comment.id { editing = nil; draft = "" }
            if replyTarget?.id == comment.id { replyTarget = nil }
        } catch {
            errorMessage = L("articleReader.comments.deleteFailed")
        }
    }
}

// MARK: – Bausteine

/// Zitierte Textstelle über einem Thread.
private struct QuoteView: View {
    let text: String
    var removed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .italic()
                .lineLimit(4)
                .foregroundStyle(.primary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(hexString: "#f59e0b") ?? .orange)
                        .frame(width: 3)
                }
            if removed {
                Text(L("articleReader.comments.highlightRemoved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Ein Kommentar mit Name, Zeit und Aktionen. Gelöschte Wurzeln bleiben als
/// Platzhalter stehen, damit ihre Antworten lesbar bleiben.
private struct CommentRow: View {
    let comment: Comment
    let replyToName: String?
    let canEdit: Bool
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if comment.deleted {
            Text(L("articleReader.comments.deleted"))
                .font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.subheadline.weight(.semibold))
                    if comment.isOwner {
                        Text(L("articleReader.comments.you"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    if let name = replyToName {
                        Text("→ \(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = comment.createdDate {
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if comment.edited {
                        Text(L("articleReader.comments.edited"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(comment.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 16) {
                    Button(L("articleReader.comments.reply"), action: onReply)
                    if canEdit {
                        Button(L("articleReader.comments.edit"), action: onEdit)
                    }
                    Button(L("articleReader.comments.delete"), role: .destructive, action: onDelete)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
    }
}
