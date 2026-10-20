// Port of functions/audiofile.py. Holds decoded PCM + the deferred effect
// chain. The DSP primitives live on EffectChain (pure, engine-free); this adds
// decoding and offline rendering via react-native-audio-api.

import { decodeAudioData } from 'react-native-audio-api';
import { EffectChain } from './chain';
import { Channels } from './types';
import { renderChain, RenderResult } from './render';

// All decode/render runs at this rate, so PCM held in the session can be
// rebuilt into an AudioFile without separately tracking its sample rate.
export const TARGET_SAMPLE_RATE = 48000;

export class AudioFile extends EffectChain {
  data: Channels;
  sampleRate: number;

  constructor(data: Channels, sampleRate: number) {
    super();
    this.data = data;
    this.sampleRate = sampleRate;
  }

  /** Decode an audio/video file (mp4/m4a/mp3/wav) to PCM. */
  static async decode(uri: string, targetSampleRate = TARGET_SAMPLE_RATE): Promise<AudioFile> {
    // iOS only: decode straight from the file path with the native decoder
    // (file:// is stripped and the path percent-decoded by the library).
    const buffer = await decodeAudioData(uri, targetSampleRate);

    const channels: Channels = [];
    for (let c = 0; c < buffer.numberOfChannels; c++) {
      // slice() is a memcpy; Float32Array.from() copies element-by-element.
      channels.push(buffer.getChannelData(c).slice());
    }
    return new AudioFile(channels, buffer.sampleRate);
  }

  /** Execute the whole chain offline and return processed channels. */
  render(): Promise<RenderResult> {
    return renderChain(this.data, this.sampleRate, this.chain);
  }
}
