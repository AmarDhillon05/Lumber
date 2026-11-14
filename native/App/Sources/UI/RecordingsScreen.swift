// Recordings: everything saved from Edit (mixes, videos, raw takes), newest
// first, with total storage. Tap a row to play it in place; its actions are
// Share, Save to Photos (videos), Rename and Delete.
// Port of src/screens/RecordingsScreen.tsx.

import AVKit
import SwiftUI
import UIKit

struct RecordingsScreen: View {
    @Environment(AppModel.self) private var model
    let openId: String?
    @State private var openRow: String?
    @State private var didOpen = false

    var body: some View {
        let sorted = RecordingFormat.sorted(model.recordings)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(sorted.count) recording\(sorted.count == 1 ? "" : "s") · \(RecordingFormat.bytes(RecordingFormat.totalSize(sorted)))")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    HintText("Stored on this iPhone. Delete what you don’t need to free space.")
                }
                .padding(.bottom, 4)
                if sorted.isEmpty {
                    Text("Nothing saved yet. In a take’s Edit screen, Export WAV, Export M4A or Export video — or Save raw take — and it shows up here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
                ForEach(sorted) { rec in
                    RecordingRow(rec: rec, open: openRow == rec.id) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            openRow = openRow == rec.id ? nil : rec.id
                        }
                    }
                }
            }
            .padding(Theme.gutter)
            .padding(.bottom, 32)
        }
        .lumberScreen("Recordings")
        .onAppear {
            if !didOpen {
                didOpen = true
                openRow = openId
            }
        }
    }
}

private struct RecordingRow: View {
    @Environment(AppModel.self) private var model
    let rec: Recording
    let open: Bool
    let onToggle: () -> Void

    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var savingPhotos = false
    @State private var message: (title: String, body: String)?

    var body: some View {
        let missing = !model.recordingExists(rec)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text([rec.kind.label, RecordingFormat.duration(rec.durationSec), RecordingFormat.bytes(rec.size)].joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                        Text(RecordingFormat.date(rec.createdAt))
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .foregroundStyle(Theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                if missing {
                    ErrorText("The file for this recording is missing. Delete it from the list.")
                } else {
                    RecordingPlayer(url: model.recordingURL(rec), video: rec.kind.isVideo)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if !missing {
                            ShareLink(item: model.recordingURL(rec)) {
                                Text("Share")
                            }
                            .lumberButton(.primary, small: true)
                        }
                        if rec.kind.isVideo {
                            Button(savingPhotos ? "Saving…" : "Save to Photos") { Task { await saveToPhotos() } }
                                .lumberButton(small: true)
                                .disabled(missing || savingPhotos)
                        }
                        Button("Rename") {
                            renameText = rec.title
                            renaming = true
                        }
                        .lumberButton(small: true)
                        Button("Delete") { confirmDelete = true }
                            .lumberButton(.danger, small: true)
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(open ? Theme.accent : Theme.border, lineWidth: 1))
        .alert("Rename recording", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.renameRecording(rec.id, renameText) }
        }
        .confirmationDialog("Delete recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.removeRecording(rec.id) }
        } message: {
            Text("\(rec.title) will be deleted from this iPhone.")
        }
        .alert(
            message?.title ?? "",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(message?.body ?? "") }
        )
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceDeep)
            if let url = model.thumbnailURL(rec), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: rec.kind.isVideo ? "play.fill" : "music.note")
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func saveToPhotos() async {
        savingPhotos = true
        do {
            switch try await model.saveToPhotos(rec) {
            case .saved:
                message = ("Saved to Photos", rec.title)
            case .denied:
                message = ("No access to Photos", "Allow Lumber (native) to add to Photos in Settings → Privacy & Security → Photos, then try again. You can also use Share → Save Video.")
            case .unavailable:
                message = ("Save to Photos", "This build can’t save to Photos — use Share → Save Video instead.")
            }
        } catch {
            message = ("Save to Photos failed", error.localizedDescription)
        }
        savingPhotos = false
    }
}

/// Plays a recording in place: a video player, or audio transport for mixes.
private struct RecordingPlayer: View {
    let url: URL
    let video: Bool
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        Group {
            if video {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                HStack {
                    Button {
                        guard let player else { return }
                        if playing {
                            player.pause()
                        } else {
                            if let item = player.currentItem, item.currentTime() >= item.duration, item.duration.isNumeric {
                                player.seek(to: .zero)
                            }
                            player.play()
                        }
                        playing.toggle()
                    } label: {
                        Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                    }
                    .lumberButton(small: true)
                    Spacer()
                }
            }
        }
        .onAppear {
            if player == nil { player = AVPlayer(url: url) }
        }
        .onDisappear {
            player?.pause()
            playing = false
        }
        .task(id: playing) {
            // Flip back to "Play" when the item finishes.
            while playing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if let player, player.rate == 0 { playing = false }
            }
        }
    }
}
