// In-app playback for a saved recording, on expo-video's player (AVPlayer,
// which also plays WAV/M4A). Videos get a VideoView with the native controls;
// audio gets play/pause and a scrubber. If the Record engine already set the
// audio session to playAndRecord, expo-video keeps it (see its
// AudioSessionPolicy), so recording afterwards still works.
//
// Loaded through ./lazy — expo-video throws at import without its native code.

import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import Slider from '@react-native-community/slider';
import { VideoView, useVideoPlayer } from 'expo-video';
import { theme } from '../theme';
import { formatDuration } from './core';

export function RecordingPlayer({ uri, video, durationSec }: { uri: string; video: boolean; durationSec: number }) {
  const player = useVideoPlayer(uri, (p) => {
    p.loop = false;
  });
  const { width, height } = useWindowDimensions();

  if (video) {
    const h = Math.min(((width - 32) * 16) / 9, height * 0.55);
    return (
      <View style={[ps.videoBox, { height: h }]}>
        <VideoView player={player} style={StyleSheet.absoluteFill} contentFit="contain" nativeControls />
      </View>
    );
  }
  return <AudioControls player={player} durationSec={durationSec} />;
}

function AudioControls({ player, durationSec }: { player: ReturnType<typeof useVideoPlayer>; durationSec: number }) {
  const [pos, setPos] = useState(0);
  const [dur, setDur] = useState(durationSec);
  const [playing, setPlaying] = useState(false);
  const [scrub, setScrub] = useState<number | null>(null);

  useEffect(() => {
    const id = setInterval(() => {
      try {
        setPos(player.currentTime);
        setPlaying(player.playing);
        if (player.duration > 0) setDur(player.duration);
      } catch {
        // player released
      }
    }, 200);
    return () => clearInterval(id);
  }, [player]);

  const toggle = () => {
    if (player.playing) {
      player.pause();
      setPlaying(false);
      return;
    }
    if (dur > 0 && player.currentTime >= dur - 0.05) player.currentTime = 0;
    player.play();
    setPlaying(true);
  };

  const shown = scrub ?? pos;
  return (
    <View style={ps.audio}>
      <Pressable
        onPress={toggle}
        style={({ pressed }) => [ps.play, pressed && { opacity: 0.7 }]}
        accessibilityRole="button"
        accessibilityLabel={playing ? 'Pause' : 'Play'}
      >
        <Text style={ps.playText}>{playing ? '❚❚' : '▶'}</Text>
      </Pressable>
      <Text style={ps.time}>{formatDuration(shown)}</Text>
      <Slider
        style={{ flex: 1, height: 36 }}
        value={shown}
        minimumValue={0}
        maximumValue={Math.max(0.1, dur)}
        onValueChange={setScrub}
        onSlidingComplete={(v) => {
          player.currentTime = v;
          setPos(v);
          setScrub(null);
        }}
        minimumTrackTintColor={theme.accent}
        maximumTrackTintColor={theme.border}
        thumbTintColor={theme.accent}
      />
      <Text style={ps.time}>{formatDuration(dur)}</Text>
    </View>
  );
}

const ps = StyleSheet.create({
  videoBox: {
    borderRadius: 10,
    overflow: 'hidden',
    backgroundColor: theme.surfaceDeep,
    borderWidth: 1,
    borderColor: theme.border,
  },
  audio: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  play: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.accent,
  },
  playText: { color: theme.onAccent, fontSize: 16, fontWeight: '700' },
  time: { color: theme.textMuted, fontSize: 12, fontVariant: ['tabular-nums'], minWidth: 36, textAlign: 'center' },
});
