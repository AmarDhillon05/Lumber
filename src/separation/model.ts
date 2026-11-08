// Demucs v4 htdemucs exported without STFT/iSTFT (weights CC-BY-NC 4.0, Meta).
// The app uses a copy whose attention runs in row slices (identical output,
// far lower peak memory), built from the original by
// scripts/separation/chunk_attention.py and published as a release asset by
// .github/workflows/model.yml.
export const SOURCE_MODEL_URL =
  'https://huggingface.co/sathvik77/htdemucs-core-onnx/resolve/main/htdemucs_core.onnx';
export const MODEL_RELEASE = 'models-v1';
export const MODEL_URL = `https://github.com/AmarDhillon05/Lumber/releases/download/${MODEL_RELEASE}/htdemucs_chunked.onnx`;
export const MODEL_FILENAME = 'htdemucs_chunked_v1.onnx';
