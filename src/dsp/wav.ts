// WAV encode/decode for de-interleaved PCM. Pure (no engine, no Buffer), so it
// runs the same on Hermes and in Node tests.
//
// encode: 16- or 24-bit integer PCM, or 32-bit IEEE float.
// decode: 8/16/24/32-bit integer PCM, 32/64-bit float, incl. WAVE_FORMAT_EXTENSIBLE.

import type { Channels } from './types';

/** 16 / 24 = integer PCM, 32 = IEEE float32. */
export type WavBitDepth = 16 | 24 | 32;

const FORMAT_PCM = 1;
const FORMAT_FLOAT = 3;
const FORMAT_EXTENSIBLE = 0xfffe;

export function encodeWav(channels: Channels, sampleRate: number, bitDepth: WavBitDepth = 16): Uint8Array {
  const numChannels = channels.length;
  if (numChannels === 0) throw new Error('encodeWav: no channels');
  const length = channels[0].length;
  const isFloat = bitDepth === 32;
  const bytesPerSample = bitDepth / 8;
  const blockAlign = numChannels * bytesPerSample;
  const dataSize = length * blockAlign;

  // Float files carry an 18-byte fmt (cbSize = 0) and a fact chunk, per spec.
  const fmtSize = isFloat ? 18 : 16;
  const factSize = isFloat ? 12 : 0;
  const headerSize = 12 + (8 + fmtSize) + factSize + 8;
  const padded = dataSize + (dataSize & 1);

  const out = new Uint8Array(headerSize + padded);
  const view = new DataView(out.buffer);
  const str = (o: number, s: string) => {
    for (let i = 0; i < s.length; i++) out[o + i] = s.charCodeAt(i);
  };

  str(0, 'RIFF');
  view.setUint32(4, headerSize - 8 + padded, true);
  str(8, 'WAVE');
  let o = 12;
  str(o, 'fmt ');
  view.setUint32(o + 4, fmtSize, true);
  view.setUint16(o + 8, isFloat ? FORMAT_FLOAT : FORMAT_PCM, true);
  view.setUint16(o + 10, numChannels, true);
  view.setUint32(o + 12, sampleRate, true);
  view.setUint32(o + 16, sampleRate * blockAlign, true);
  view.setUint16(o + 20, blockAlign, true);
  view.setUint16(o + 22, bitDepth, true);
  if (isFloat) view.setUint16(o + 24, 0, true); // cbSize
  o += 8 + fmtSize;
  if (isFloat) {
    str(o, 'fact');
    view.setUint32(o + 4, 4, true);
    view.setUint32(o + 8, length, true);
    o += 12;
  }
  str(o, 'data');
  view.setUint32(o + 4, dataSize, true);
  o += 8;

  for (let i = 0; i < length; i++) {
    for (let c = 0; c < numChannels; c++) {
      const s = channels[c][i];
      if (isFloat) {
        view.setFloat32(o, Number.isFinite(s) ? s : 0, true);
      } else if (bitDepth === 16) {
        view.setInt16(o, quantize(s, 32768), true);
      } else {
        const v = quantize(s, 8388608);
        out[o] = v & 0xff;
        out[o + 1] = (v >> 8) & 0xff;
        out[o + 2] = (v >> 16) & 0xff;
      }
      o += bytesPerSample;
    }
  }
  return out;
}

// Round to the nearest step of 1/scale and clamp to the signed integer range.
function quantize(s: number, scale: number): number {
  if (!Number.isFinite(s)) return 0;
  const v = Math.round(s * scale);
  return v > scale - 1 ? scale - 1 : v < -scale ? -scale : v;
}

export interface DecodedWav {
  channels: Channels;
  sampleRate: number;
}

export function decodeWav(input: Uint8Array | ArrayBuffer): DecodedWav {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (o: number) => String.fromCharCode(bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]);

  if (bytes.length < 12 || tag(0) !== 'RIFF' || tag(8) !== 'WAVE') {
    throw new Error('decodeWav: not a RIFF/WAVE file');
  }

  let format = 0;
  let numChannels = 0;
  let sampleRate = 0;
  let bitDepth = 0;
  let dataOffset = -1;
  let dataSize = 0;

  let o = 12;
  while (o + 8 <= bytes.length) {
    const id = tag(o);
    const size = view.getUint32(o + 4, true);
    const body = o + 8;
    if (id === 'fmt ') {
      format = view.getUint16(body, true);
      numChannels = view.getUint16(body + 2, true);
      sampleRate = view.getUint32(body + 4, true);
      bitDepth = view.getUint16(body + 14, true);
      if (format === FORMAT_EXTENSIBLE && size >= 40) {
        format = view.getUint16(body + 24, true); // first 2 bytes of SubFormat GUID
      }
    } else if (id === 'data') {
      dataOffset = body;
      // Streaming writers may leave the size as 0 / 0xFFFFFFFF; clamp to file.
      dataSize = Math.min(size, bytes.length - body);
      break;
    }
    o = body + size + (size & 1);
  }

  if (!numChannels || !sampleRate || !bitDepth) throw new Error('decodeWav: missing fmt chunk');
  if (dataOffset < 0) throw new Error('decodeWav: missing data chunk');

  const bps = bitDepth / 8;
  const frames = Math.floor(dataSize / (bps * numChannels));
  const channels: Channels = Array.from({ length: numChannels }, () => new Float32Array(frames));

  const read = sampleReader(view, format, bitDepth);
  let p = dataOffset;
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < numChannels; c++) {
      channels[c][i] = read(p);
      p += bps;
    }
  }
  return { channels, sampleRate };
}

function sampleReader(view: DataView, format: number, bitDepth: number): (p: number) => number {
  if (format === FORMAT_FLOAT) {
    if (bitDepth === 32) return (p) => view.getFloat32(p, true);
    if (bitDepth === 64) return (p) => view.getFloat64(p, true);
  } else if (format === FORMAT_PCM) {
    switch (bitDepth) {
      case 8:
        return (p) => (view.getUint8(p) - 128) / 128;
      case 16:
        return (p) => view.getInt16(p, true) / 32768;
      case 24:
        return (p) => {
          const v = view.getUint8(p) | (view.getUint8(p + 1) << 8) | (view.getInt8(p + 2) << 16);
          return v / 8388608;
        };
      case 32:
        return (p) => view.getInt32(p, true) / 2147483648;
    }
  }
  throw new Error(`decodeWav: unsupported format ${format} / ${bitDepth}-bit`);
}
