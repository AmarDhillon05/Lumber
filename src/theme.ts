// Dark take on Timber's silver-wood theme: near-black walnut surfaces,
// cream text and brushed-silver controls. Plain constants — no light mode.
export const theme = {
  surface: '#15100b', // screen background
  surfaceDeep: '#0b0805', // waveform wells
  card: '#241a11', // cards, inputs, secondary buttons
  cardRaised: '#30241a',
  border: '#3d2f20',

  text: '#f3e8d2',
  textSoft: '#ddccae',
  textMuted: '#b39c78',
  textFaint: '#8a744f',
  placeholder: '#6e5b3f',

  accent: '#c9ced6', // brushed silver
  onAccent: '#1a1108',

  song: '#8fb4d9', // song lane
  drums: '#e0a458', // drum lane

  danger: '#e2593f',
  dangerSoft: '#f0998b',
  dangerDeep: '#8c2f1e',
  success: '#71be55',
  warning: '#e8c547',

  steelFace: '#565b63',
  steelRimLight: '#a7adb6',
  steelRimSide: '#787e87',
  steelRimDark: '#23262b',
  steelHub: '#3c4046',
  steelHubDark: '#22252a',
  steelHubLight: '#6f757e',
  steelHubSide: '#4a4f56',
  steelPointer: '#eef1f4',
} as const;

export const fmtTime = (sec: number): string => {
  if (!Number.isFinite(sec)) return '--:--';
  const s = Math.max(0, sec);
  const m = Math.floor(s / 60);
  const r = s - m * 60;
  return `${m}:${r < 10 ? '0' : ''}${r.toFixed(1)}`;
};
