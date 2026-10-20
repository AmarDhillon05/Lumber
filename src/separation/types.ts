// On-device drum removal (HTDemucs via ONNX Runtime + Core ML EP).
// Runs once per song; results are cached next to the song file.

export interface SeparationResult {
  drumsUri: string; // file:// WAV of the song's original drums
  noDrumsUri: string; // file:// WAV of bass + other + vocals
  sampleRate: number;
}

export type SeparationProgress = (fraction: number) => void;
