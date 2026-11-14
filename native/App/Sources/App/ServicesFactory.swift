// The services the app runs with: real ones from App/LiveServices.swift, plus
// mocks (State/MockServices.swift) for song sources, Spotify and prompt
// mixing until their LumberCore ports land.
// The screens only see the protocols in State/Services.swift.

extension Services {
    static func live() -> Services {
        Services(
            sources: MockSongSourceService(),
            spotify: MockSpotifyService(),
            audio: LiveAudioEngine(),
            camera: LiveCamera(),
            preview: LiveMixPreview(),
            separation: LiveSeparation(),
            promptMix: MockPromptMixService(),
            export: LiveExport(),
            photos: LivePhotos()
        )
    }
}
