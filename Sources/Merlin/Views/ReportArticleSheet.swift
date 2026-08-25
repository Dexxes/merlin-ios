import SwiftUI

// Ergebnis eines Melde-Vorgangs — verhindert fragile String-Prefix-Checks.
enum ReportFeedback {
    case success
    case failure(String)
}

/// Melde-Sheet: Nutzer kann optional einen Kommentar eingeben,
/// bevor der Artikel ans merlin-reports-Backend gesendet wird.
struct ReportArticleSheet: View {

    let articleURL:  String
    @Binding var comment:   String
    @Binding var isSending: Bool
    @Binding var feedback:  ReportFeedback?

    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {

                // URL-Vorschau
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("report.articleLabel"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(articleURL)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.horizontal)

                // Optionaler Kommentar
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("report.commentLabel"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    TextField(L("report.commentPlaceholder"), text: $comment, axis: .vertical)
                        .lineLimit(3...5)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                }

                // Feedback-Meldung nach dem Senden
                if let feedback {
                    let (msg, color): (String, Color) = switch feedback {
                    case .success:           (L("report.successMessage"), .green)
                    case .failure(let err):  (err, .red)
                    }
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(color)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle(L("report.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else if feedback != nil {
                        // Nach erfolgreichem Senden: Schließen-Button
                        Button(L("common.close")) { dismiss() }
                    } else {
                        Button(L("report.submitButton")) { onSend() }
                            .bold()
                    }
                }
            }
        }
    }
}
