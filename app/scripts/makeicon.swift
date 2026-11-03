import AppKit

// Apple 原生风格：白底圆角方形（squircle）+ 黑色字形（参照 ChatGPT / magpie 的白底黑标）
// 字形：两条箭头组成的循环（上→右、下←左），表达「双向转发 / 隧道」

func squirclePath(in rect: NSRect, n: CGFloat = 5.0) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 720
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func drawIcon(size S: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    ctx.setShouldAntialias(true)

    // macOS 图标留白
    let inset = S * 0.09
    let bodyRect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let body = squirclePath(in: bodyRect)

    // 底部投影
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.16)
    shadow.shadowBlurRadius = S * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.010)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 白底极轻渐变（更接近系统白底图标）
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let g = NSGradient(colors: [NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
                                NSColor(srgbRed: 0.957, green: 0.957, blue: 0.969, alpha: 1)])!
    g.draw(in: bodyRect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 极细内描边（系统白底图标常见的一道浅边）
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    body.lineWidth = max(1, S * 0.004)
    NSColor(srgbRed: 0.80, green: 0.80, blue: 0.83, alpha: 0.55).setStroke()
    body.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 字形：两条水平箭头（上→右、下←左），线条加粗以在白底上更醒目
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let black = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.121, alpha: 1)   // #1D1D1F
    let x0 = S * 0.285, x1 = S * 0.700
    let stroke = S * 0.058
    let headW = S * 0.118, headH = S * 0.112
    let yTop = S * 0.572, yBot = S * 0.428

    func arrow(cy: CGFloat, toRight: Bool) {
        // 箭头尖与底边（三角形）
        let tipX = toRight ? x1 + headW * 0.30 : x0 - headW * 0.30
        let baseX = toRight ? tipX - headW : tipX + headW
        let shaftEnd = baseX
        let shaftStart = toRight ? x0 : x1

        let shaft = NSBezierPath()
        shaft.lineWidth = stroke
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: shaftStart, y: cy))
        shaft.line(to: NSPoint(x: shaftEnd, y: cy))
        black.setStroke(); shaft.stroke()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: tipX, y: cy))
        head.line(to: NSPoint(x: baseX, y: cy + headH / 2))
        head.line(to: NSPoint(x: baseX, y: cy - headH / 2))
        head.close()
        black.setFill(); head.fill()
    }
    arrow(cy: yTop, toRight: true)
    arrow(cy: yBot, toRight: false)

    NSGraphicsContext.restoreGraphicsState()
    img.unlockFocus()
    return img
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let specs: [(Int, String)] = [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),
                              (128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),
                              (512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")]
for (px, name) in specs {
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("iconset 生成完成: \(outDir)")
