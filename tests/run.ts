// Node test runner (npm test → tsx tests/run.ts). Only pure modules are
// imported here; anything touching react-native-audio-api stays out.

import { counts } from './harness';
import * as dsp from './dsp.test';
import * as presets from './presets.test';

const suites: { run(): void }[] = [dsp, presets];

for (const s of suites) s.run();

const { passes, failures } = counts();
console.log(failures === 0 ? `\nALL PASS (${passes} checks)` : `\n${failures} FAILED, ${passes} passed`);
process.exit(failures === 0 ? 0 : 1);
