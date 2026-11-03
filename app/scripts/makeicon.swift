import AppKit

// Apple 原生风格图标：圆角方形（squircle）+ 柔和渐变 + 内发光 + 极简白色字形 + 轻微投影

func squirclePath(in rect: NSRect, n: CGFloat = 5.0) -> NSBezierPath {
    // 用超椭圆近似 macOS 的 squircle
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

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    ctx.setShouldAntialias(true)
    let S = size

    // macOS 图标留白：内容约占 82%
    let inset = S * 0.09
    let bodyRect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let body = squirclePath(in: bodyRect)

    // 投影
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = S * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.07, green: 0.12, blue: 0.22, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 主体渐变（深海军蓝 → 蓝紫，苹果常用的低调双色）
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let top = NSColor(srgbRed: 0.24, green: 0.36, blue: 0.62, alpha: 1)
    let bottom = NSColor(srgbRed: 0.09, green: 0.14, blue: 0.28, alpha: 1)
    NSGradient(colors: [top, bottom])!.draw(in: bodyRect, angle: -90)

    // 顶部柔和径向高光（无硬边）
    let center = NSPoint(x: bodyRect.midX, y: bodyRect.maxY - bodyRect.height * 0.12)
    let radial = NSGradient(colorsAndLocations:
        (NSColor(white: 1, alpha: 0.22), 0.0),
        (NSColor(white: 1, alpha: 0.06), 0.45),
        (NSColor(white: 1, alpha: 0.0), 0.85))!
    radial.draw(fromCenter: center, radius: 0,
                toCenter: center, radius: bodyRect.width * 0.78,
                options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])

    // 内描边
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    body.lineWidth = S * 0.008
    NSColor(white: 1, alpha: 0.18).setStroke()
    body.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 字形：两条水平箭头（右去/左回），居中、留白充足
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let white = NSColor(white: 0.985, alpha: 1)
    let stroke = S * 0.050
    let x0 = S * 0.330, x1 = S * 0.670
    let headW = S * 0.078, headH = S * 0.076

    func arrowBody(cy: CGFloat, toRight: Bool) {
        let path = NSBezierPath()
        path.lineWidth = stroke
        path.lineCapStyle = .round
        let startX = toRight ? x0 : x1
        let endX = toRight ? x1 - stroke * 0.1 : x0 + stroke * 0.1
        path.move(to: NSPoint(x: startX, y: cy))
        path.line(to: NSPoint(x: endX, y: cy))
        white.setStroke(); path.stroke()

        let head = NSBezierPath()
        let tipX = endX + (toRight ? headW * 0.55 : -headW * 0.55)
        head.move(to: NSPoint(x: tipX, y: cy))
        head.line(to: NSPoint(x: tipX + (toRight ? -headW : headW), y: cy + headH))
        head.line(to: NSPoint(x: tipX + (toRight ? -headW : headW), y: cy - headH))
        head.close()
        white.setFill(); head.fill()
    }
    arrowBody(cy: S * 0.578, toRight: true)
    arrowBody(cy: S * 0.422, toRight: false)

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
