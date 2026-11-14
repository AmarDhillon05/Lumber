// SwiftUI wrapper for the camera preview (AVCaptureVideoPreviewLayer).

import AVFoundation
import SwiftUI
import UIKit

public struct CameraPreviewLayerView: UIViewRepresentable {
    public let session: AVCaptureSession
    public var gravity: AVLayerVideoGravity

    public init(session: AVCaptureSession, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.session = session
        self.gravity = gravity
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
        view.applyPortrait()
        return view
    }

    public func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.previewLayer.videoGravity = gravity
        view.applyPortrait()
    }

    /// UIView backed by an AVCaptureVideoPreviewLayer.
    public final class PreviewView: UIView {
        public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        public var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }

        /// The app is portrait-only; the connection exists once the session has an input.
        func applyPortrait() {
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
                c.videoRotationAngle = 90
            }
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            applyPortrait()
        }
    }
}
