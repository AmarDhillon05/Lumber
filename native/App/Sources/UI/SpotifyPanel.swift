// Spotify tab of "Add a song": connect, then Now playing / Liked / Playlists.
// Picked tracks are matched to YouTube and downloaded (SongSourceService.fetch).
// Port of src/screens/SpotifyPanel.tsx.

import SwiftUI

struct SpotifyPanel: View {
    let session: SpotifySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch session.connected {
            case nil:
                HintText("Checking for a saved login…")
            case false?:
                HintText("Connect your Spotify account to pick songs from what's playing, your liked songs or your playlists. Lumber finds each song on YouTube to download it.")
                Button("Connect Spotify") { Task { await session.connect() } }
                    .lumberButton(.primary, fill: true)
                    .disabled(session.busy)
            case true?:
                connectedControls
            }
            if session.busy {
                ProgressView().tint(Theme.accent)
            }
            if let error = session.error {
                ErrorText(error)
            }
            listing
        }
        .task { await session.refresh() }
    }

    private var connectedControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("Now playing") { Task { await session.nowPlaying() } }
                    .lumberButton(.primary, small: true)
                Button("Liked") { Task { await session.open(.liked) } }
                    .lumberButton(small: true)
                Button("Playlists") { Task { await session.open(.playlists) } }
                    .lumberButton(small: true)
                Button("Disconnect") { Task { await session.disconnect() } }
                    .lumberButton(.ghost, small: true)
            }
        }
        .disabled(session.busy)
    }

    @ViewBuilder private var listing: some View {
        if let listing = session.listing {
            HStack {
                Text(listing.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Button(isPlaylist(listing) ? "Back" : "Close") { Task { await session.back() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentSoft)
            }
            .padding(.top, 6)
        }
        if !session.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.playlists) { playlist in
                    Button {
                        Task { await session.open(.playlist(id: playlist.id, name: playlist.name)) }
                    } label: {
                        HStack {
                            Text(playlist.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                            if let n = playlist.trackCount {
                                Text("\(n) songs")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Theme.border)
                }
            }
            HintText("Spotify only lets apps open playlists you created.")
        }
        if !session.tracks.isEmpty {
            SearchResultsList(results: session.tracks)
        }
        if let listing = session.listing, session.nextOffset != nil {
            Button("Load more") { Task { await session.open(listing, more: true) } }
                .lumberButton(small: true)
                .disabled(session.busy)
        }
    }

    private func isPlaylist(_ listing: SpotifySession.Listing) -> Bool {
        if case .playlist = listing { return true }
        return false
    }
}
