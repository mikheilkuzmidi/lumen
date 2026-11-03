import CoreGraphics
import CoreImage
import Foundation
import LumenCore

/// A conservative material-conditioned proposal for one consistent recolour.
/// The model supplies the colour; the photo supplies geometry and shading.
/// Interiors recover source fold/detail positions, and the uncertain pixels
/// either side of the semantic contour are decided from the photo's own
/// cloth/exterior evidence. Ambiguous material and non-solid colour proposals
/// decline so the existing renderer remains available to the caller.
enum MaterialRecolour {
  static func prepare(
    _ proposalImage: EncodedImage, over original: EncodedImage,
    instances inputInstances: [MaskData],
    analysisStarted: (@Sendable () -> Void)? = nil
  ) throws -> PreparedPatch? {
    try Task.checkCancellation()
    guard inputInstances.count >= 2, inputInstances.allSatisfy(\.followsPhoto) else { return nil }
    guard inputInstances.allSatisfy({
      $0.size.width > 0 && $0.size.height > 0
        && $0.size.width <= Int.max / $0.size.height
        && $0.coverage.count == $0.size.width * $0.size.height
    }) else { return nil }
    let nonemptyInstances = inputInstances.filter { $0.boundingBox != nil }
    guard nonemptyInstances.count >= 2 else { return nil }
    let source = try RGBAPixels(original)
    guard min(source.width, source.height) >= 16,
      source.bytes.enumerated().allSatisfy({ $0.offset % 4 != 3 || $0.element == 255 })
    else { return nil }
    let generated: RGBAPixels
    let decoded = try RGBAPixels(proposalImage)
    if decoded.width == source.width, decoded.height == source.height {
      generated = decoded
    } else {
      guard
        let image = CIImage(data: proposalImage.data, options: [.applyOrientationProperty: true])
      else { return nil }
      let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
      let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
      ])
      guard
        let data = context.pngRepresentation(
          of: PhotoCompositor.resized(image, to: bounds), format: .RGBA8,
          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
      else { return nil }
      generated = try RGBAPixels(
        EncodedImage(
          data: data, format: .png, size: PixelSize(width: source.width, height: source.height)))
    }
    // These are finished photographic pixels, not unassociated colour. A
    // transparent proposal would otherwise be interpreted as dark cloth.
    guard generated.bytes.enumerated().allSatisfy({ $0.offset % 4 != 3 || $0.element == 255 })
    else {
      return nil
    }
    let w = source.width
    let h = source.height
    let n = w * h
    try Task.checkCancellation()
    let size = PixelSize(width: w, height: h)
    let masks = nonemptyInstances.map { $0.resized(to: size) }
    let instances = masks.map(\.coverage)
    let union = masks.dropFirst().reduce(masks[0]) { $0.union($1) }.coverage
    let linear = (0...255).map { v -> Double in
      let c = Double(v) / 255
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    func rgb(_ p: RGBAPixels, _ i: Int) -> SIMD3<Double> {
      SIMD3(
        linear[Int(p.bytes[i * 4])], linear[Int(p.bytes[i * 4 + 1])],
        linear[Int(p.bytes[i * 4 + 2])])
    }
    func y(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    func byte(_ v: Double) -> UInt8 {
      let c = max(0, min(1, v))
      return UInt8(((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
    }
    func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
    func neighbours(_ i: Int, _ f: (Int) -> Void) {
      let x = i % w
      let yy = i / w
      if x > 0 { f(i - 1) }
      if x + 1 < w { f(i + 1) }
      if yy > 0 { f(i - w) }
      if yy + 1 < h { f(i + w) }
    }
    var inside = [[Int]]()
    var owner = [Int](repeating: -1, count: n)
    var distance = [Int](repeating: -1, count: n)
    var queue: [Int] = []
    var head = 0
    // Internal checkpoint for deterministic background/cancellation tests.
    // It follows actual decode, validation and mask preparation; production
    // callers supply nil and the pixel algorithm remains unchanged.
    analysisStarted?()
    for (k, m) in instances.enumerated() {
      try Task.checkCancellation()
      var d = [Int](repeating: 0, count: n)
      var q: [Int] = []
      var p = 0
      for i in 0..<n where m[i] > 0 {
        if i & 8191 == 0 { try Task.checkCancellation() }
        d[i] = -1
        var boundary = false
        neighbours(i) { j in if m[j] == 0 { boundary = true } }
        if boundary {
          d[i] = 1
          q.append(i)
        }
      }
      while p < q.count {
        if p & 8191 == 0 { try Task.checkCancellation() }
        let i = q[p]
        p += 1
        neighbours(i) { j in
          if m[j] > 0 && d[j] < 0 {
            d[j] = d[i] + 1
            q.append(j)
          }
        }
      }
      inside.append(d)
      for i in 0..<n where m[i] > 0 {
        if owner[i] < 0 || d[i] > inside[owner[i]][i] { owner[i] = k }
      }
    }
    for i in 0..<n where owner[i] >= 0 {
      distance[i] = 0
      queue.append(i)
    }
    while head < queue.count {
      if head & 8191 == 0 { try Task.checkCancellation() }
      let i = queue[head]
      head += 1
      if distance[i] >= 18 { continue }
      neighbours(i) { j in
        if distance[j] < 0 {
          distance[j] = distance[i] + 1
          owner[j] = owner[i]
          queue.append(j)
        }
      }
    }
    func labValue(_ image: RGBAPixels, _ i: Int) -> ColourMeasurement {
      ColourMeasuring.lab(
        red: image.bytes[i * 4], green: image.bytes[i * 4 + 1], blue: image.bytes[i * 4 + 2])
    }
    func hue(_ l: ColourMeasurement) -> Int {
      if hypot(l.a, l.b) < 8 { return 12 }
      return Int(
        ((atan2(l.b, l.a) + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)
          / (2 * Double.pi) * 12).rounded(.down)) % 12
    }
    func changed(_ i: Int) -> Bool {
      let a = labValue(source, i)
      let b = labValue(generated, i)
      return sqrt(pow(a.lightness - b.lightness, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2)) > 10
    }
    var hueGroups = [[Int]](repeating: [], count: 13)
    for k in instances.indices {
      try Task.checkCancellation()
      for i in 0..<n where instances[k][i] > 0 && inside[k][i] > 8 && changed(i) {
        hueGroups[hue(labValue(generated, i))].append(i)
      }
    }
    let dominant = hueGroups.indices.max { hueGroups[$0].count < hueGroups[$1].count }!
    func sameHue(_ h: Int) -> Bool {
      if dominant == 12 { return h == 12 }
      return h != 12 && min(abs(h - dominant), 12 - abs(h - dominant)) <= 1
    }
    let common = hueGroups.indices.filter { sameHue($0) }.flatMap { hueGroups[$0] }
    let changedTotal = hueGroups.reduce(0) { $0 + $1.count }
    guard !common.isEmpty, Double(common.count) / Double(max(1, changedTotal)) >= 0.8 else {
      return nil
    }
    func palette(_ ids: [Int]) -> SIMD3<Double> {
      SIMD3(
        median(ids.map { rgb(generated, $0).x }), median(ids.map { rgb(generated, $0).y }),
        median(ids.map { rgb(generated, $0).z }))
    }
    let sharedTarget = palette(common)
    var material: [SIMD3<Double>] = []
    var materialSpread: [SIMD3<Double>] = []
    var target: [SIMD3<Double>] = []
    var medianY: [Double] = []
    var sourceHue: [Double] = []
    var sourceHueTolerance: [Double] = []
    // Neutral cloth evidence inside the approved support, from the instance's
    // own trusted interior. Zero means the instance is chromatic.
    var neutralChromaLimit: [Double] = []
    var neutralLightnessFloor: [Double] = []
    // The brightest ordinary interior shading ratio. Edge highlights may not
    // exceed it, so a lit rim does not become a light outline.
    var ratioCap: [Double] = []
    func hueDistance(_ a: Double, _ b: Double) -> Double {
      let delta = abs(a - b)
      return min(delta, 2 * Double.pi - delta)
    }
    for k in instances.indices {
      try Task.checkCancellation()
      let ids = (0..<n).filter { instances[k][$0] > 0 && inside[k][$0] > 8 }
      // Every instance must supply its own trusted material evidence. A tiny
      // or eroded-away instance cannot borrow an unrelated object's geometry.
      guard ids.count >= 32 else { return nil }
      let normal = ids.map { i -> SIMD3<Double> in
        let c = rgb(source, i)
        return c / max(0.0001, c.x + c.y + c.z)
      }
      let centre = SIMD3(median(normal.map(\.x)), median(normal.map(\.y)), median(normal.map(\.z)))
      material.append(centre)
      materialSpread.append(
        SIMD3(
          max(0.015, 3 * median(normal.map { abs($0.x - centre.x) })),
          max(0.015, 3 * median(normal.map { abs($0.y - centre.y) })),
          max(0.015, 3 * median(normal.map { abs($0.z - centre.z) }))))
      let spread = materialSpread[k]
      guard max(spread.x, spread.y, spread.z) <= 0.36 else { return nil }
      // A bright fold need not have the median fabric's linear RGB ratios.
      // A tightly clustered chromatic source hue is an independent material
      // cue; neutral cloth and uncertain/multicolour distributions do not
      // acquire this permission.
      let interiorLab = ids.map { labValue(source, $0) }
      let chromas = interiorLab.map(\.chroma).sorted()
      let lightnesses = interiorLab.map(\.lightness).sorted()
      if chromas[chromas.count / 2] < 8 {
        neutralChromaLimit.append(max(10, chromas[chromas.count * 9 / 10] + 4))
        neutralLightnessFloor.append(lightnesses[lightnesses.count / 50] - 12)
      } else {
        neutralChromaLimit.append(0)
        neutralLightnessFloor.append(0)
      }
      let chromatic = interiorLab.filter { $0.chroma >= 8 }
      let angle = atan2(median(chromatic.map(\.b)), median(chromatic.map(\.a)))
      let hueMAD = median(chromatic.map { hueDistance(atan2($0.b, $0.a), angle) })
      sourceHue.append(angle)
      sourceHueTolerance.append(
        chromatic.count * 2 >= ids.count && hueMAD <= Double.pi / 30
          ? min(Double.pi / 10, max(Double.pi / 18, 3 * hueMAD)) : 0)
      // Two substantial separated lightness modes can be a source pattern.
      // Do not flatten that uncertainty merely because the model proposed a
      // single colour. Ordinary redraw still remains available to the caller.
      var lightnessModes = [Int](repeating: 0, count: 10)
      for i in ids {
        lightnessModes[min(9, max(0, Int(labValue(source, i).lightness / 10)))] += 1
      }
      for a in 0..<7 where Double(lightnessModes[a]) / Double(ids.count) >= 0.20 {
        for b in (a + 3)..<10 where Double(lightnessModes[b]) / Double(ids.count) >= 0.20 {
          let valley = lightnessModes[(a + 1)..<b].reduce(0, +)
          if Double(valley) / Double(ids.count) < 0.10 { return nil }
        }
      }
      medianY.append(median(ids.map { y(rgb(source, $0)) }))
      let ratios = ids.map { y(rgb(source, $0)) / max(0.0001, medianY[k]) }.sorted()
      ratioCap.append(min(6, max(1, ratios[ratios.count * 95 / 100])))
      var unmatchedStructure = Set<Int>()
      for i in ids {
        let luminance = y(rgb(source, i))
        let extreme =
          (medianY[k] < 0.1 && luminance > 0.5)
          || (medianY[k] > 0.3 && luminance < 0.01)
        guard extreme,
          abs(labValue(source, i).lightness - labValue(generated, i).lightness) > 15
        else { continue }
        var sharp = false
        neighbours(i) { j in
          if abs(labValue(source, i).lightness - labValue(source, j).lightness) > 20 {
            sharp = true
          }
        }
        if sharp { unmatchedStructure.insert(i) }
      }
      // A missing high-contrast interior mark cannot be reconstructed safely
      // from the model's replacement colour. Leave that material to the old
      // quality-checked path rather than silently recolouring its print.
      // Isolated glints or a few mislabeled skin pixels are not a graphic.
      // Require a spatially coherent high-contrast mark before declining.
      while let seed = unmatchedStructure.first {
        var component = [seed]
        unmatchedStructure.remove(seed)
        var cursor = 0
        while cursor < component.count {
          let current = component[cursor]
          cursor += 1
          neighbours(current) { next in
            if unmatchedStructure.remove(next) != nil { component.append(next) }
          }
        }
        guard component.count < 8 else { return nil }
      }
      let changedMaterial = ids.filter { changed($0) && sameHue(hue(labValue(generated, $0))) }
      target.append(changedMaterial.count >= 32 ? palette(changedMaterial) : sharedTarget)
    }
    var proposal = source
    var result = source
    var neutral = [Bool](repeating: false, count: n)
    var materialColour = [Bool](repeating: false, count: n)
    var materialCompatible = [Bool](repeating: false, count: n)
    var allowed = [Bool](repeating: false, count: n)
    var protected = [Bool](repeating: false, count: n)
    var unchangedByModel = [Bool](repeating: false, count: n)
    var neutralSource = [Bool](repeating: false, count: n)
    var sourceLabs = [ColourMeasurement](
      repeating: ColourMeasurement(lightness: 0, a: 0, b: 0), count: n)
    for i in 0..<n where owner[i] >= 0 { sourceLabs[i] = labValue(source, i) }
    for i in 0..<n where owner[i] >= 0 {
      let k = owner[i]
      let c = rgb(source, i)
      let unit = c / max(0.0001, c.x + c.y + c.z)
      let d = unit - material[k]
      let difference = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
      let ratio = y(c) / max(0.0001, medianY[k])
      let same = (0..<3).allSatisfy {
        abs(Int(source.bytes[i * 4 + $0]) - Int(generated.bytes[i * 4 + $0])) < 12
      }
      protected[i] =
        same
        && ((ratio > 4 && y(c) > 0.03)
          || (medianY[k] > 0.03 && (ratio < 0.12 || difference > 0.14)))
      let rgbBytes = (0..<3).map { Double(source.bytes[i * 4 + $0]) }
      let lo = rgbBytes.min()!
      let hi = rgbBytes.max()!
      let achromatic = hi - lo <= max(4, hi * 0.04)
      let sourceMatch =
        abs(d.x) < materialSpread[k].x && abs(d.y) < materialSpread[k].y
        && abs(d.z) < materialSpread[k].z
      let sourceLab = sourceLabs[i]
      let hueMatches = sourceHueTolerance[k] > 0 && sourceLab.chroma >= 8
        && hueDistance(atan2(sourceLab.b, sourceLab.a), sourceHue[k]) <= sourceHueTolerance[k]
      // Inside the approved support, a warm or cool white is still neutral
      // cloth when it is as neutral as the instance's own interior.
      let labNeutral = neutralChromaLimit[k] > 0 && sourceLab.chroma <= neutralChromaLimit[k]
        && sourceLab.lightness >= neutralLightnessFloor[k]
      // Hue and neutral-Lab permissions describe material the semantic model
      // already selected. Outside that support they would admit skin with a
      // similar hue (a neck above a red collar), so zero-support extension
      // keeps the strict source-ratio evidence only.
      materialColour[i] = sourceMatch || achromatic || (union[i] > 0 && (hueMatches || labNeutral))
      materialCompatible[i] = medianY[k] > 0.03 && y(c) > 0.015 && materialColour[i]
      neutral[i] = materialCompatible[i] && !(union[i] == 0 && same)
      unchangedByModel[i] = same
      neutralSource[i] = achromatic
      if union[i] > 0 { allowed[i] = true }
    }
    // A closed semantic hole has no exterior material evidence. Preserve it,
    // even when its RGB happens to match the surrounding cloth and the model
    // painted it. Find true exterior zeros from the crop boundary first.
    var exteriorZero = [Bool](repeating: false, count: n)
    queue = []
    head = 0
    func border(_ i: Int) -> Bool { i < w || i >= n - w || i % w == 0 || i % w == w - 1 }
    for i in 0..<n where union[i] == 0 && border(i) {
      exteriorZero[i] = true
      queue.append(i)
    }
    while head < queue.count {
      if head & 8191 == 0 { try Task.checkCancellation() }
      let i = queue[head]
      head += 1
      neighbours(i) { j in
        if union[j] == 0, !exteriorZero[j] {
          exteriorZero[j] = true
          queue.append(j)
        }
      }
    }
    // A zero-support material component that reaches independently known
    // exterior background is ambiguous (a white shirt against a white wall,
    // for example). The generator painting it does not create new evidence.
    var ambiguousExterior = [Bool](repeating: false, count: n)
    queue = []
    head = 0
    for i in 0..<n where union[i] == 0 {
      if !exteriorZero[i] {
        ambiguousExterior[i] = true
      } else if materialCompatible[i] && (distance[i] >= 18 || border(i)) {
        ambiguousExterior[i] = true
        queue.append(i)
      }
    }
    while head < queue.count {
      if head & 8191 == 0 { try Task.checkCancellation() }
      let i = queue[head]
      head += 1
      neighbours(i) { j in
        if !ambiguousExterior[j], union[j] == 0, materialCompatible[j], distance[j] >= 0 {
          ambiguousExterior[j] = true
          queue.append(j)
        }
      }
    }
    // Preserve a model-aligned source graphic and its antialias transition.
    // Only trusted interior graphics seed this exclusion. Boundary skin
    // remains protected directly, but must not force adjacent cloth back
    // to a pale/flesh model proposal. This grows exclusion, never colour.
    let graphicEdge = MaskData(size: size, coverage: (0..<n).map {
      protected[$0] && union[$0] >= 128 && inside[owner[$0]][$0] > 8 ? 255 : 0
    })
      .grown(by: 4).coverage
    // Material/source-detail proposal is computed here, not loaded from an earlier output.
    for i in 0..<n where union[i] > 0 {
      let k = owner[i]
      let v = target[k] * min(6, max(0, y(rgb(source, i)) / max(0.0001, medianY[k])))
      for c in 0..<3 { proposal.bytes[i * 4 + c] = byte(v[c]) }
    }
    // Proportional linear luminance retains source fold/detail positions
    // and normalized contrast. Adding an absolute L* high-frequency term
    // would emboss pale fabric when its reflectance becomes dark navy.
    // Zero-support extension needs a continuous, high-signal source material path.
    queue = (0..<n).filter { union[$0] > 0 }
    head = 0
    func L(_ yy: Double) -> Double { yy > 216.0 / 24389 ? 116 * cbrt(yy) - 16 : yy * 24389.0 / 27 }
    while head < queue.count {
      if head & 8191 == 0 { try Task.checkCancellation() }
      let i = queue[head]
      head += 1
      neighbours(i) { j in
        // Neutral cloth keeps its own shadow and rim light: a grey shaded
        // side and its bright edge are one material, while a warm arm or a
        // differently coloured object still stops the extension.
        let step = abs(L(y(rgb(source, i))) - L(y(rgb(source, j))))
        if !allowed[j], distance[j] >= 0, neutral[j], !ambiguousExterior[j], owner[j] == owner[i],
          step < 10 || (neutralSource[i] && neutralSource[j] && step < 40)
        {
          allowed[j] = true
          queue.append(j)
        }
      }
    }
    // Contour evidence. A binary semantic contour can sit a few pixels inside
    // or outside the photographed edge, so the first `band` pixels on each
    // side are decided from the photo itself. Exterior evidence comes only
    // from unselected pixels beyond that band: the garment's own uncovered
    // rim is never evidence that the garment is background.
    let band = 3
    let reach = 8
    func farExterior(_ j: Int) -> Bool {
      union[j] == 0 && exteriorZero[j] && (distance[j] > band || distance[j] < 0)
    }
    func deltaE(_ p: ColourMeasurement, _ q: ColourMeasurement) -> Double {
      let l = p.lightness - q.lightness, a = p.a - q.a, b = p.b - q.b
      return (l * l + a * a + b * b).squareRoot()
    }
    func write(_ i: Int, _ v: SIMD3<Double>) {
      for c in 0..<3 { result.bytes[i * 4 + c] = byte(v[c]) }
    }
    func recoloured(_ k: Int, luminance: Double) -> SIMD3<Double> {
      target[k] * min(ratioCap[k], max(0, luminance / max(0.0001, medianY[k])))
    }
    struct Edge {
      var cloth: SIMD3<Double>
      var clothLab: ColourMeasurement
      var exterior: [Int]
      var nearestExterior: Double
    }
    func edgeEvidence(_ i: Int, _ k: Int) -> Edge? {
      let x = i % w
      let yy = i / w
      var sum = SIMD3<Double>(repeating: 0)
      var count = 0
      var exterior: [Int] = []
      for ry in max(0, yy - reach)...min(h - 1, yy + reach) {
        for rx in max(0, x - reach)...min(w - 1, x + reach) {
          let j = ry * w + rx
          if union[j] >= 250, owner[j] == k, inside[k][j] > band, !protected[j], graphicEdge[j] == 0 {
            sum += rgb(source, j)
            count += 1
          } else if farExterior(j) {
            exterior.append(j)
          }
        }
      }
      guard count > 0, !exterior.isEmpty else { return nil }
      let cloth = sum / Double(count)
      let clothLab = ColourMeasuring.lab(red: byte(cloth.x), green: byte(cloth.y), blue: byte(cloth.z))
      let own = sourceLabs[i]
      let nearest = exterior.map { deltaE(own, labValue(source, $0)) }.min() ?? .infinity
      return Edge(cloth: cloth, clothLab: clothLab, exterior: exterior, nearestExterior: nearest)
    }
    // Explains an edge pixel as a mixture of local cloth and one nearby
    // exterior colour. Nil when no exterior colour separates from the cloth
    // or the pixel is not such a mixture (a lit rim, a cord, a shadow).
    func unmix(_ s: SIMD3<Double>, _ e: Edge) -> (alpha: Double, background: SIMD3<Double>)? {
      var fits: [(error: Double, alpha: Double, background: SIMD3<Double>)] = []
      for j in e.exterior {
        let b = rgb(source, j)
        let v = e.cloth - b
        let vv = (v * v).sum()
        guard vv >= 0.0016 else { continue }
        let alpha = max(0, min(1, ((s - b) * v).sum() / vv))
        let r = s - (b + alpha * v)
        fits.append(((r * r).sum().squareRoot() / vv.squareRoot(), alpha, b))
      }
      guard let best = fits.min(by: { $0.error < $1.error }), best.error <= 0.3 else { return nil }
      // Average the exterior colours that explain the pixel equally well, so
      // one noisy background sample does not set the edge colour.
      let similar = fits.filter { $0.error <= best.error + 0.05 && abs($0.alpha - best.alpha) <= 0.15 }
      let background = similar.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.background } / Double(similar.count)
      return (best.alpha, background)
    }
    func clothFamily(_ i: Int, _ k: Int) -> Bool {
      let l = sourceLabs[i]
      if neutralChromaLimit[k] > 0 {
        return l.chroma <= neutralChromaLimit[k] && l.lightness >= neutralLightnessFloor[k]
      }
      return l.chroma >= 6
        && hueDistance(atan2(l.b, l.a), sourceHue[k]) <= max(sourceHueTolerance[k], Double.pi / 8)
    }
    // A semantic contour can include a small background/skin gap. Restore
    // source only when its non-material colour is also evidenced by nearby
    // unselected exterior pixels beyond the uncertain band, never by darkness
    // alone (which could be a genuine fabric fold).
    func matchesFarExterior(_ i: Int) -> Bool {
      let own = sourceLabs[i]
      let x = i % w
      let yy = i / w
      for ry in max(0, yy - reach - 1)...min(h - 1, yy + reach + 1) {
        for rx in max(0, x - reach - 1)...min(w - 1, x + reach + 1) {
          let j = ry * w + rx
          if farExterior(j), deltaE(own, labValue(source, j)) < 12 { return true }
        }
      }
      return false
    }
    for i in 0..<n where owner[i] >= 0 {
      if i & 8191 == 0 { try Task.checkCancellation() }
      let k = owner[i]
      let s = rgb(source, i)
      if union[i] > 0 {
        if protected[i] { continue }
        if graphicEdge[i] > 0 {
          // Model-aligned antialias around a preserved source graphic, where
          // the model kept the graphic or painted the requested colour. A
          // dark fold read as trim must not import a different painted
          // object (an arm-coloured patch) from the proposal.
          let model = labValue(generated, i)
          let agrees = unchangedByModel[i] || (dominant == 12 ? hue(model) == 12 : sameHue(hue(model)))
          for c in 0..<3 {
            result.bytes[i * 4 + c] = agrees ? generated.bytes[i * 4 + c] : proposal.bytes[i * 4 + c]
          }
          continue
        }
        let depth = inside[k][i]
        if union[i] < 250 {
          // A fractional semantic edge is a finished photographic pixel.
          if !materialColour[i], depth <= 6, matchesFarExterior(i) { continue }
          for c in 0..<3 { result.bytes[i * 4 + c] = generated.bytes[i * 4 + c] }
          continue
        }
        if depth <= band, let e = edgeEvidence(i, k) {
          let clothDistance = deltaE(sourceLabs[i], e.clothLab)
          // The selection took in skin or background beside the garment.
          if !materialColour[i], e.nearestExterior + 2 <= clothDistance { continue }
          if let mix = unmix(s, e), mix.alpha < 0.98 {
            if mix.alpha < 0.2 { continue }
            // A convex mixture of the recoloured cloth and the real exterior:
            // an edge pixel can never acquire a hue neither side has.
            write(i, mix.alpha * recoloured(k, luminance: y(e.cloth)) + (1 - mix.alpha) * mix.background)
            continue
          }
          write(i, recoloured(k, luminance: y(s)))
          continue
        }
        if !materialColour[i], depth <= 6, matchesFarExterior(i) { continue }
        for c in 0..<3 { result.bytes[i * 4 + c] = proposal.bytes[i * 4 + c] }
        continue
      }
      if allowed[i] && neutral[i] && !protected[i] {
        write(i, target[k] * min(6, max(0, y(s) / max(0.0001, medianY[k]))))
        continue
      }
      // The garment's own photographed rim just outside the selection: cloth
      // closer to the garment than to any exterior colour beyond the band.
      guard distance[i] >= 1, distance[i] <= band, exteriorZero[i], !ambiguousExterior[i],
        !unchangedByModel[i], let e = edgeEvidence(i, k)
      else { continue }
      let clothDistance = deltaE(sourceLabs[i], e.clothLab)
      if e.nearestExterior + 2 <= clothDistance { continue }
      if let mix = unmix(s, e) {
        guard mix.alpha >= 0.5 else { continue }
        write(i, mix.alpha >= 0.98 ? recoloured(k, luminance: y(s))
          : mix.alpha * recoloured(k, luminance: y(e.cloth)) + (1 - mix.alpha) * mix.background)
        continue
      }
      if clothFamily(i, k), clothDistance + 3 < e.nearestExterior {
        write(i, recoloured(k, luminance: y(s)))
      }
    }

    try Task.checkCancellation()
    let changed = (0..<n).map { i -> UInt8 in
      (0..<3).contains { source.bytes[i * 4 + $0] != result.bytes[i * 4 + $0] } ? 255 : 0
    }
    guard changed.contains(255) else { return nil }
    // Pixels already contain their physical background term. A second
    // soft opacity would put the old garment colour back on that edge.
    return PreparedPatch(
      image: try result.encoded(), mask: MaskData(size: size, coverage: changed, followsPhoto: true)
    )
  }
}
