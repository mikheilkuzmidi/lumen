import Foundation

/// RGB guided interpolation in a narrow trimap, with fixed semantic seeds.
enum ColourMatte {
    static func refined(_ initial: [Double], rgb: [SIMD3<Double>], width: Int, height: Int,
                        foreground: [Bool], background: [Bool], radius: Int = 3) -> [Double] {
        func mean(_ values: [Double]) -> [Double] { MaskRefinement.boxMean(values, width: width, height: height, radius: radius) }
        let r = rgb.map(\.x), g = rgb.map(\.y), b = rgb.map(\.z)
        let mr = mean(r), mg = mean(g), mb = mean(b)
        let rr = mean(r.map { $0 * $0 }), gg = mean(g.map { $0 * $0 }), bb = mean(b.map { $0 * $0 })
        let rg = mean(zip(r, g).map(*)), rb = mean(zip(r, b).map(*)), gb = mean(zip(g, b).map(*))
        var alpha = initial
        for _ in 0..<2 {
            for i in alpha.indices {
                if foreground[i] { alpha[i] = 1 }
                if background[i] { alpha[i] = 0 }
            }
            let mp = mean(alpha), rp = mean(zip(r, alpha).map(*)), gp = mean(zip(g, alpha).map(*)), bp = mean(zip(b, alpha).map(*))
            var ar = alpha, ag = alpha, ab = alpha, offset = alpha
            for i in alpha.indices {
                // Scale conditioning to local RGB variance. A fixed bright-
                // image regularizer blends dark blue cloth into dark green
                // scenery, although those source colours are distinguishable.
                let vr = max(0, rr[i] - mr[i] * mr[i])
                let vg = max(0, gg[i] - mg[i] * mg[i])
                let vb = max(0, bb[i] - mb[i] * mb[i])
                let regularizer = max(1e-10, (vr + vg + vb) * 1e-6)
                let a = vr + regularizer, d = vg + regularizer, f = vb + regularizer
                let c = rg[i] - mr[i] * mg[i], e = rb[i] - mr[i] * mb[i], h = gb[i] - mg[i] * mb[i]
                let x = rp[i] - mr[i] * mp[i], y = gp[i] - mg[i] * mp[i], z = bp[i] - mb[i] * mp[i]
                let determinant = max(1e-40, a * (d * f - h * h) - c * (c * f - e * h) + e * (c * h - d * e))
                ar[i] = ((d * f - h * h) * x + (e * h - c * f) * y + (c * h - d * e) * z) / determinant
                ag[i] = ((e * h - c * f) * x + (a * f - e * e) * y + (c * e - a * h) * z) / determinant
                ab[i] = ((c * h - d * e) * x + (c * e - a * h) * y + (a * d - c * c) * z) / determinant
                offset[i] = mp[i] - ar[i] * mr[i] - ag[i] * mg[i] - ab[i] * mb[i]
            }
            let mar = mean(ar), mag = mean(ag), mab = mean(ab), mo = mean(offset)
            for i in alpha.indices {
                alpha[i] = foreground[i] ? 1 : background[i] ? 0 : min(1, max(0, mar[i] * r[i] + mag[i] * g[i] + mab[i] * b[i] + mo[i]))
            }
        }
        return alpha
    }
}
