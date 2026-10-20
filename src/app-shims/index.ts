// Single switchboard for APIs other branches are delivering. The app imports
// these names from here only; when a real module lands on main, re-export it
// below instead of the shim and delete the shim file.
//
//   presets.ts    → src/dsp/presets.ts      (origin/feat/dsp)
//   mix.ts        → src/dsp/mix.ts          (feat/dsp, in progress)
//   wav.ts        → src/dsp/wav.ts          (feat/dsp, in progress)
//   separation.ts → src/separation/index.ts cachedSeparation (origin/feat/separation)
//   localFile.ts  → src/sources/localFile.ts
//   youtube.ts    → src/sources/youtube.ts

export { PRESETS, getPreset, fillValues, presetValues } from './presets';
export type { Preset, BlanketValues } from './presets';
export { mixTake, resample } from './mix';
export type { MixTakeInput } from './mix';
export { encodeWav, decodeWav } from './wav';
export { cachedSeparation } from './separation';
export { importLocalFile } from './localFile';
export { youtubeSource } from './youtube';
