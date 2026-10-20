// Small shared UI pieces: buttons, labelled slider, header bar, progress bar.

import type { ReactNode } from 'react';
import { Pressable, StyleSheet, Text, View, type ViewStyle } from 'react-native';
import Slider from '@react-native-community/slider';
import { theme } from '../theme';

type Kind = 'primary' | 'secondary' | 'danger' | 'ghost';

export function Button({
  title,
  onPress,
  kind = 'secondary',
  disabled,
  style,
  small,
}: {
  title: string;
  onPress: () => void;
  kind?: Kind;
  disabled?: boolean;
  style?: ViewStyle;
  small?: boolean;
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      style={({ pressed }) => [
        styles.btn,
        small && styles.btnSmall,
        kind === 'primary' && { backgroundColor: theme.accent },
        kind === 'danger' && { backgroundColor: theme.dangerDeep },
        kind === 'ghost' && { backgroundColor: 'transparent', borderColor: theme.border },
        pressed && { opacity: 0.7 },
        disabled && { opacity: 0.4 },
        style,
      ]}
    >
      <Text
        style={[
          styles.btnText,
          small && { fontSize: 13 },
          kind === 'primary' && { color: theme.onAccent },
        ]}
      >
        {title}
      </Text>
    </Pressable>
  );
}

export function Header({ title, onBack, right }: { title: string; onBack?: () => void; right?: ReactNode }) {
  return (
    <View style={styles.header}>
      {onBack ? (
        <Pressable onPress={onBack} hitSlop={12} style={styles.back}>
          <Text style={styles.backText}>‹ Back</Text>
        </Pressable>
      ) : (
        <View style={styles.back} />
      )}
      <Text style={styles.title} numberOfLines={1}>
        {title}
      </Text>
      <View style={[styles.back, { alignItems: 'flex-end' }]}>{right}</View>
    </View>
  );
}

export function LabeledSlider({
  label,
  value,
  min,
  max,
  step,
  onChange,
  onComplete,
  format,
  disabled,
  color,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  onChange?: (v: number) => void;
  onComplete?: (v: number) => void;
  format?: (v: number) => string;
  disabled?: boolean;
  color?: string;
}) {
  return (
    <View style={[styles.sliderRow, disabled && { opacity: 0.4 }]}>
      <Text style={styles.sliderLabel}>{label}</Text>
      <Slider
        style={{ flex: 1, height: 36 }}
        value={value}
        minimumValue={min}
        maximumValue={max}
        step={step}
        disabled={disabled}
        onValueChange={onChange}
        onSlidingComplete={onComplete}
        minimumTrackTintColor={color ?? theme.accent}
        maximumTrackTintColor={theme.border}
        thumbTintColor={theme.accent}
      />
      <Text style={styles.sliderValue}>{format ? format(value) : value.toFixed(2)}</Text>
    </View>
  );
}

export function ProgressBar({ progress, color }: { progress: number; color?: string }) {
  return (
    <View style={styles.progress}>
      <View
        style={[
          styles.progressFill,
          { width: `${Math.round(Math.min(1, Math.max(0, progress)) * 100)}%`, backgroundColor: color ?? theme.accent },
        ]}
      />
    </View>
  );
}

export function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>{title}</Text>
      {children}
    </View>
  );
}

export const styles = StyleSheet.create({
  btn: {
    backgroundColor: theme.card,
    borderWidth: 1,
    borderColor: theme.border,
    borderRadius: 10,
    paddingVertical: 12,
    paddingHorizontal: 16,
    alignItems: 'center',
    justifyContent: 'center',
  },
  btnSmall: { paddingVertical: 7, paddingHorizontal: 10, borderRadius: 8 },
  btnText: { color: theme.text, fontSize: 15, fontWeight: '600' },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  back: { width: 80 },
  backText: { color: theme.accent, fontSize: 16 },
  title: { flex: 1, color: theme.text, fontSize: 17, fontWeight: '700', textAlign: 'center' },
  sliderRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  sliderLabel: { color: theme.textSoft, width: 96, fontSize: 13 },
  sliderValue: { color: theme.textMuted, width: 56, textAlign: 'right', fontSize: 12, fontVariant: ['tabular-nums'] },
  progress: { height: 4, backgroundColor: theme.border, borderRadius: 2, overflow: 'hidden' },
  progressFill: { height: 4 },
  section: { marginTop: 18 },
  sectionTitle: {
    color: theme.textMuted,
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1,
    textTransform: 'uppercase',
    marginBottom: 8,
  },
});
