// Streaming 32-bit float WAV writer: header first with placeholder sizes,
// interleaved blocks appended as they arrive, sizes patched on close.
// Float keeps headroom — a no-drums stem can exceed ±1 before the final mix.

export interface ByteSink {
  offset: number | null;
  writeBytes(bytes: Uint8Array): Promise<void> | void;
}

const HEADER_BYTES = 44;

export function wavHeader(sampleRate: number, channels: number, dataBytes: number): Uint8Array {
  const b = new Uint8Array(HEADER_BYTES);
  const dv = new DataView(b.buffer);
  const ascii = (o: number, s: string) => {
    for (let i = 0; i < s.length; i++) b[o + i] = s.charCodeAt(i);
  };
  ascii(0, 'RIFF');
  dv.setUint32(4, 36 + dataBytes, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  dv.setUint32(16, 16, true);
  dv.setUint16(20, 3, true); // IEEE float
  dv.setUint16(22, channels, true);
  dv.setUint32(24, sampleRate, true);
  dv.setUint32(28, sampleRate * channels * 4, true);
  dv.setUint16(32, channels * 4, true);
  dv.setUint16(34, 32, true);
  ascii(36, 'data');
  dv.setUint32(40, dataBytes, true);
  return b;
}

export class WavStream {
  private dataBytes = 0;

  private constructor(
    private sink: ByteSink,
    private sampleRate: number,
    private channels: number,
  ) {}

  static async open(sink: ByteSink, sampleRate: number, channels: number): Promise<WavStream> {
    sink.offset = 0;
    await sink.writeBytes(wavHeader(sampleRate, channels, 0));
    return new WavStream(sink, sampleRate, channels);
  }

  async write(block: Float32Array[]): Promise<void> {
    const frames = block[0].length;
    const out = new Float32Array(frames * this.channels);
    for (let i = 0; i < frames; i++)
      for (let c = 0; c < this.channels; c++) out[i * this.channels + c] = block[c][i];
    await this.sink.writeBytes(new Uint8Array(out.buffer));
    this.dataBytes += out.byteLength;
  }

  async finish(): Promise<void> {
    this.sink.offset = 0;
    await this.sink.writeBytes(wavHeader(this.sampleRate, this.channels, this.dataBytes));
  }
}
