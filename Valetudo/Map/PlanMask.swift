import SwiftUI

/// A map path as a grid of coverage values, one cell per map pixel. Softening the grid and
/// tracing it gives smooth outlines, where the path itself is a staircase of pixel rows.
struct PlanMask {
    let origin: CGPoint
    let width: Int
    let height: Int
    private(set) var values: [Float]

    init(_ path: Path, in box: CGRect, margin: Int = 3) {
        origin = CGPoint(x: box.minX.rounded(.down) - CGFloat(margin), y: box.minY.rounded(.down) - CGFloat(margin))
        width = max(1, Int(box.width.rounded(.up)) + margin * 2 + 1)
        height = max(1, Int(box.height.rounded(.up)) + margin * 2 + 1)
        values = [Float](repeating: 0, count: width * height)

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        // Bitmap rows run top down, the opposite of Core Graphics' default.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -origin.x, y: -origin.y)
        context.setShouldAntialias(false)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path.cgPath)
        context.fillPath()
        for i in values.indices { values[i] = Float(bytes[i]) / 255 }
    }

    /// A small Gaussian blur. Each pass rounds corners by about one map pixel.
    mutating func soften(passes: Int = 2) {
        var scratch = values
        for _ in 0..<passes {
            for y in 0..<height {
                let row = y * width
                for x in 0..<width {
                    let left = values[row + max(x - 1, 0)], right = values[row + min(x + 1, width - 1)]
                    scratch[row + x] = (left + 2 * values[row + x] + right) / 4
                }
            }
            for y in 0..<height {
                let above = max(y - 1, 0) * width, row = y * width, below = min(y + 1, height - 1) * width
                for x in 0..<width {
                    values[row + x] = (scratch[above + x] + 2 * scratch[row + x] + scratch[below + x]) / 4
                }
            }
        }
    }

    /// Closed outlines where the grid crosses `level`, in map pixels. Holes are returned as
    /// loops of their own, so fill them with the even-odd rule.
    func outlines(at level: Float, minimumArea: CGFloat = 0, tolerance: CGFloat = 0.3) -> [[CGPoint]] {
        var next: [Int: Int] = [:]
        next.reserveCapacity(width * 4)

        func horizontal(_ x: Int, _ y: Int) -> Int { (y * width + x) * 2 }
        func vertical(_ x: Int, _ y: Int) -> Int { (y * width + x) * 2 + 1 }

        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let tl = values[y * width + x], tr = values[y * width + x + 1]
                let br = values[(y + 1) * width + x + 1], bl = values[(y + 1) * width + x]
                let code = (tl >= level ? 8 : 0) | (tr >= level ? 4 : 0) | (br >= level ? 2 : 0) | (bl >= level ? 1 : 0)
                if code == 0 || code == 15 { continue }

                let top = horizontal(x, y), bottom = horizontal(x, y + 1)
                let left = vertical(x, y), right = vertical(x + 1, y)
                let joined = (tl + tr + br + bl) / 4 >= level

                // Every segment keeps the inside on the same side, so each crossing has one way out.
                switch code {
                case 8: next[top] = left
                case 4: next[right] = top
                case 2: next[bottom] = right
                case 1: next[left] = bottom
                case 12: next[right] = left
                case 6: next[bottom] = top
                case 3: next[left] = right
                case 9: next[top] = bottom
                case 7: next[left] = top
                case 11: next[top] = right
                case 13: next[right] = bottom
                case 14: next[bottom] = left
                case 10:
                    if joined {
                        next[top] = right
                        next[bottom] = left
                    } else {
                        next[top] = left
                        next[bottom] = right
                    }
                default: // 5
                    if joined {
                        next[left] = top
                        next[right] = bottom
                    } else {
                        next[right] = top
                        next[left] = bottom
                    }
                }
            }
        }

        func crossing(_ edge: Int) -> CGPoint {
            let cell = edge / 2
            let x = cell % width, y = cell / width
            let a = values[cell]
            let b = edge % 2 == 0 ? values[cell + 1] : values[cell + width]
            let t = CGFloat(a == b ? 0.5 : (level - a) / (b - a))
            // Values sit at the centre of each cell.
            return edge % 2 == 0
                ? CGPoint(x: origin.x + CGFloat(x) + t + 0.5, y: origin.y + CGFloat(y) + 0.5)
                : CGPoint(x: origin.x + CGFloat(x) + 0.5, y: origin.y + CGFloat(y) + t + 0.5)
        }

        var loops: [[CGPoint]] = []
        var seen = Set<Int>()
        seen.reserveCapacity(next.count)
        for start in next.keys where !seen.contains(start) {
            var loop: [CGPoint] = []
            var edge = start
            while !seen.contains(edge), let following = next[edge] {
                seen.insert(edge)
                loop.append(crossing(edge))
                edge = following
            }
            guard edge == start, loop.count >= 3, Self.area(of: loop) >= minimumArea else { continue }
            loops.append(Self.simplified(loop, tolerance: tolerance))
        }
        return loops
    }

    static func area(of loop: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Drops points that barely change the shape, which keeps the 3D model light.
    static func simplified(_ loop: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard loop.count > 8 else { return loop }
        // A closed loop has no ends to anchor on, so split it at the point farthest from the start.
        let far = loop.indices.max { distance(loop[0], loop[$0]) < distance(loop[0], loop[$1]) } ?? loop.count / 2
        let first = reduced(Array(loop[0...far]), tolerance: tolerance)
        let second = reduced(Array(loop[far...]) + [loop[0]], tolerance: tolerance)
        return Array(first.dropLast()) + Array(second.dropLast())
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func reduced(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var ranges = [(0, points.count - 1)]
        while let (start, end) = ranges.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let length = max(distance(a, b), 0.0001)
            var farthest = start, most: CGFloat = 0
            for i in (start + 1)..<end {
                let p = points[i]
                let offset = abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
                if offset > most {
                    most = offset
                    farthest = i
                }
            }
            if most > tolerance {
                keep[farthest] = true
                ranges.append((start, farthest))
                ranges.append((farthest, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}
