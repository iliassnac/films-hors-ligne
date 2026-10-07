import SwiftUI
import UniformTypeIdentifiers

/// Main screen: downloads in progress, offline library, and the add / import actions.
struct LibraryView: View {
    @EnvironmentObject private var library: MovieLibrary
    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var showingAddDownload = false
    @State private var showingImporter = false
    @State private var selectedMovie: Movie?

    @State private var renameTarget: Movie?
    @State private var renameText = ""
    @State private var isRenaming = false

    @State private var deleteTarget: Movie?
    @State private var isConfirmingDelete = false

    @State private var errorMessage = ""
    @State private var isShowingError = false

    var body: some View {
        List {
            if !downloadManager.downloads.isEmpty {
                Section("Téléchargements en cours") {
                    ForEach(downloadManager.downloads) { download in
                        downloadRow(download)
                    }
                }
            }

            if !library.movies.isEmpty {
                Section("Prêts hors ligne") {
                    ForEach(library.movies) { movie in
                        movieRow(movie)
                    }
                }
            }

            if let footer = freeSpaceFooter {
                Section {
                    EmptyView()
                } footer: {
                    Text(footer)
                }
            }
        }
        .overlay {
            if isLibraryEmpty {
                emptyState
            }
        }
        .navigationTitle("Mes films")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showingAddDownload = true
                    } label: {
                        Label("Télécharger depuis un lien", systemImage: "link")
                    }
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Importer depuis Fichiers", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Ajouter")
            }
        }
        .sheet(isPresented: $showingAddDownload) {
            AddDownloadView()
                .environmentObject(downloadManager)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .fullScreenCover(item: $selectedMovie) { movie in
            PlayerView(movie: movie)
                .environmentObject(library)
        }
        .alert("Renommer le film", isPresented: $isRenaming) {
            TextField("Titre", text: $renameText)
            Button("Annuler", role: .cancel) {}
            Button("Enregistrer") {
                commitRename()
            }
        } message: {
            Text("Choisissez un nouveau titre.")
        }
        .confirmationDialog(
            "Supprimer ce film ?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                performDelete()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le fichier sera supprimé de cet appareil. Cette action est irréversible.")
        }
        .alert("Erreur", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Derived state

    private var isLibraryEmpty: Bool {
        library.movies.isEmpty && downloadManager.downloads.isEmpty
    }

    private var freeSpaceFooter: String? {
        guard let space = library.availableDiskSpace() else { return nil }
        return "Espace libre : \(Formatting.bytes(space))"
    }

    // MARK: - Rows

    private func downloadRow(_ download: ActiveDownload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(download.title)
                .font(.headline)
                .lineLimit(2)

            switch download.state {
            case .downloading:
                if download.totalBytes > 0 {
                    ProgressView(value: download.progress)
                } else {
                    ProgressView()
                }
                HStack {
                    Text(progressText(for: download))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        downloadManager.cancel(download.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Annuler le téléchargement")
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                Button("Retirer") {
                    downloadManager.dismiss(download.id)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func movieRow(_ movie: Movie) -> some View {
        Button {
            selectedMovie = movie
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(movie.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(detailText(for: movie))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if movie.watchedFraction > 0, movie.watchedFraction < 1 {
                        ProgressView(value: movie.watchedFraction)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestDelete(movie)
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                beginRename(movie)
            } label: {
                Label("Renommer", systemImage: "pencil")
            }
            Button(role: .destructive) {
                requestDelete(movie)
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Aucun film pour l'instant. Touchez + pour en ajouter.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    private func progressText(for download: ActiveDownload) -> String {
        let written = Formatting.bytes(download.bytesWritten)
        guard download.totalBytes > 0 else { return written }
        return "\(written) / \(Formatting.bytes(download.totalBytes))"
    }

    private func detailText(for movie: Movie) -> String {
        var parts = [Formatting.bytes(movie.fileSize)]
        if let duration = movie.duration {
            parts.append(Formatting.duration(duration))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                _ = try library.importMovie(from: url)
            } catch {
                present(error)
            }
        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            present(error)
        }
    }

    private func beginRename(_ movie: Movie) {
        renameTarget = movie
        renameText = movie.title
        isRenaming = true
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        library.rename(target.id, to: renameText)
        renameTarget = nil
    }

    private func requestDelete(_ movie: Movie) {
        deleteTarget = movie
        isConfirmingDelete = true
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        do {
            try library.delete(target.id)
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}
