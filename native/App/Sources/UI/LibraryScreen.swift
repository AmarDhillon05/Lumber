// Library: an "Add a song" picker (Files / YouTube / Spotify), saved songs
// with their takes, per-song "Remove original drums", the Recordings entry
// and the build label. Port of src/screens/LibraryScreen.tsx.

import SwiftUI
import UniformTypeIdentifiers

struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: Route.recordings(openId: nil)) {
                    RecordingsEntry(count: model.recordings.count)
                }
                .buttonStyle(.plain)

                AddSongSection(onImport: { importing = true })

                Text("Your songs")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.text)
                    .padding(.top, 10)
                if model.songs.isEmpty {
                    HintText("Add one above: import from Files, search YouTube (or paste a link), or connect Spotify.")
                }
                ForEach(model.songs) { song in
                    SongRow(song: song)
                }

                Text(BuildInfo.label)
                    .font(.caption2)
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
            .padding(Theme.gutter)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .lumberScreen("Lumber")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(BuildInfo.shortLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        try await model.importSong(from: url)
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .errorAlert("Import failed", message: $importError)
        .onAppear { model.adoptCachedStems() }
    }
}

private struct RecordingsEntry: View {
    let count: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recordings")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(count > 0 ? "\(count) saved · videos, mixes and takes" : "Your saved videos, mixes and takes")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Text("Open ›")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentSoft)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Add a song

private enum SongSourceTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case youtube = "YouTube"
    case spotify = "Spotify"
    var id: String { rawValue }
}

private struct AddSongSection: View {
    @Environment(AppModel.self) private var model
    let onImport: () -> Void
    @State private var tab: SongSourceTab = .files
    @State private var youtube: YouTubeSearchSession?
    @State private var spotify: SpotifySession?

    var body: some View {
        CardSection("Add a song") {
            Picker("Source", selection: $tab) {
                ForEach(SongSourceTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)

            switch tab {
            case .files:
                Button("Import file", action: onImport)
                    .lumberButton(.primary, fill: true)
                HintText("MP3, M4A, WAV, AAC or AIFF from the Files app.")
            case .youtube:
                if let youtube {
                    YouTubeSearchView(session: youtube)
                }
            case .spotify:
                if let spotify {
                    SpotifyPanel(session: spotify)
                }
            }
        }
        .onAppear {
            // Kept for the screen's lifetime so results survive tab switches.
            if youtube == nil { youtube = YouTubeSearchSession(model: model) }
            if spotify == nil { spotify = SpotifySession(model: model) }
        }
    }
}

private struct YouTubeSearchView: View {
    @Bindable var session: YouTubeSearchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search, or paste a YouTube/Spotify link", text: $session.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await session.search() } }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .foregroundStyle(Theme.text)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                Button("Search") { Task { await session.search() } }
                    .lumberButton()
                    .disabled(session.busy)
            }
            if session.busy {
                ProgressView().tint(Theme.accent)
            }
            if let error = session.error {
                ErrorText(error)
            }
            SearchResultsList(results: session.results, label: session.label)
        }
    }
}

/// Results from YouTube, a pasted link or Spotify, each with an Add button
/// that downloads it into the library.
struct SearchResultsList: View {
    @Environment(AppModel.self) private var model
    let results: [SearchResult]
    var label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 6)
            }
            ForEach(results) { result in
                row(result)
                Divider().overlay(Theme.border)
            }
        }
    }

    private func row(_ r: SearchResult) -> some View {
        let job = model.jobs[AppModel.downloadJobId(r)]
        let added = model.isInLibrary(r)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text([r.artist, r.durationSec.map { RecordingFormat.duration($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                if let job, let error = job.error {
                    ErrorText(error)
                } else if let job {
                    ProgressBar(progress: job.progress, color: Theme.blue)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if added {
                Text("Added ✓")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.success)
            } else {
                Button(job?.isRunning == true ? "Adding…" : "Add") {
                    Task { await model.addSearchResult(r) }
                }
                .lumberButton(.primary, small: true)
                .disabled(job?.isRunning == true)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Song row

private struct SongRow: View {
    @Environment(AppModel.self) private var model
    let song: LibrarySong
    @State private var confirmDelete = false
    @State private var projectToDelete: Project?

    var body: some View {
        let job = model.jobs[AppModel.separationJobId(song.id)]
        let running = job?.isRunning == true
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            .contextMenu {
                Button("Delete song", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }

            HStack(spacing: 8) {
                NavigationLink(value: Route.record(songId: song.id)) {
                    Text("Record")
                }
                .lumberButton(.primary, small: true)
                if song.stems == nil {
                    Button(running ? "Removing… \(Int(((job?.progress ?? 0) * 100).rounded()))%" : "Remove original drums") {
                        Task { await model.removeOriginalDrums(song.id) }
                    }
                    .lumberButton(small: true)
                    .disabled(running)
                }
                Button("Delete") { confirmDelete = true }
                    .lumberButton(.ghost, small: true)
            }

            if running, let job {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressBar(progress: job.progress, color: Theme.drums)
                    HintText("\(job.label). Runs on-device; first run downloads the model. Keep the app open.")
                }
            }
            if let error = job?.error {
                ErrorText(error)
            }

            ForEach(model.projects(forSong: song.id)) { project in
                Divider().overlay(Theme.border)
                NavigationLink(value: Route.edit(projectId: project.id)) {
                    HStack {
                        Text("🥁 \(project.name)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSoft)
                            .lineLimit(1)
                        Spacer()
                        Text("Edit ›")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentSoft)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete take", systemImage: "trash", role: .destructive) { projectToDelete = project }
                }
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
        .confirmationDialog("Delete song?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.removeSong(song.id) }
        } message: {
            Text("\(song.title) and its takes will be removed.")
        }
        .confirmationDialog(
            "Delete take?",
            isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }),
            titleVisibility: .visible,
            presenting: projectToDelete
        ) { project in
            Button("Delete", role: .destructive) { model.removeProject(project.id) }
        } message: { project in
            Text(project.name)
        }
    }

    private var meta: String {
        [song.artist, song.source.label, song.stems != nil ? "drums removed ✓" : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
