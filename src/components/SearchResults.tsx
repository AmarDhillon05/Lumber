// YouTube results with a Get button and download progress. Shared by the
// search box and the Spotify panel.

import { Pressable, StyleSheet, Text, View } from 'react-native';
import { youtubeSource } from '../sources';
import type { SearchResult } from '../sources/types';
import { useStore } from '../state/store';
import { fmtTime, theme } from '../theme';
import { ProgressBar } from './ui';

export function SearchResults({ results, label }: { results: SearchResult[]; label?: string | null }) {
  const jobs = useStore((s) => s.jobs);
  const { addSong, setJob } = useStore.getState();

  const download = async (r: SearchResult) => {
    const jobId = `yt:${r.externalId}`;
    if (jobs[jobId] && !jobs[jobId].error) return;
    setJob(jobId, { label: 'Downloading', progress: 0 });
    try {
      const song = await youtubeSource.fetch(r, (p) => setJob(jobId, { label: 'Downloading', progress: p }));
      addSong(song);
      setJob(jobId, null);
    } catch (e) {
      setJob(jobId, { label: 'Failed', progress: 0, error: String((e as Error).message ?? e) });
    }
  };

  return (
    <View>
      {label ? <Text style={rs.meta}>{label}</Text> : null}
      {results.map((r) => {
        const job = jobs[`yt:${r.externalId}`];
        return (
          <Pressable key={r.externalId} style={rs.result} onPress={() => download(r)}>
            <View style={{ flex: 1 }}>
              <Text style={rs.title} numberOfLines={1}>
                {r.title}
              </Text>
              <Text style={rs.meta} numberOfLines={1}>
                {[r.artist, r.durationSec ? fmtTime(r.durationSec) : null].filter(Boolean).join(' · ')}
              </Text>
              {job ? (
                job.error ? (
                  <Text style={rs.error}>{job.error}</Text>
                ) : (
                  <View style={{ marginTop: 6 }}>
                    <ProgressBar progress={job.progress} />
                  </View>
                )
              ) : null}
            </View>
            <Text style={rs.action}>{job && !job.error ? `${Math.round(job.progress * 100)}%` : 'Get'}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const rs = StyleSheet.create({
  result: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  title: { color: theme.text, fontSize: 16, fontWeight: '600' },
  meta: { color: theme.textMuted, fontSize: 12, marginTop: 2 },
  error: { color: theme.dangerSoft, fontSize: 12, marginTop: 6 },
  action: { color: theme.accent, fontSize: 14, fontWeight: '600' },
});
