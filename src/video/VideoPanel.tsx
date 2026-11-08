// Edit screen: the take's camera clip, following the audio preview. Best
// effort: on every playhead tick the clip is re-seeked if it drifted more
// than ~120 ms from where the preview says it should be. The player stays
// muted and mixes with others, so expo-video leaves the engine's
// playAndRecord audio session alone.

import { useEffect, useRef } from 'react';
import { StyleSheet, View } from 'react-native';
import { VideoView, useVideoPlayer } from 'expo-video';
import { theme } from '../theme';
import { videoStartFor } from './sync';

const DRIFT_SEC = 0.12;
const SEEK_COOLDOWN_MS = 800;
const now = () => globalThis.performance?.now?.() ?? Date.now();

export function VideoPanel({
  uri,
  offsetSec,
  durationSec,
  playing,
  playhead,
  getPosition,
}: {
  uri: string;
  offsetSec: number; // song time of video time 0 (incl. nudge)
  durationSec: number; // fallback until the player knows
  playing: boolean;
  playhead: number;
  getPosition: () => number;
}) {
  const player = useVideoPlayer(uri, (p) => {
    p.muted = true;
    p.audioMixingMode = 'mixWithOthers';
    p.loop = false;
  });
  const lastSeek = useRef(0);
  const wasPlaying = useRef(false);

  useEffect(() => {
    const dur = player.duration > 0 ? player.duration : durationSec;
    const force = playing !== wasPlaying.current;
    wasPlaying.current = playing;
    const pos = playing ? getPosition() : playhead;
    const s = videoStartFor(pos, offsetSec, dur);
    try {
      if (!playing || !s || s.delaySec > 0) {
        // Stopped, or outside the clip: hold the matching frame.
        if (player.playing) player.pause();
        const t = s ? s.videoSec : dur;
        if (force || Math.abs(player.currentTime - t) > 0.05) player.currentTime = t;
        return;
      }
      const drift = player.currentTime - s.videoSec;
      if (force || (Math.abs(drift) > DRIFT_SEC && now() - lastSeek.current > SEEK_COOLDOWN_MS)) {
        player.currentTime = s.videoSec;
        lastSeek.current = now();
      }
      if (!player.playing) player.play();
    } catch (e) {
      console.warn('video preview sync failed', e);
    }
  }, [player, playing, playhead, offsetSec, durationSec, getPosition]);

  return (
    <View style={vs.box}>
      <VideoView player={player} style={StyleSheet.absoluteFill} contentFit="contain" nativeControls={false} />
    </View>
  );
}

const vs = StyleSheet.create({
  box: {
    height: 260,
    borderRadius: 10,
    overflow: 'hidden',
    backgroundColor: theme.surfaceDeep,
    borderWidth: 1,
    borderColor: theme.border,
  },
});
