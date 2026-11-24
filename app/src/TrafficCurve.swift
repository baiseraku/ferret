import Foundation

struct TrafficCurve {
    struct Segment {
        var end: CGPoint
        var control1: CGPoint
        var control2: CGPoint
    }

    // 单调三次插值穿过真实采样点，并限制切线，避免平滑后出现负值或虚假峰值。
    static func segments(through points: [CGPoint]) -> [Segment] {
        guard points.count >= 2 else { return [] }
        let widths = zip(points, points.dropFirst()).map { $1.x - $0.x }
        guard widths.allSatisfy({ $0 > 0 }) else { return [] }
        let slopes = points.indices.dropLast().map { (points[$0 + 1].y - points[$0].y) / widths[$0] }
        var tangents = [CGFloat](repeating: 0, count: points.count)
        tangents[0] = slopes[0]
        tangents[points.count - 1] = slopes[slopes.count - 1]
        if points.count > 2 {
            for i in 1..<(points.count - 1) where slopes[i - 1] * slopes[i] > 0 {
                let w1 = 2 * widths[i] + widths[i - 1]
                let w2 = widths[i] + 2 * widths[i - 1]
                tangents[i] = (w1 + w2) / (w1 / slopes[i - 1] + w2 / slopes[i])
            }
        }
        for i in slopes.indices {
            if slopes[i] == 0 {
                tangents[i] = 0
                tangents[i + 1] = 0
            } else {
                let a = tangents[i] / slopes[i]
                let b = tangents[i + 1] / slopes[i]
                let length = hypot(a, b)
                if length > 3 {
                    tangents[i] = 3 / length * a * slopes[i]
                    tangents[i + 1] = 3 / length * b * slopes[i]
                }
            }
        }
        return slopes.indices.map { i in
            let third = widths[i] / 3
            return Segment(end: points[i + 1],
                           control1: CGPoint(x: points[i].x + third, y: points[i].y + tangents[i] * third),
                           control2: CGPoint(x: points[i + 1].x - third, y: points[i + 1].y - tangents[i + 1] * third))
        }
    }
}
