import Cocoa

struct TunnelHealth {
    var ok: Bool?
    var text: String
    var checkedAt = Date()
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let summary = StatusSummaryView()
    private let dockOption = NSMenuItem(title: "随窗口隐藏 Dock 图标", action: #selector(toggleDock), keyEquivalent: "")
    var onLaunchChatGPT: (() -> Void)?
    var onShowWindow: (() -> Void)?
    var onToggleDock: (() -> Void)?
    var onMenuOpen: (() -> Void)?
    var hideDockWhenWindowHidden = true {
        didSet { dockOption.state = hideDockWhenWindowHidden ? .on : .off }
    }

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Ferret")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("Ferret")
        menu.autoenablesItems = false
        menu.delegate = self
        let information = NSMenuItem()
        information.view = summary
        menu.addItem(information)
        menu.addItem(.separator())
        let chatGPT = NSMenuItem(title: "启动 ChatGPT", action: #selector(launchChatGPT), keyEquivalent: "")
        chatGPT.target = self
        menu.addItem(chatGPT)
        let open = NSMenuItem(title: "打开 Ferret", action: #selector(showWindow), keyEquivalent: "0")
        open.target = self
        menu.addItem(open)
        dockOption.target = self
        dockOption.state = .on
        menu.addItem(dockOption)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Ferret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.toolTip = "退出界面和菜单栏；launchd 常驻隧道继续运行"
        menu.addItem(quit)
        item.menu = menu
        update(serverName: nil, health: nil, traffic: nil)
    }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = max(0, value)
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 { amount /= 1024; unit += 1 }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }

    func update(serverName: String?, health: TunnelHealth?, traffic: TunnelTraffic?) {
        summary.heading.stringValue = serverName.map { "Ferret · " + $0 } ?? "Ferret"
        var status = "检查连接中…"
        var ok: Bool?
        if serverName == nil {
            status = "未配置服务器"
        } else if let traffic = traffic, traffic.state == .stopped {
            status = "未连接 · 隧道未启动"
            ok = false
        } else if let traffic = traffic, traffic.state == .connecting {
            status = "连接中 · 等待 SSH 隧道"
        } else if let health = health, Date().timeIntervalSince(health.checkedAt) < 65 {
            status = health.text
            ok = health.ok
        } else if traffic?.state == .running {
            status = "SSH 运行中 · 等待网关检查"
        } else if traffic?.state == .unavailable {
            status = "连接状态暂不可用"
        }
        summary.connection.stringValue = "●  " + status
        summary.connection.textColor = ok.map { $0 ? Theme.menuGreen : Theme.menuOrange } ?? .textColor
        item.button?.toolTip = "Ferret · \(serverName ?? "未配置服务器")\n\(status)"
        summary.chart.samples = traffic?.samples ?? []
        let rate: (Double?) -> String = { $0.map { Self.bytes($0) + "/s" } ?? "—" }
        summary.upload.stringValue = "↑ 上传    " + rate(traffic?.uploadRate)
        summary.download.stringValue = "↓ 下载    " + rate(traffic?.downloadRate)
        summary.total.stringValue = "本次监控累计  ↑ \(Self.bytes(Double(traffic?.uploaded ?? 0)))  ↓ \(Self.bytes(Double(traffic?.downloaded ?? 0)))"
    }

    func showMenu() {
        DispatchQueue.main.async { [weak self] in self?.item.button?.performClick(nil) }
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuOpen?() }
    @objc private func launchChatGPT() { DispatchQueue.main.async { [weak self] in self?.onLaunchChatGPT?() } }
    @objc private func showWindow() { DispatchQueue.main.async { [weak self] in self?.onShowWindow?() } }
    @objc private func toggleDock() { DispatchQueue.main.async { [weak self] in self?.onToggleDock?() } }
}
