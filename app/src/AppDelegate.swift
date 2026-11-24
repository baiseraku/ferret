import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    var config = loadConfig()

    let serverListStack = NSStackView()
    let headerName = NSTextField(labelWithString: "")
    let headerSub = NSTextField(labelWithString: "")
    let statusPill = AdaptiveView()
    let statusDot = AdaptiveView()
    let statusLabel = NSTextField(labelWithString: "检查中…")
    let actionLabel = NSTextField(labelWithString: "")
    let logView = NSTextView()
    let reportView = NSTextView()
    let setupView = NSTextView()
    let segmented = NSSegmentedControl(labels: ["隧道与日志", "远端分流监测", "服务器初始化说明", "同步"],
                                       trackingMode: .selectOne, target: nil, action: nil)
    var tabBoxes: [NSView] = []
    var moreMenu: NSMenu?
    var lastOK = false
    var lastStatusDetail = ""
    var healthInFlight = false
    var compressionCheck: NSButton?
    var syncFields: [String: NSTextField] = [:]
    var syncMirrorCheck: NSButton?
    var skillsComparisonController: SkillsComparisonController?
    var contextField: NSTextField?
    var contextWindowField: NSTextField?
    var asyncCompactionCheck: NSButton?
    var statusTimer: Timer?
    var fields: [String: NSTextField] = [:]
    var busy = false
    var timer: Timer?
    var statusBar: StatusBarController?
    var trafficTimer: Timer?
    let trafficSampler = TunnelTrafficSampler()
    let trafficQueue = DispatchQueue(label: "local.ferret.traffic", qos: .utility)
    var trafficInFlight = false
    var logInFlight = false
    var trafficReadings: [String: TunnelTraffic] = [:]
    var tunnelHealth: [String: TunnelHealth] = [:]
    var healthRequests: [String: UUID] = [:]
    var isSleeping = false
    var trafficGeneration = 0
    var presentingWindow = false
    var hideDockWhenWindowHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "hideDockWhenWindowHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "hideDockWhenWindowHidden") }
    }
    var feedback: [String] = []   // 本次会话的操作反馈，统一显示到「隧道与日志」
    let sessionSince: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }()

    var current: SavedServer? {
        guard !config.servers.isEmpty else { return nil }
        let i = min(max(config.selected, 0), config.servers.count - 1)
        return config.servers[i]
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["hideDockWhenWindowHidden": true])
        NSApp.setActivationPolicy(.regular)
        // 便于验证两种外观（不设置时跟随系统）
        switch ProcessInfo.processInfo.environment["FERRET_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        buildMenu()
        buildUI()
        window.delegate = self
        window.title = "Ferret"
        window.isRestorable = false
        window.center()
        fitOnScreen()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // 系统恢复窗口位置可能发生在启动之后，延迟再兜底一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.fitOnScreen() }
        buildStatusBar()
        reloadServerUI()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshLog()
        }
        // 每 20 秒做一次深度健康检查（端口/网关/出口/封禁）
        let healthTimer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            guard let self = self, !self.busy, !self.healthInFlight, !self.isSleeping else { return }
            self.healthInFlight = true
            self.refreshStatus { self.healthInFlight = false }
        }
        RunLoop.main.add(healthTimer, forMode: .common)
        statusTimer = healthTimer
    }
    func fitOnScreen() {
        let w = window
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(w.frame) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = w.frame
        if f.maxX > vf.maxX - 20 { f.origin.x = vf.maxX - f.width - 20 }
        if f.minX < vf.minX + 20 { f.origin.x = vf.minX + 20 }
        if f.maxY > vf.maxY - 20 { f.origin.y = vf.maxY - f.height - 20 }
        if f.minY < vf.minY + 20 { f.origin.y = vf.minY + 20 }
        w.setFrame(f, display: true)
    }

    // 关闭窗口只是隐藏，不退出程序（退出用 ⌘Q 或菜单）
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // Dock 图标再次点击 / 重新 open 时把窗口显示回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onShowWindow()
        return true
    }
}
