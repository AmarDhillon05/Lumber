// Camera section of the Record screen: film yourself while recording (muted
// clip, lined up with the song afterwards). Preview view comes from CameraService.

import SwiftUI
import UIKit

struct CameraPanel: View {
    let session: RecordSession

    var body: some View {
        CardSection("Camera") {
            Toggle("Film yourself while recording", isOn: Binding(
                get: { session.cameraOn },
                set: { on in Task { await session.setCamera(on) } }
            ))
            .font(.subheadline)
            .foregroundStyle(Theme.textSoft)
            .tint(Theme.accent)
            .disabled(session.isBusy)

            if session.cameraOn {
                CameraPreview(camera: session.camera)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    HintText("The clip has no sound; the mix is added when you export video.")
                    Spacer()
                    Button("Flip") { session.flipCamera() }
                        .lumberButton(small: true)
                        .disabled(session.isBusy)
                }
            }
            if let error = session.cameraError {
                ErrorText(error)
            }
        }
        .onDisappear {
            if session.cameraOn { session.camera.stopPreview() }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let camera: any CameraService

    func makeUIView(context: Context) -> UIView {
        camera.makePreviewView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
