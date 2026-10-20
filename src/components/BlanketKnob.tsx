// Rotary knob for one Blanket term, ported from Timber. Drag up to turn
// clockwise (increase), down to decrease; double-tap resets to 0. Value range
// −1..1. Controlled: the parent owns the value.

import { memo, useEffect, useRef, useState } from 'react';
import { Animated, PanResponder, StyleSheet, Text, View } from 'react-native';
import { BLANKET_TERMS, type BlanketTerm } from '../dsp/blanketTerms';
import { theme } from '../theme';

const SWEEP = 135; // degrees from center to each extreme
const DRAG_RANGE = 160; // px of vertical drag for the full −1..1
const GLOW = theme.drums;

function BlanketKnobBase({
  term,
  value,
  onChange,
  disabled,
}: {
  term: BlanketTerm;
  value: number;
  onChange: (term: BlanketTerm, value: number) => void;
  disabled?: boolean;
}) {
  const { label } = BLANKET_TERMS[term];
  const [active, setActive] = useState(false);

  const valueRef = useRef(value);
  valueRef.current = value;
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const disabledRef = useRef(disabled);
  disabledRef.current = disabled;
  const startValue = useRef(0);
  const lastTap = useRef(0);

  const lift = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.spring(lift, { toValue: active ? 1 : 0, useNativeDriver: true, friction: 6, tension: 140 }).start();
  }, [active, lift]);
  const scale = lift.interpolate({ inputRange: [0, 1], outputRange: [1, 1.08] });

  const pan = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => !disabledRef.current,
      onMoveShouldSetPanResponder: () => !disabledRef.current,
      // Keep the gesture while dragging inside a ScrollView.
      onPanResponderTerminationRequest: () => false,
      onPanResponderGrant: () => {
        const now = Date.now();
        if (now - lastTap.current < 300) onChangeRef.current(term, 0);
        lastTap.current = now;
        startValue.current = valueRef.current;
        setActive(true);
      },
      onPanResponderMove: (_e, g) => {
        const delta = (-g.dy / DRAG_RANGE) * 2;
        const next = Math.max(-1, Math.min(1, startValue.current + delta));
        onChangeRef.current(term, Math.round(next * 100) / 100);
      },
      onPanResponderRelease: () => setActive(false),
      onPanResponderTerminate: () => setActive(false),
    }),
  ).current;

  return (
    <View style={styles.wrap}>
      <Animated.View
        {...pan.panHandlers}
        style={[styles.lift, { transform: [{ scale }] }, active && { shadowColor: GLOW, shadowOpacity: 0.7, shadowRadius: 16 }]}
      >
        <View style={[styles.knob, disabled && styles.knobDisabled, active && { borderColor: GLOW }]}>
          <View style={styles.sheen} pointerEvents="none" />
          <View style={[styles.pointerBox, { transform: [{ rotate: `${value * SWEEP}deg` }] }]} pointerEvents="none">
            <View style={[styles.pointer, (active || value !== 0) && { backgroundColor: GLOW }]} />
          </View>
          <View style={styles.hub} pointerEvents="none" />
        </View>
      </Animated.View>
      <Text style={styles.label} numberOfLines={1}>
        {label}
      </Text>
      <Text style={[styles.value, active && { color: GLOW }]}>{value.toFixed(2)}</Text>
    </View>
  );
}

export const BlanketKnob = memo(BlanketKnobBase);

const SIZE = 56;
const HUB = 16;

const styles = StyleSheet.create({
  wrap: { width: 84, alignItems: 'center', paddingVertical: 4 },
  lift: {
    width: SIZE,
    height: SIZE,
    borderRadius: SIZE / 2,
    shadowColor: '#000',
    shadowOpacity: 0.5,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 6 },
  },
  knob: {
    width: SIZE,
    height: SIZE,
    borderRadius: SIZE / 2,
    backgroundColor: theme.steelFace,
    borderWidth: 2,
    borderTopColor: theme.steelRimLight,
    borderLeftColor: theme.steelRimSide,
    borderRightColor: theme.steelRimSide,
    borderBottomColor: theme.steelRimDark,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  knobDisabled: { opacity: 0.4 },
  sheen: {
    position: 'absolute',
    top: 3,
    width: SIZE * 0.74,
    height: SIZE * 0.5,
    borderRadius: SIZE,
    backgroundColor: 'rgba(255,255,255,0.10)',
  },
  pointerBox: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, alignItems: 'center', paddingTop: 5 },
  pointer: { width: 4, height: 14, borderRadius: 2, backgroundColor: theme.steelPointer },
  hub: {
    position: 'absolute',
    width: HUB,
    height: HUB,
    borderRadius: HUB / 2,
    backgroundColor: theme.steelHub,
    borderWidth: 1,
    borderTopColor: theme.steelHubDark,
    borderBottomColor: theme.steelHubLight,
    borderLeftColor: theme.steelHubSide,
    borderRightColor: theme.steelHubSide,
  },
  label: { color: theme.textSoft, fontSize: 11, marginTop: 4, textAlign: 'center' },
  value: { color: theme.textFaint, fontSize: 11, fontVariant: ['tabular-nums'] },
});
