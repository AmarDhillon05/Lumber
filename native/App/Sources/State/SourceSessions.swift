// "Add a song" panel logic: YouTube search / pasted links and the Spotify
// browser. Owned by the Library screen so results and login state survive
// switching between the Files / YouTube / Spotify tabs.

import Foundation
import Observation

@MainActor
@Observable
final class YouTubeSearchSession {
    private let model: AppModel

    var query = ""
    private(set) var busy = false
    private(set) var results: [SearchResult] = []
    private(set) var label: String?
    private(set) var error: String?

    init(model: AppModel) {
        self.model = model
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        busy = true
        error = nil
        label = nil
        do {
            // A pasted YouTube/Spotify link resolves directly; anything else is a search.
            if let link = try await model.services.sources.resolvePastedLink(q) {
                label = link.label
                results = link.results
            } else {
                results = try await model.services.sources.searchYouTube(q)
            }
        } catch {
            self.error = error.localizedDescription
            results = []
        }
        busy = false
    }
}

@MainActor
@Observable
final class SpotifySession {
    enum Listing: Hashable {
        case liked
        case playlists
        case playlist(id: String, name: String)

        var title: String {
            switch self {
            case .liked: "Liked songs"
            case .playlists: "Your playlists"
            case .playlist(_, let name): name
            }
        }
    }

    private let model: AppModel
    private var spotify: any SpotifyService { model.services.spotify }

    private(set) var connected: Bool? // nil while checking
    private(set) var busy = false
    private(set) var error: String?
    private(set) var listing: Listing?
    private(set) var tracks: [SearchResult] = []
    private(set) var playlists: [SpotifyPlaylist] = []
    private(set) var nextOffset: Int?

    init(model: AppModel) {
        self.model = model
    }

    func refresh() async {
        guard connected == nil else { return }
        connected = await spotify.isConnected()
    }

    func connect() async {
        await run {
            try await self.spotify.connect()
            self.connected = true
        }
    }

    func disconnect() async {
        await spotify.disconnect()
        connected = false
        close()
    }

    func nowPlaying() async {
        await run {
            self.listing = nil
            if let track = try await self.spotify.nowPlaying() {
                self.tracks = [track]
            } else {
                self.tracks = []
                self.error = "Nothing is playing on Spotify right now."
            }
        }
    }

    func open(_ listing: Listing, more: Bool = false) async {
        let offset = more ? (nextOffset ?? 0) : 0
        await run {
            switch listing {
            case .liked:
                let page = try await self.spotify.likedTracks(offset: offset)
                self.tracks = more ? self.tracks + page.items : page.items
                self.nextOffset = page.nextOffset
                if !more { self.playlists = [] }
            case .playlists:
                let page = try await self.spotify.playlists(offset: offset)
                self.playlists = more ? self.playlists + page.items : page.items
                self.nextOffset = page.nextOffset
                if !more { self.tracks = [] }
            case .playlist(let id, _):
                let page = try await self.spotify.playlistTracks(playlistId: id, offset: offset)
                self.tracks = more ? self.tracks + page.items : page.items
                self.nextOffset = page.nextOffset
                if !more { self.playlists = [] }
            }
            self.listing = listing
        }
    }

    /// Back from a playlist to the playlist list; otherwise close the listing.
    func back() async {
        if case .playlist = listing {
            await open(.playlists)
        } else {
            close()
        }
    }

    func close() {
        listing = nil
        tracks = []
        playlists = []
        nextOffset = nil
    }

    private func run(_ work: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

extension AppModel {
    func saveToPhotos(_ rec: Recording) async throws -> PhotosSaveOutcome {
        try await services.photos.saveVideo(at: recordingURL(rec))
    }
}
