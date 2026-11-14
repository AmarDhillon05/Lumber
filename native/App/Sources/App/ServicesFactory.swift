// The services the app runs with: real ones from App/LiveServices.swift and
// App/LiveSources.swift. State/MockServices.swift keeps mocks for previews/tests.
// The screens only see the protocols in State/Services.swift.

extension Services {
    static func live() -> Services {
        Services(
            sources: LiveSongSources(),
            spotify: LiveSpotify(),
            audio: LiveAudioEngine(),
            camera: LiveCamera(),
            preview: LiveMixPreview(),
            separation: LiveSeparation(),
            promptMix: LivePromptMix(),
            export: LiveExport(),
            photos: LivePhotos()
        )
    }
}
