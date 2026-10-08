import SwiftUI

/// Kommentare eines Artikels: Threads mit Antworten, neuer Kommentar, Antwort,
/// Bearbeiten (eigene) und Löschen (alle – der Besitzer moderiert seinen
/// Artikel). Liest live aus dem `CommentStore`, neue Kommentare von Gästen
/// erscheinen also ohne Neuladen.
///
/// Mit `initialHighlightId` zeigt der Dialog zuerst nur die Threads dieser
/// Markierung und kommentiert neu an ihr; "Alle Kommentare" schaltet um.
/// Mit `initialAnchor` (frische Auswahl, noch keine Markierung) zeigt er nur
/// die zitierte Stelle und das Eingabefeld; erst der abgeschickte Kommentar
/// legt die Stelle an, danach zeigt der Dialog deren Thread.
struct CommentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: CommentStore
    let initialHighlightId: Int?
    /// Markierter Text, falls die Markierung gerade erst angelegt wurde und
    /// der Store sie noch nicht kennt.
    let initialQuote: String?
    let initialAnchor: CommentAnchor?
    var onShowInText: ((Int) -> Void)? = nil

    @State private var focusedHighlightId: Int?
    @State private var pendingAnchor: CommentAnchor?
    @State private var draft = ""
    @State private var replyTarget: Comment?
    @State private var editing: Comment?
    @State private var commentToDelete: Comment?
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool
    @AppStorage("merlinCommentSortOrder") private var sortOrderRaw: String = CommentSortOrder.text.rawValue

    init(store: CommentStore, initialHighlightId: Int?, initialQuote: String?,
         initialAnchor: CommentAnchor? = nil, onShowInText: ((Int) -> Void)? = nil) {
        self.store = store
        self.initialHighlightId = initialHighlightId
        self.initialQuote = initialQuote
        self.initialAnchor = initialAnchor
        self.onShowInText = onShowInText
        _focusedHighlightId = State(initialValue: initialHighlightId)
        _pendingAnchor = State(initialValue: initialAnchor)
    }

    /// Eine Stelle ist im Fokus: eine bestehende Markierung oder die Auswahl,
    /// zu der gerade der erste Kommentar entsteht.
    private var isPassageFocused: Bool { focusedHighlightId != nil || pendingAnchor != nil }

    private var visibleThreads: [Comment] {
        if pendingAnchor != nil { return [] }
        guard let hid = focusedHighlightId else { return sortedThreads }
        return store.threads.filter { $0.highlightId == hid }
    }

    /// „Alle Kommentare“: Reihenfolge im Text oder nach der neuesten Antwort.
    /// Threads zur selben Stelle bleiben beieinander, damit das Zitat nur
    /// einmal über ihnen steht.
    private var sortedThreads: [Comment] {
        var groups: [[Comment]] = []
        var indexByHighlight: [Int: Int] = [:]
        for thread in store.threads {
            if let hid = thread.highlightId, let index = indexByHighlight[hid] {
                groups[index].append(thread)
            } else {
                if let hid = thread.highlightId { indexByHighlight[hid] = groups.count }
                groups.append([thread])
            }
        }
        let order = CommentSortOrder(rawValue: sortOrderRaw) ?? .text
        if order != .text {
            // Erst innerhalb einer Stelle (Thread mit der jüngsten Antwort
            // zuerst bzw. zuletzt), dann die Stellen untereinander.
            groups = groups.map { group in
                group.sorted { a, b in
                    let ta = Self.lastActivity(a), tb = Self.lastActivity(b)
                    if ta == tb { return a.id < b.id }
                    return order == .newest ? ta > tb : ta < tb
                }
            }
            let activity: ([Comment]) -> Date = { $0.map(Self.lastActivity).max() ?? .distantPast }
            groups.sort { a, b in
                let ta = activity(a), tb = activity(b)
                if ta == tb { return a[0].id < b[0].id }
                return order == .newest ? ta > tb : ta < tb
            }
        }
        return groups.flatMap { $0 }
    }

    /// Threads, über denen das Zitat steht: der erste zu jeder Stelle.
    private var quotedThreadIds: Set<Int> {
        guard focusedHighlightId == nil else { return [] }
        var seen = Set<Int>()
        var ids = Set<Int>()
        for thread in visibleThreads {
            guard let hid = thread.highlightId else { ids.insert(thread.id); continue }
            if seen.insert(hid).inserted { ids.insert(thread.id) }
        }
        return ids
    }

    /// Zeitpunkt der neuesten Antwort (ohne Antworten: der Kommentar selbst).
    private static func lastActivity(_ thread: Comment) -> Date {
        var latest = thread.createdDate ?? .distantPast
        for reply in thread.replies ?? [] where !reply.deleted {
            if let date = reply.createdDate, date > latest { latest = date }
        }
        return latest
    }

    private var focusedQuote: String? {
        if let anchor = pendingAnchor { return anchor.highlightedText }
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

                    if visibleThreads.isEmpty && pendingAnchor == nil {
                        Text(focusedHighlightId != nil
                             ? L("articleReader.comments.noneOnPassage")
                             : L("articleReader.comments.none"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }

                    let quoted = quotedThreadIds
                    ForEach(visibleThreads) { thread in
                        threadView(thread, showsQuote: quoted.contains(thread.id))
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            // An einer Stelle keine Überschrift: das Zitat oben sagt genug.
            .navigationTitle(isPassageFocused ? "" : L("articleReader.comments.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
                if !isPassageFocused && store.threads.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker(L("articleReader.comments.sort"), selection: $sortOrderRaw) {
                                ForEach(CommentSortOrder.allCases) { order in
                                    Text(order.label).tag(order.rawValue)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel(L("articleReader.comments.sort"))
                    }
                }
                if isPassageFocused {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L("articleReader.comments.allComments")) {
                            focusedHighlightId = nil
                            pendingAnchor = nil
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
        .onAppear {
            // Frische Auswahl: der Nutzer wollte kommentieren, also gleich tippen.
            if pendingAnchor != nil { inputFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: – Thread

    @ViewBuilder
    private func threadView(_ thread: Comment, showsQuote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsQuote, let quote = thread.quotedText, !quote.isEmpty {
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
            } else if let anchor = pendingAnchor {
                let saved = try await store.create(body: body, highlightId: nil, parentId: nil, anchor: anchor)
                // Ab jetzt gibt es die Stelle: ihren Thread zeigen.
                pendingAnchor = nil
                focusedHighlightId = saved?.highlightId
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
                    Circle()
                        .fill(authorColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
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
                    Spacer(minLength: 0)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("articleReader.comments.delete"))
                }
                Text(CommentLinks.attributed(comment.body))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 16) {
                    Button(L("articleReader.comments.reply"), action: onReply)
                    if canEdit {
                        Button(L("articleReader.comments.edit"), action: onEdit)
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(authorColor)
                    .frame(width: 3)
            }
        }
    }

    /// Verfasser-Farbe vom Server (Besitzer orange, Gäste je eigene).
    private var authorColor: Color {
        comment.authorColor.flatMap { Color(hexString: $0) } ?? Color(.systemGray)
    }
}

/// Sortierung von „Alle Kommentare“.
enum CommentSortOrder: String, CaseIterable, Identifiable {
    case text, newest, oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return L("articleReader.comments.sortText")
        case .newest: return L("articleReader.comments.sortNewest")
        case .oldest: return L("articleReader.comments.sortOldest")
        }
    }
}

/// Web-Adressen in Kommentaren als antippbare Links (nur http und https;
/// „www.heise.de“ erkennt der Detector als http-Link).
enum CommentLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        guard let detector else { return AttributedString(text) }
        var result = AttributedString()
        var last = text.startIndex
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: text), range.lowerBound >= last
            else { continue }
            result += AttributedString(text[last..<range.lowerBound])
            var link = AttributedString(text[range])
            link.link = url
            result += link
            last = range.upperBound
        }
        result += AttributedString(text[last...])
        return result
    }
}
