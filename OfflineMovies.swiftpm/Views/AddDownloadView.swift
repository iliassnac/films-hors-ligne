import SwiftUI

/// Sheet to start a download from a direct HTTPS link.
struct AddDownloadView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var titleText = ""
    @State private var errorMessage: String?

    private var isLinkEmpty: Bool {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Lien HTTPS du fichier vidéo", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Titre (optionnel)", text: $titleText)
                } footer: {
                    Text("Lien direct vers un fichier .mp4, .m4v ou .mov. Gardez l'application ouverte et l'écran allumé pendant le téléchargement. Connectez-vous au Wi-Fi.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle("Nouveau téléchargement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Télécharger") {
                        startDownload()
                    }
                    .disabled(isLinkEmpty)
                }
            }
        }
    }

    private func startDownload() {
        do {
            try downloadManager.start(urlString: urlText, title: titleText)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
