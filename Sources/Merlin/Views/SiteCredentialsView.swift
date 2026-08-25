import SwiftUI

/// Verwaltung von Paywall-Abo-Zugangsdaten (z. B. Tagesspiegel Plus): verbundene
/// Domains anzeigen/trennen, neue Domain verbinden. Aufgerufen sowohl aus
/// SettingsView (allgemeine Verwaltung) als auch aus dem Paywall-Warnbanner im
/// Reader (mit `preselectedDomain`, damit sich das Eingabe-Sheet sofort öffnet).
struct SiteCredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = SiteCredentialsViewModel()

    /// Wenn gesetzt, öffnet sich das Eingabe-Sheet für diese Domain automatisch.
    var preselectedDomain: String? = nil

    @State private var editingDomain: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isLoading && viewModel.credentials.isEmpty && viewModel.availableDomains.isEmpty {
                    Section { ProgressView() }
                }

                if !viewModel.credentials.isEmpty {
                    Section {
                        ForEach(viewModel.credentials) { credential in
                            credentialRow(credential)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let domain = viewModel.credentials[index].domain
                                Task { await viewModel.delete(domain: domain) }
                            }
                        }
                    } header: {
                        Text(L("siteCredentials.connectedSection"))
                    }
                }

                if !viewModel.connectableDomains.isEmpty {
                    Section {
                        ForEach(viewModel.connectableDomains, id: \.self) { domain in
                            Button {
                                editingDomain = domain
                            } label: {
                                Label(domain, systemImage: "lock.shield")
                            }
                        }
                    } header: {
                        Text(L("siteCredentials.addSection"))
                    }
                }

                if viewModel.credentials.isEmpty && viewModel.connectableDomains.isEmpty && !viewModel.isLoading {
                    Section {
                        Text(L("siteCredentials.noneYet"))
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L("siteCredentials.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { editingDomain.map(IdentifiableDomain.init) },
                set: { editingDomain = $0?.domain }
            )) { wrapped in
                SiteCredentialEditView(domain: wrapped.domain, viewModel: viewModel)
            }
            .task {
                await viewModel.load()
                if let preselectedDomain {
                    editingDomain = preselectedDomain
                }
            }
        }
    }

    private func credentialRow(_ credential: SiteCredentialInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.domain)
                statusLabel(for: credential.status)
                    .font(.caption)
                    .foregroundStyle(statusColor(for: credential.status))
            }
            Spacer()
            Button {
                editingDomain = credential.domain
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
        }
    }

    private func statusLabel(for status: String) -> Text {
        switch status {
        case "ok":                   return Text(L("siteCredentials.status.ok"))
        case "invalid_credentials":  return Text(L("siteCredentials.status.invalidCredentials"))
        case "login_flow_broken":    return Text(L("siteCredentials.status.loginFlowBroken"))
        default:                     return Text(L("siteCredentials.status.pending"))
        }
    }

    private func statusColor(for status: String) -> Color {
        status == "ok" ? .green : .orange
    }
}

/// `String` ist nicht `Identifiable` – kleiner Wrapper, damit `.sheet(item:)`
/// (statt `.sheet(isPresented:)`) genutzt werden kann und die editierte Domain
/// eindeutig an das Sheet gebunden bleibt.
private struct IdentifiableDomain: Identifiable {
    let domain: String
    var id: String { domain }
}

/// Eingabe-Sheet: Benutzername/Passwort für eine einzelne Domain, mit sofortigem
/// Server-seitigem Login-Test beim Speichern (siehe MerlinAPI.updateSiteCredential).
private struct SiteCredentialEditView: View {
    @Environment(\.dismiss) private var dismiss
    let domain: String
    var viewModel: SiteCredentialsViewModel

    @State private var username = ""
    @State private var password = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSucceed = false
    @FocusState private var focusedField: Field?

    enum Field { case username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("siteCredentials.usernamePlaceholder"), text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                    SecureField(L("siteCredentials.passwordPlaceholder"), text: $password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text(domain)
                }

                if didSucceed {
                    Section {
                        Label(L("siteCredentials.savedHint"), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                } else if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L("siteCredentials.addSection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || isSaving)
                        .overlay {
                            if isSaving { ProgressView().progressViewStyle(.circular) }
                        }
                }
            }
            .onAppear { focusedField = .username }
        }
    }

    private func save() {
        guard !isSaving else { return }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { return }

        isSaving = true
        errorMessage = nil
        Task {
            let success = await viewModel.save(domain: domain, username: trimmedUsername, password: password)
            isSaving = false
            if success {
                didSucceed = true
            } else {
                errorMessage = viewModel.errorMessage
            }
        }
    }
}
