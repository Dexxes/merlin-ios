import SwiftUI

/// Verwaltung des öffentlichen Share-Links eines Artikels: anlegen,
/// Passwort/Ablaufdatum setzen, Kommentare für Besucher öffnen/schließen,
/// Link kopieren/teilen, regenerieren, widerrufen.
/// Ein Artikel hat höchstens einen Link (siehe ArticleShare/MerlinAPI).
struct ShareLinkSheet: View {
    @Environment(\.dismiss) private var dismiss

    let articleId: Int
    /// Server kann Kommentare (Nextcloud) – dann gibt es den Schalter
    /// "Besucher dürfen markieren und kommentieren".
    var commentsAvailable = false

    @State private var share: ArticleShare = .disabled
    @State private var isLoading  = true
    @State private var isBusy     = false
    @State private var errorMessage: String? = nil

    // Anlegen (noch kein Link vorhanden)
    @State private var createPasswordEnabled = false
    @State private var createPassword = ""
    @State private var createExpiryEnabled = false
    @State private var createExpiryDate = Date().addingTimeInterval(30 * 86_400)
    @State private var createAllowComments = true

    // Bestehenden Link ändern
    @State private var editingPassword = false
    @State private var newPassword = ""
    @State private var editingExpiry = false
    @State private var newExpiryDate = Date().addingTimeInterval(30 * 86_400)

    var body: some View {
        NavigationStack {
            Form {
                if let msg = errorMessage {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                if isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else if !share.enabled {
                    createSection
                } else {
                    manageSection
                }
            }
            .navigationTitle(L("articleReader.shareLink.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
        .task { await load() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: – Anlegen

    @ViewBuilder
    private var createSection: some View {
        Section {
            Text(L("articleReader.shareLink.explainer"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle(L("articleReader.shareLink.protectWithPassword"), isOn: $createPasswordEnabled.animation())
            if createPasswordEnabled {
                SecureField(L("articleReader.shareLink.password"), text: $createPassword)
            }
        }

        Section {
            Toggle(L("articleReader.shareLink.setExpiry"), isOn: $createExpiryEnabled.animation())
            if createExpiryEnabled {
                DatePicker(L("articleReader.shareLink.expiresOn"), selection: $createExpiryDate, in: Date()..., displayedComponents: [.date])
            }
        }

        if commentsAvailable {
            Section {
                Toggle(L("articleReader.comments.visitorsCanComment"), isOn: $createAllowComments)
            } footer: {
                Text(L("articleReader.comments.nameExplainer"))
            }
        }

        Section {
            Button {
                Task { await create() }
            } label: {
                if isBusy {
                    ProgressView()
                } else {
                    Text(L("articleReader.shareLink.createButton"))
                }
            }
            .disabled(isBusy)
        }
    }

    // MARK: – Verwalten

    @ViewBuilder
    private var manageSection: some View {
        Section {
            HStack {
                Text(share.url ?? "")
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    UIPasteboard.general.string = share.url
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
            if let url = share.url, let shareURL = URL(string: url) {
                ShareLink(item: shareURL) {
                    Label(L("articleReader.shareLink.shareButton"), systemImage: "square.and.arrow.up")
                }
            }
        }

        Section {
            Toggle(L("articleReader.shareLink.protectWithPassword"), isOn: passwordBinding)
            if editingPassword {
                SecureField(L("articleReader.shareLink.newPassword"), text: $newPassword)
                Button(L("common.save")) {
                    Task { await setPassword() }
                }
                .disabled(isBusy || newPassword.isEmpty)
            }
        }

        Section {
            Toggle(L("articleReader.shareLink.setExpiry"), isOn: expiryBinding)
            if editingExpiry {
                DatePicker(L("articleReader.shareLink.expiresOn"), selection: $newExpiryDate, in: Date()..., displayedComponents: [.date])
                Button(L("common.save")) {
                    Task { await setExpiry() }
                }
                .disabled(isBusy)
            } else if let expiresAt = share.expiresAt, let date = ArticleShare.parseDate(expiresAt) {
                // Schlichte Verkettung statt L()-Platzhalter: String-Interpolation
                // in L()-Keys wird im restlichen iOS-Code nirgends verwendet.
                Text("\(L("articleReader.shareLink.expiresOn")): \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if share.allowComments != nil {
            Section {
                Toggle(L("articleReader.comments.visitorsCanComment"), isOn: allowCommentsBinding)
                    .disabled(isBusy)
            } footer: {
                Text(L("articleReader.comments.nameExplainer"))
            }
        }

        Section {
            Button {
                Task { await regenerate() }
            } label: {
                Label(L("articleReader.shareLink.regenerateButton"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isBusy)

            Button(role: .destructive) {
                Task { await revoke() }
            } label: {
                Label(L("articleReader.shareLink.revokeButton"), systemImage: "trash")
            }
            .disabled(isBusy)
        }
    }

    /// Toggle, das direkt beim Ausschalten das Passwort entfernt (analog Web-UI),
    /// beim Einschalten nur das Eingabefeld öffnet (Speichern erst per Button).
    private var passwordBinding: Binding<Bool> {
        Binding(
            get: { share.hasPassword ?? false },
            set: { isOn in
                if isOn {
                    editingPassword = true
                    newPassword = ""
                } else {
                    editingPassword = false
                    Task { await removePassword() }
                }
            }
        )
    }

    private var allowCommentsBinding: Binding<Bool> {
        Binding(
            get: { share.allowComments ?? true },
            set: { isOn in Task { await setAllowComments(isOn) } }
        )
    }

    private var expiryBinding: Binding<Bool> {
        Binding(
            get: { share.expiresAt != nil },
            set: { isOn in
                if isOn {
                    editingExpiry = true
                    newExpiryDate = Date().addingTimeInterval(30 * 86_400)
                } else {
                    editingExpiry = false
                    Task { await removeExpiry() }
                }
            }
        )
    }

    // MARK: – Aktionen

    private func load() async {
        isLoading = true
        do {
            share = try await MerlinAPI.shared.getShare(articleId)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func create() async {
        isBusy = true
        errorMessage = nil
        do {
            share = try await MerlinAPI.shared.createShare(
                articleId,
                password: createPasswordEnabled ? createPassword : nil,
                expiresAt: createExpiryEnabled ? ISO8601DateFormatter().string(from: createExpiryDate) : nil,
                allowComments: commentsAvailable ? createAllowComments : nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func setPassword() async {
        guard !newPassword.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        do {
            share = try await MerlinAPI.shared.updateShare(articleId, password: .some(newPassword))
            editingPassword = false
            newPassword = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func removePassword() async {
        isBusy = true
        do {
            share = try await MerlinAPI.shared.updateShare(articleId, password: .some(nil))
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func setExpiry() async {
        isBusy = true
        errorMessage = nil
        do {
            share = try await MerlinAPI.shared.updateShare(articleId, expiresAt: .some(ISO8601DateFormatter().string(from: newExpiryDate)))
            editingExpiry = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func removeExpiry() async {
        isBusy = true
        do {
            share = try await MerlinAPI.shared.updateShare(articleId, expiresAt: .some(nil))
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func setAllowComments(_ allow: Bool) async {
        isBusy = true
        errorMessage = nil
        do {
            share = try await MerlinAPI.shared.updateShare(articleId, allowComments: allow)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func regenerate() async {
        isBusy = true
        errorMessage = nil
        do {
            share = try await MerlinAPI.shared.regenerateShare(articleId)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func revoke() async {
        isBusy = true
        errorMessage = nil
        do {
            try await MerlinAPI.shared.deleteShare(articleId)
            share = .disabled
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }
}

private extension ArticleShare {
    static func parseDate(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }
}
