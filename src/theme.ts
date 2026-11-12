// Dark slate-indigo theme: near-black blue-gray surfaces, cool gray text,
// purple as the main accent and blue as the second. Plain constants — no light mode.
export const theme = {
  surface: '#0e0e16', // screen background
  surfaceDeep: '#08080e', // waveform wells
  card: '#171724', // cards, inputs, secondary buttons
  cardRaised: '#20202f',
  border: '#2b2b3d',

  text: '#f3f3fa',
  textSoft: '#d3d3e3',
  textMuted: '#9b9bb4',
  textFaint: '#6f6f8a',
  placeholder: '#585870',

  accent: '#8b5cf6', // purple: primary buttons, links, active state
  accentSoft: '#c4b5fd',
  onAccent: '#ffffff',
  blue: '#3b82f6', // secondary accent: progress, selection
  blueSoft: '#93c5fd',
  glow: '#a78bfa', // knob highlight while touched / non-zero

  song: '#60a5fa', // song lane (blue)
  drums: '#a78bfa', // drum lane (purple)

  danger: '#f43f5e',
  dangerSoft: '#fda4af',
  dangerDeep: '#9f1239',
  success: '#34d399',
  warning: '#fbbf24',

  // Knobs: cool gunmetal with a violet cast.
  steelFace: '#3a3a52',
  steelRimLight: '#8c8cab',
  steelRimSide: '#5c5c79',
  steelRimDark: '#16162a',
  steelHub: '#2c2c42',
  steelHubDark: '#18182a',
  steelHubLight: '#5a5a7a',
  steelHubSide: '#383852',
  steelPointer: '#ece9ff',
} as const;

export const fmtTime = (sec: number): string => {
  if (!Number.isFinite(sec)) return '--:--';
  const s = Math.max(0, sec);
  const m = Math.floor(s / 60);
  const r = s - m * 60;
  return `${m}:${r < 10 ? '0' : ''}${r.toFixed(1)}`;
};
