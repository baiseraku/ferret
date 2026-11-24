import Cocoa

// MARK: - 外观（参考 ChatGPT 桌面端）
enum Theme {
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let accent = NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)      // #10A37F
    static let accentSoft = adaptive(NSColor(srgbRed: 0.902, green: 0.965, blue: 0.945, alpha: 1),
                                     NSColor(srgbRed: 0.114, green: 0.282, blue: 0.239, alpha: 1))
    static let windowBG = adaptive(NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
                                   NSColor(srgbRed: 0.106, green: 0.106, blue: 0.106, alpha: 1))
    static let sidebarBG = adaptive(NSColor(srgbRed: 0.973, green: 0.973, blue: 0.976, alpha: 1),
                                    NSColor(srgbRed: 0.145, green: 0.145, blue: 0.149, alpha: 1))
    static let cardBG = adaptive(NSColor(srgbRed: 0.973, green: 0.976, blue: 0.980, alpha: 1),
                                 NSColor(srgbRed: 0.176, green: 0.176, blue: 0.184, alpha: 1))
    static let hover = adaptive(NSColor(srgbRed: 0.937, green: 0.941, blue: 0.945, alpha: 1),
                                NSColor(srgbRed: 0.220, green: 0.220, blue: 0.227, alpha: 1))
    static let fieldBG = adaptive(NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),
                                  NSColor(srgbRed: 0.243, green: 0.243, blue: 0.251, alpha: 1))
    static let border = adaptive(NSColor(srgbRed: 0.898, green: 0.898, blue: 0.906, alpha: 1),
                                 NSColor(srgbRed: 0.282, green: 0.282, blue: 0.290, alpha: 1))
    static let bad = NSColor(srgbRed: 0.878, green: 0.286, blue: 0.243, alpha: 1)
    // 菜单的小字号彩色文字：浅色外观加深，深色外观提亮。
    static let menuGreen = adaptive(NSColor(srgbRed: 24 / 255, green: 92 / 255, blue: 54 / 255, alpha: 1),
                                    NSColor(srgbRed: 126 / 255, green: 219 / 255, blue: 160 / 255, alpha: 1))
    static let menuOrange = adaptive(NSColor(srgbRed: 137 / 255, green: 64 / 255, blue: 0, alpha: 1),
                                     NSColor(srgbRed: 1, green: 187 / 255, blue: 120 / 255, alpha: 1))
    static let menuBlue = adaptive(NSColor(srgbRed: 24 / 255, green: 79 / 255, blue: 145 / 255, alpha: 1),
                                   NSColor(srgbRed: 130 / 255, green: 187 / 255, blue: 1, alpha: 1))
    static let rowSelected = adaptive(NSColor(srgbRed: 0.918, green: 0.918, blue: 0.925, alpha: 1),
                                      NSColor(srgbRed: 0.216, green: 0.216, blue: 0.227, alpha: 1))
}
