// Port of src/dsp/fft.ts: minimal in-place iterative radix-2 Cooley–Tukey FFT
// over Float storage with Double twiddles/intermediates (as the TS does over
// Float32Array). Used by the resonance detector, spectral gate and
// calibration's matched filter, so results match the TS bit-for-bit-ish.
//
// `DSP.fftDouble` is a separate all-Double FFT used only for convolution
// reverb (no TS counterpart: the TS ran that on a native ConvolverNode).

import Foundation

extension DSP {
    /// In-place FFT of `re`/`im` (same length, a power of two). `inverse` scales by 1/N.
    public static func fft(_ re: inout [Float], _ im: inout [Float], inverse: Bool = false) {
        let n = re.count
        precondition(im.count == n, "fft: re/im length mismatch")
        if n <= 1 { return }
        precondition(n & (n - 1) == 0, "fft: length must be a power of two")

        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                var j = 0
                for i in 1..<n {
                    var bit = n >> 1
                    while j & bit != 0 { j ^= bit; bit >>= 1 }
                    j ^= bit
                    if i < j {
                        re.swapAt(i, j)
                        im.swapAt(i, j)
                    }
                }

                let sign: Double = inverse ? 1 : -1
                var len = 2
                while len <= n {
                    let ang = sign * 2 * Double.pi / Double(len)
                    let wRe = cos(ang)
                    let wIm = sin(ang)
                    let halfLen = len / 2
                    var i = 0
                    while i < n {
                        var curRe = 1.0
                        var curIm = 0.0
                        for k in 0..<halfLen {
                            let a = i + k
                            let b = a + halfLen
                            let rb = Double(re[b]), ib = Double(im[b])
                            let tRe = rb * curRe - ib * curIm
                            let tIm = rb * curIm + ib * curRe
                            let ra = Double(re[a]), ia = Double(im[a])
                            re[b] = Float(ra - tRe)
                            im[b] = Float(ia - tIm)
                            re[a] = Float(ra + tRe)
                            im[a] = Float(ia + tIm)
                            let nextRe = curRe * wRe - curIm * wIm
                            curIm = curRe * wIm + curIm * wRe
                            curRe = nextRe
                        }
                        i += len
                    }
                    len <<= 1
                }

                if inverse {
                    let dn = Double(n)
                    for i in 0..<n {
                        re[i] = Float(Double(re[i]) / dn)
                        im[i] = Float(Double(im[i]) / dn)
                    }
                }
            }
        }
    }

    /// Smallest power of two ≥ max(1, n).
    public static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < max(1, n) { p <<= 1 }
        return p
    }

    /// All-Double in-place radix-2 FFT (precomputed twiddles). Used for
    /// FFT convolution, where the Float-storage FFT would add needless error.
    static func fftDouble(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        let n = re.count
        if n <= 1 { return }
        precondition(n & (n - 1) == 0, "fftDouble: length must be a power of two")
        let sign: Double = inverse ? 1 : -1
        // twiddles for the largest stage; stage `len` uses stride n/len
        var twRe = [Double](repeating: 0, count: n / 2)
        var twIm = [Double](repeating: 0, count: n / 2)
        for k in 0..<(n / 2) {
            let a = sign * 2 * Double.pi * Double(k) / Double(n)
            twRe[k] = cos(a)
            twIm[k] = sin(a)
        }
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                var j = 0
                for i in 1..<n {
                    var bit = n >> 1
                    while j & bit != 0 { j ^= bit; bit >>= 1 }
                    j ^= bit
                    if i < j { re.swapAt(i, j); im.swapAt(i, j) }
                }
                var len = 2
                while len <= n {
                    let half = len / 2
                    let stride = n / len
                    var i = 0
                    while i < n {
                        for k in 0..<half {
                            let a = i + k, b = a + half
                            let wr = twRe[k * stride], wi = twIm[k * stride]
                            let tRe = re[b] * wr - im[b] * wi
                            let tIm = re[b] * wi + im[b] * wr
                            re[b] = re[a] - tRe
                            im[b] = im[a] - tIm
                            re[a] += tRe
                            im[a] += tIm
                        }
                        i += len
                    }
                    len <<= 1
                }
                if inverse {
                    let s = 1 / Double(n)
                    for i in 0..<n { re[i] *= s; im[i] *= s }
                }
            }
        }
    }
}
