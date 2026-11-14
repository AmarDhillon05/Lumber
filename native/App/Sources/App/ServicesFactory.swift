// The services the app runs with. Each starts as a mock (State/MockServices.swift);
// swap in the App/Sources/Platform implementation as it lands, e.g.
//   audio: AVAudioEngineService(),
// The screens only see the protocols in State/Services.swift.

extension Services {
    static func live() -> Services {
        Services(
            sources: MockSongSourceService(),
            spotify: MockSpotifyService(),
            audio: MockAudioEngineService(),
            camera: MockCameraService(),
            preview: MockMixPreviewService(),
            separation: MockSeparationService(),
            promptMix: MockPromptMixService(),
            export: MockExportService(),
            photos: MockPhotoLibraryService()
        )
    }
}
