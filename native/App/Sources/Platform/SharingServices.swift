// Getting exports out of the app: save to Photos (add-only access) and the
// system share sheet.

import Photos
import SwiftUI
import UIKit

public enum PhotoLibrary {
    /// Asks for add-only Photos access if undetermined; true when allowed.
    public static func requestAddOnlyAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited: return true
        case .notDetermined:
            let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return s == .authorized || s == .limited
        default: return false
        }
    }

    /// Copies a video (.mp4/.mov) into the Photos library. Audio files can't
    /// go to Photos — share those instead.
    public static func saveVideo(at url: URL) async throws {
        guard await requestAddOnlyAccess() else { throw PlatformError.photosPermissionDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: url, options: options)
            }
        } catch {
            throw PlatformError.exportFailed(error.localizedDescription)
        }
    }
}

/// The system share sheet for SwiftUI, e.g. `.sheet(item:) { ShareSheet(urls: [$0.url]) }`.
public struct ShareSheet: UIViewControllerRepresentable {
    public var items: [Any]
    public var onComplete: (@MainActor (Bool) -> Void)?

    public init(items: [Any], onComplete: (@MainActor (Bool) -> Void)? = nil) {
        self.items = items
        self.onComplete = onComplete
    }

    public init(urls: [URL], onComplete: (@MainActor (Bool) -> Void)? = nil) {
        self.init(items: urls, onComplete: onComplete)
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let onComplete = self.onComplete
        vc.completionWithItemsHandler = { _, completed, _, _ in
            MainActor.assumeIsolated { onComplete?(completed) }
        }
        return vc
    }

    public func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}

    /// Presents a share sheet over the top-most view controller (outside SwiftUI sheets).
    @MainActor
    public static func present(items: [Any]) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }
}
