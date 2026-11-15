// The camera clip in Edit, following the audio preview. The clip is muted (it
// has no audio track anyway); the song preview drives it. Video time for song
// time s is s − (recorded offset + video nudge), and the picture is matched to
// what you HEAR: the preview's playhead is the render clock, which reaches the
// ears outputLatency later, so the video is held back by that much.
//
// While playing, the player runs at rate 1 and is re-seeked only when it
// drifts more than ~2 frames from the target. While paused, it shows the
// frame under the playhead (so nudging the video offset shows its effect).

import AVFoundation
import SwiftUI
import UIKit

struct EditVideoPreview: View {
    let url: URL
    /// Song time where video time 0 belongs, nudge included.
    let offsetSec: Double
    let playhead: Double
    let playing: Bool

    @State private var player: AVPlayer?

    private static let maxDriftSec = 0.07

    var body: some View {
        PlayerLayerView(player: player)
            .aspectRatio(9 / 16, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 360)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {
                if player == nil {
                    let p = AVPlayer(url: url)
                    p.isMuted = true
                    p.automaticallyWaitsToMinimizeStalling = false
                    p.actionAtItemEnd = .pause
                    player = p
                }
                sync(force: true)
            }
            .onDisappear { player?.pause() }
            .onChange(of: playing) { sync(force: true) }
            .onChange(of: offsetSec) { sync(force: true) }
            .onChange(of: playhead) { sync(force: !playing) }
    }

    /// Video time that matches what's being heard now.
    private var target: Double {
        let heard = playing ? playhead - AVAudioSession.sharedInstance().outputLatency : playhead
        return heard - offsetSec
    }

    private func sync(force: Bool) {
        guard let player else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        let t = target
        let inside = t >= 0 && (!duration.isFinite || t < duration)
        if !playing || !inside {
            player.pause()
            if force || !inside {
                let clamped = duration.isFinite ? min(max(0, t), max(0, duration - 0.04)) : max(0, t)
                seek(player, clamped)
            }
            return
        }
        let current = player.currentTime().seconds
        if force || !current.isFinite || abs(current - t) > Self.maxDriftSec {
            seek(player, t)
        }
        if player.rate == 0 { player.play() }
    }

    private func seek(_ player: AVPlayer, _ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// AVPlayerLayer host, aspect-fit, no controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
