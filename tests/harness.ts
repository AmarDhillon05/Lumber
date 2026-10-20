// Tiny assertion harness: PASS/FAIL lines, failure count read by run.ts.

let failures = 0;
let passes = 0;

export function ok(name: string, cond: boolean, extra = ''): void {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  (' + extra + ')' : ''}`);
  if (cond) passes++;
  else failures++;
}

export function section(name: string): void {
  console.log(`\n# ${name}`);
}

export const counts = () => ({ passes, failures });

export const peak = (x: Float32Array): number => x.reduce((m, v) => Math.max(m, Math.abs(v)), 0);

export const finite = (x: Float32Array): boolean => x.every((v) => Number.isFinite(v));

export function tone(freq: number, amp: number, n: number, sr: number): Float32Array {
  const x = new Float32Array(n);
  for (let i = 0; i < n; i++) x[i] = amp * Math.sin((2 * Math.PI * freq * i) / sr);
  return x;
}
