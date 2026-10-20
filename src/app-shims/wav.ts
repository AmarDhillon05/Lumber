// SHIM — stand-in for src/dsp/wav.ts (being written on another branch).
// Delete once the real module lands and point src/app-shims/index.ts at it.

import type { Channels } from '../dsp/types';

export function encodeWav(channels: Channels, sampleRate: number, bitDepth: 16 | 24 | 32 = 16): Uint8Array {
  const nch = channels.length;
  const len = channels[0]?.length ?? 0;
  const bps = bitDepth / 8;
  const dataSize = len * nch * bps;
  const buf = new ArrayBuffer(44 + dataSize);
  const v = new DataView(buf);
  const str = (o: number, s: string) => {
    for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i));
  };
  str(0, 'RIFF');
  v.setUint32(4, 36 + dataSize, true);
  str(8, 'WAVE');
  str(12, 'fmt ');
  v.setUint32(16, 16, true);
  v.setUint16(20, bitDepth === 32 ? 3 : 1, true); // 3 = IEEE float
  v.setUint16(22, nch, true);
  v.setUint32(24, sampleRate, true);
  v.setUint32(28, sampleRate * nch * bps, true);
  v.setUint16(32, nch * bps, true);
  v.setUint16(34, bitDepth, true);
  str(36, 'data');
  v.setUint32(40, dataSize, true);
  let o = 44;
  for (let i = 0; i < len; i++) {
    for (let c = 0; c < nch; c++) {
      const s = Math.max(-1, Math.min(1, channels[c][i]));
      if (bitDepth === 16) {
        v.setInt16(o, Math.round(s < 0 ? s * 0x8000 : s * 0x7fff), true);
      } else if (bitDepth === 24) {
        const x = Math.round(s < 0 ? s * 0x800000 : s * 0x7fffff);
        v.setUint8(o, x & 0xff);
        v.setUint8(o + 1, (x >> 8) & 0xff);
        v.setUint8(o + 2, (x >> 16) & 0xff);
      } else {
        v.setFloat32(o, s, true);
      }
      o += bps;
    }
  }
  return new Uint8Array(buf);
}

export function decodeWav(bytes: Uint8Array): { channels: Channels; sampleRate: number } {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let o = 12;
  let fmt = 1;
  let nch = 1;
  let sr = 48000;
  let bits = 16;
  while (o + 8 <= v.byteLength) {
    const id = String.fromCharCode(v.getUint8(o), v.getUint8(o + 1), v.getUint8(o + 2), v.getUint8(o + 3));
    const size = v.getUint32(o + 4, true);
    if (id === 'fmt ') {
      fmt = v.getUint16(o + 8, true);
      nch = v.getUint16(o + 10, true);
      sr = v.getUint32(o + 12, true);
      bits = v.getUint16(o + 22, true);
    } else if (id === 'data') {
      const bps = bits / 8;
      const len = Math.floor(Math.min(size, v.byteLength - o - 8) / (bps * nch));
      const channels: Channels = Array.from({ length: nch }, () => new Float32Array(len));
      let p = o + 8;
      for (let i = 0; i < len; i++) {
        for (let c = 0; c < nch; c++) {
          let s: number;
          if (fmt === 3) s = v.getFloat32(p, true);
          else if (bits === 16) s = v.getInt16(p, true) / 0x8000;
          else if (bits === 24) s = (((v.getUint8(p + 2) << 24) | (v.getUint8(p + 1) << 16) | (v.getUint8(p) << 8)) >> 8) / 0x800000;
          else s = v.getInt32(p, true) / 0x80000000;
          channels[c][i] = s;
          p += bps;
        }
      }
      return { channels, sampleRate: sr };
    }
    o += 8 + size + (size & 1);
  }
  throw new Error('decodeWav: no data chunk');
}
