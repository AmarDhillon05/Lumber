// In-place iterative radix-2 complex FFT with precomputed tables. One instance
// per size; Demucs only ever needs n = 4096. Port of src/separation/fft.ts.

public struct FFT: Sendable {
    public let n: Int
    private let rev: [Int]
    private let cosTable: [Double]
    private let sinTable: [Double]

    public init(_ n: Int) {
        precondition(n > 0 && n & (n - 1) == 0, "FFT size must be a power of two, got \(n)")
        self.n = n
        let bits = n.trailingZeroBitCount
        var rev = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var r = 0
            for b in 0..<bits { r |= ((i >> b) & 1) << (bits - 1 - b) }
            rev[i] = r
        }
        self.rev = rev
        cosTable = (0..<(n / 2)).map { Foundation.cos(2 * Double.pi * Double($0) / Double(n)) }
        sinTable = (0..<(n / 2)).map { Foundation.sin(2 * Double.pi * Double($0) / Double(n)) }
    }

    /// Forward transform (e^{-i…}) unless `inverse`. The inverse is unscaled:
    /// callers apply 1/n.
    public func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        precondition(re.count == n && im.count == n)
        let n = self.n
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                rev.withUnsafeBufferPointer { rev in
                    for i in 0..<n {
                        let j = rev[i]
                        if j > i {
                            re.swapAt(i, j)
                            im.swapAt(i, j)
                        }
                    }
                }
                let sign: Double = inverse ? 1 : -1
                cosTable.withUnsafeBufferPointer { cosT in
                    sinTable.withUnsafeBufferPointer { sinT in
                        var size = 2
                        while size <= n {
                            let half = size >> 1
                            let step = n / size
                            var start = 0
                            while start < n {
                                for k in 0..<half {
                                    let wr = cosT[k * step]
                                    let wi = sign * sinT[k * step]
                                    let a = start + k
                                    let b = a + half
                                    let xr = re[b] * wr - im[b] * wi
                                    let xi = re[b] * wi + im[b] * wr
                                    re[b] = re[a] - xr
                                    im[b] = im[a] - xi
                                    re[a] += xr
                                    im[a] += xi
                                }
                                start += size
                            }
                            size <<= 1
                        }
                    }
                }
            }
        }
    }
}

import Foundation
