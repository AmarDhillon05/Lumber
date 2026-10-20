// Adapts an ONNX Runtime session (onnxruntime-react-native on the phone,
// onnxruntime-node in tests — same onnxruntime-common API) to DemucsRunner.

import type { InferenceSession, Tensor } from 'onnxruntime-common';
import { BINS, FRAMES, SEGMENT, type DemucsRunner } from './demucs';

type TensorCtor = new (type: 'float32', data: Float32Array, dims: readonly number[]) => Tensor;

export function ortRunner(session: InferenceSession, TensorClass: TensorCtor): DemucsRunner {
  return {
    async run(mix, mag) {
      const out = await session.run({
        mix: new TensorClass('float32', mix, [1, 2, SEGMENT]),
        mag: new TensorClass('float32', mag, [1, 4, BINS, FRAMES]),
      });
      return {
        spec: out.spec_out.data as Float32Array,
        wave: out.wave_out.data as Float32Array,
      };
    },
  };
}
