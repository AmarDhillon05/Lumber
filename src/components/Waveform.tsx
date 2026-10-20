// A simple waveform lane: one vertical bar per column, drawn with Views
// (no SVG dependency). Peaks come from audio/peaks.windowPeaks.

import { memo } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { theme } from '../theme';

function WaveformBase({
  peaks,
  color,
  height = 64,
  label,
  playhead, // 0..1 across the lane, or null
}: {
  peaks: Float32Array | null;
  color: string;
  height?: number;
  label?: string;
  playhead?: number | null;
}) {
  const max = peaks ? Math.max(0.05, ...Array.from(peaks)) : 1;
  return (
    <View style={[styles.lane, { height }]}>
      <View style={styles.bars}>
        {peaks
          ? Array.from(peaks).map((p, i) => (
              <View
                key={i}
                style={{
                  flex: 1,
                  marginHorizontal: 0.5,
                  height: Math.max(1, (p / max) * (height - 8)),
                  backgroundColor: color,
                  borderRadius: 1,
                }}
              />
            ))
          : null}
      </View>
      {playhead != null && playhead >= 0 && playhead <= 1 ? (
        <View style={[styles.playhead, { left: `${playhead * 100}%` }]} />
      ) : null}
      {label ? <Text style={styles.label}>{label}</Text> : null}
    </View>
  );
}

export const Waveform = memo(WaveformBase);

const styles = StyleSheet.create({
  lane: {
    backgroundColor: theme.surfaceDeep,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: theme.border,
    overflow: 'hidden',
    justifyContent: 'center',
  },
  bars: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 2, height: '100%' },
  playhead: { position: 'absolute', top: 0, bottom: 0, width: 2, backgroundColor: theme.text },
  label: { position: 'absolute', top: 4, left: 6, color: theme.textMuted, fontSize: 10, fontWeight: '700' },
});
