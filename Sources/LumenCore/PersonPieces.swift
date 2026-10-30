import Foundation

/// The parts of a person a style redraws besides its own, over the photo at the size of the person's mask: found from
/// their face, their outline and their bare skin or, for what isn't there yet (a hat), made room for where their head is.
public enum PersonPieces {
    /// A face's rows and columns, in pixels.
    struct Face {
        var top: Int
        var bottom: Int
        var left: Int
        var right: Int
        var height: Double { Double(bottom - top + 1) }
        var width: Double { Double(right - left + 1) }
        var centre: Double { Double(left + right) / 2 }

        init?(_ mask: MaskData) {
            var top = Int.max, bottom = -1, left = Int.max, right = -1
            for y in 0..<mask.size.height {
                for x in 0..<mask.size.width where mask[x, y] >= 128 {
                    top = min(top, y); bottom = max(bottom, y)
                    left = min(left, x); right = max(right, x)
                }
            }
            guard bottom - top >= 3, right - left >= 2 else { return nil }
            (self.top, self.bottom, self.left, self.right) = (top, bottom, left, right)
        }
    }

    /// Their neck and ears: the bare skin joined to the face, from its eyes down to a face's height below the chin.
    /// Without their `skin` (a host that can't look at its pixels), the person under the chin, about as wide as the jaw.
    /// Skin by the face but not joined to it, such as a friend's hand on their shoulder, is not theirs.
    public static func neck(face: MaskData, person: MaskData, skin: MaskData?) -> MaskData? {
        guard let f = Face(face) else { return nil }
        let size = person.size
        guard let skin else {
            let rows = (f.bottom - Int(f.height * 0.1))...(f.bottom + Int(f.height * 0.55))
            let columns = Int(f.centre - f.width * 0.4)...Int(f.centre + f.width * 0.4)
            let neck = MaskData(size: size, coverage: (0..<size.width * size.height).map { index in
                rows.contains(index / size.width) && columns.contains(index % size.width) ? person.coverage[index] : 0
            })
            return neck.boundingBox == nil ? nil : neck
        }
        let rows = (f.top + Int(f.height * 0.35))...(f.bottom + Int(f.height))
        let columns = Int(f.centre - f.width * 0.85)...Int(f.centre + f.width * 0.85)
        let bare = skin.size == size ? skin : skin.resized(to: size)
        var open = (0..<size.width * size.height).map { index in
            rows.contains(index / size.width) && columns.contains(index % size.width)
                && bare.coverage[index] >= 128 && person.coverage[index] >= 128 && face.coverage[index] < 128
        }
        // Grown from the face's own edge, so only skin that touches it is taken.
        let edge = face.grown(by: max(1, Int((f.height * 0.06).rounded())))
        var stack = open.indices.filter { open[$0] && edge.coverage[$0] >= 128 }
        var neck = [UInt8](repeating: 0, count: open.count)
        for index in stack { neck[index] = 255; open[index] = false }
        while let index = stack.popLast() {
            let x = index % size.width, y = index / size.width
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < size.width, ny >= 0, ny < size.height else { continue }
                let next = ny * size.width + nx
                if open[next] { open[next] = false; neck[next] = 255; stack.append(next) }
            }
        }
        let found = MaskData(size: size, coverage: neck)
        return found.boundingBox == nil ? nil : found
    }

    /// The rest of their bare skin below the chin, away from the face and the `near` pieces redrawn with it: their
    /// hands, their arms, a bare chest. Above the chin it is hair: the sunlit top of a man's brown hair has the colour
    /// of his skin. Bits under a tenth of the face's size are left out, and the gaps a highlight leaves are closed.
    public static func rest(face: MaskData, person: MaskData, skin: MaskData, near: MaskData?) -> MaskData? {
        guard let f = Face(face) else { return nil }
        let size = person.size
        let bare = skin.size == size ? skin : skin.resized(to: size)
        let taken = face.grown(by: max(1, Int((f.height * 0.1).rounded()))).union(near?.grown(by: 1) ?? face)
        let below = f.bottom + Int(f.height * 0.2)
        let found = MaskData(size: size, coverage: (0..<size.width * size.height).map { index in
            index / size.width >= below && bare.coverage[index] >= 128 && person.coverage[index] >= 128
                && taken.coverage[index] < 128 ? 255 : 0
        })
        // The gaps a highlight or a crease leaves are closed first, so a fingertip stays with its hand; then strips a few
        // pixels thin are cut off: the shaded wood of a bench under a hand has a hand's colour.
        let gap = max(1, Int((f.height * 0.04).rounded())), strip = max(1, Int((f.height * 0.02).rounded()))
        let closed = found.grown(by: gap).inverted().grown(by: gap).inverted()
        let left = closed.inverted().grown(by: strip).inverted().grown(by: strip).multiplied(by: closed)
        let least = Int(face.area * Double(size.width * size.height) * 0.1)
        var coverage = [UInt8](repeating: 0, count: left.coverage.count)
        for figure in left.components() where figure.count >= max(4, least) {
            for index in figure { coverage[index] = 255 }
        }
        let rest = MaskData(size: size, coverage: coverage).multiplied(by: person)
        return rest.boundingBox == nil ? nil : rest
    }

    /// The clothes on their upper body: the person from the chin down to their hips, less their face and skin.
    public static func top(face: MaskData, person: MaskData, skin: MaskData?) -> MaskData? {
        guard let f = Face(face) else { return nil }
        let size = person.size
        let rows = f.bottom...(f.bottom + Int(f.height * 3.2))
        let bare = skin.map { $0.size == size ? $0 : $0.resized(to: size) }
        let top = MaskData(size: size, coverage: (0..<size.width * size.height).map { index in
            rows.contains(index / size.width) && face.coverage[index] < 128 && (bare?.coverage[index] ?? 0) < 128
                ? person.coverage[index] : 0
        })
        return top.boundingBox == nil ? nil : top
    }

    /// Room just above their head for what they wear on it, which the photo doesn't have yet: an oval three face widths
    /// across, from three quarters of a face above the top of their `head` (the face's top less a third without one)
    /// to halfway down the face's height into it. Two face widths cut a pirate's tricorn off at its brim.
    public static func hat(face: MaskData, head: MaskData?) -> MaskData? {
        guard let f = Face(face) else { return nil }
        let size = face.size
        var crown = f.top - Int(f.height * 0.3)
        if let head = head.map({ $0.size == size ? $0 : $0.resized(to: size) }) {
            let columns = max(0, f.left)...min(size.width - 1, f.right)
            if let row = (0..<size.height).first(where: { y in columns.contains { head[$0, y] >= 128 } }) { crown = row }
        }
        let centreY = Double(crown) - f.height * 0.15
        let radiusX = f.width * 1.5, radiusY = f.height * 0.6
        let hat = MaskData(size: size, coverage: (0..<size.width * size.height).map { index in
            let dx = (Double(index % size.width) - f.centre) / radiusX
            let dy = (Double(index / size.width) - centreY) / radiusY
            return dx * dx + dy * dy <= 1 ? 255 : 0
        })
        return hat.boundingBox == nil ? nil : hat
    }

    /// How much of their chest and belly is bare skin, 0...1: the middle of the person from just below the chin to two
    /// faces below it. Nil when too little of them shows there to tell.
    public static func bareChest(face: MaskData, person: MaskData, skin: MaskData) -> Double? {
        guard let f = Face(face) else { return nil }
        let size = person.size
        let bare = skin.size == size ? skin : skin.resized(to: size)
        let rows = (f.bottom + Int(f.height * 0.6))...(f.bottom + Int(f.height * 2))
        let columns = Int(f.centre - f.width * 0.75)...Int(f.centre + f.width * 0.75)
        var body = 0, covered = 0
        for y in rows where y >= 0 && y < size.height {
            for x in columns where x >= 0 && x < size.width && person[x, y] >= 128 {
                body += 1
                if bare[x, y] >= 128 { covered += 1 }
            }
        }
        guard Double(body) >= f.height * f.width * 0.5 else { return nil }
        return Double(covered) / Double(body)
    }

    /// What a body wears, by its bare chest where its skin is known, else as the planner saw it; loose when neither says.
    public static func attire(planned: String?, bareChest: Double?) -> Attire {
        if let bareChest, bareChest >= 0.5 { return .bare }
        return planned.flatMap(Attire.init(rawValue:)) ?? .loose
    }
}
