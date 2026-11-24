import Cocoa

final class TrafficChartView: NSView {
    static let uploadColor = Theme.menuOrange
    static let downloadColor = Theme.menuBlue
    var samples: [TunnelTrafficPoint] = [] {
        didSet {
            needsDisplay = true
            let latest = samples.last
            let describe: (Double?) -> String = { $0.map { StatusBarController.bytes($0) + "/s" } ?? "暂无采样" }
            setAccessibilityValue("上传 \(describe(latest?.upload))，下载 \(describe(latest?.download))")
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 134))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("最近一分钟的 SSH 隧道流量曲线，橙色上传，蓝色下载")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let now = Date().timeIntervalSinceReferenceDate
        let points = samples.filter { $0.time >= now - 60 && $0.time <= now }
        let peak = points.flatMap { [$0.upload, $0.download].compactMap { $0 } }.max() ?? 0
        let ceiling = pow(2, ceil(log2(max(1024, peak))))
        let plot = NSRect(x: 18, y: 26, width: bounds.width - 36, height: 84)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.minY + fraction * plot.height
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            grid.lineWidth = 0.5
            grid.stroke()
        }
        (StatusBarController.bytes(ceiling) + "/s" as NSString).draw(
            at: NSPoint(x: plot.minX, y: plot.maxY + 5), withAttributes: labelAttributes)
        for (text, fraction) in [("60 秒前", 0.0), ("30 秒前", 0.5), ("现在", 1.0)] {
            let width = (text as NSString).size(withAttributes: labelAttributes).width
            let x = plot.minX + fraction * plot.width - fraction * width
            (text as NSString).draw(at: NSPoint(x: x, y: 7), withAttributes: labelAttributes)
        }

        func drawLine(_ value: (TunnelTrafficPoint) -> Double?, color: NSColor) {
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            var previousTime: TimeInterval?
            var lastPoint: NSPoint?
            var run: [CGPoint] = []
            func finishRun() {
                guard let first = run.first else { return }
                path.move(to: first)
                for segment in TrafficCurve.segments(through: run) {
                    path.curve(to: segment.end, controlPoint1: segment.control1, controlPoint2: segment.control2)
                }
                run.removeAll(keepingCapacity: true)
            }
            for point in points {
                guard let rate = value(point) else {
                    finishRun(); previousTime = nil; lastPoint = nil; continue
                }
                let position = NSPoint(x: plot.maxX - (now - point.time) / 60 * plot.width,
                                       y: plot.minY + min(1, max(0, rate / ceiling)) * plot.height)
                if let previousTime = previousTime, point.time - previousTime > 8 || point.time <= previousTime { finishRun() }
                run.append(position)
                previousTime = point.time
                lastPoint = position
            }
            finishRun()
            color.setStroke()
            path.stroke()
            if let lastPoint = lastPoint, let latest = previousTime, now - latest <= 8 {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: lastPoint.x - 2, y: lastPoint.y - 2, width: 4, height: 4)).fill()
            }
        }
        drawLine({ $0.upload }, color: Self.uploadColor)
        drawLine({ $0.download }, color: Self.downloadColor)
        if !points.contains(where: { $0.upload != nil || $0.download != nil }) {
            let text = "等待流量采样…" as NSString
            let size = text.size(withAttributes: labelAttributes)
            text.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: labelAttributes)
        }
    }
}
