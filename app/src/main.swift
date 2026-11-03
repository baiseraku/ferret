import Cocoa

let ROOT = ProcessInfo.processInfo.environment["REMOTE_TUNNEL_ROOT"]
    ?? (NSHomeDirectory() + "/Documents/DSH/codex-remote")
let SSH_CONFIG = NSHomeDirectory() + "/.ssh/config"
let SUPPORT = NSHomeDirectory() + "/Library/Application Support/RemoteTunnel"
let CONFIG_FILE = SUPPORT + "/config.json"
let HISTORY_FILE = ROOT + "/log/history.log"

struct SavedServer: Codable {
    var name: String
    var sshHost: String
    var probeHost: String
    var remoteModelPort: Int = 3425
    var remoteProxyPort: Int = 58922
    var localMagpiePort: Int = 3425
    var localClashPort: Int = 7897
    var hostName: String = ""
    var port: Int = 22
    var userName: String = ""
    var identityFile: String = "~/.ssh/id_ed25519"
    var lastUsed: Double = 0
}

struct AppConfig: Codable {
    var servers: [SavedServer] = []
    var selected: Int = 0
}

struct LegacyConfig: Codable {
    var sshHost: String?
    var desktopHost: String?
    var remoteModelPort: Int?
    var remoteProxyPort: Int?
    var localMagpiePort: Int?
    var localClashPort: Int?
}

func shell(_ command: String, timeout: TimeInterval = 120) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-lc", command]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "启动失败: \(error)") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func sshConfigValues(_ host: String) -> (hostName: String, port: Int, user: String, identity: String)? {
    guard let text = try? String(contentsOfFile: SSH_CONFIG, encoding: .utf8) else { return nil }
    var h: String?; var p = 22; var u: String?; var id = "~/.ssh/id_ed25519"
    var inside = false
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") { continue }
        if line.hasPrefix("Host ") {
            let names = line.dropFirst(5).split(separator: " ").map(String.init)
            inside = names.contains(host)
            continue
        }
        guard inside else { continue }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        switch parts[0].lowercased() {
        case "hostname": h = parts[1]
        case "port": p = Int(parts[1]) ?? p
        case "user": u = parts[1]
        case "identityfile": id = parts[1]
        default: break
        }
    }
    guard let hn = h, let un = u else { return nil }
    return (hn, p, un, id)
}

func loadConfig() -> AppConfig {
    try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
    if let d = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_FILE)),
       var c = try? JSONDecoder().decode(AppConfig.self, from: d), !c.servers.isEmpty {
        for i in c.servers.indices where c.servers[i].hostName.isEmpty {
            if let v = sshConfigValues(c.servers[i].sshHost) {
                c.servers[i].hostName = v.hostName; c.servers[i].port = v.port
                c.servers[i].userName = v.user; c.servers[i].identityFile = v.identity
            }
        }
        return c
    }
    // 旧版单服务器配置迁移
    for old in [SUPPORT + "/config.json", NSHomeDirectory() + "/Library/Application Support/CodexTunnel/config.json"] {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: old)),
           let l = try? JSONDecoder().decode(LegacyConfig.self, from: d) {
            let s = SavedServer(name: "默认服务器", sshHost: l.sshHost ?? "my-tunnel", probeHost: l.desktopHost ?? "my-server",
                                remoteModelPort: l.remoteModelPort ?? 3425, remoteProxyPort: l.remoteProxyPort ?? 58922,
                                localMagpiePort: l.localMagpiePort ?? 3425, localClashPort: l.localClashPort ?? 7897)
            return AppConfig(servers: [s], selected: 0)
        }
    }
    return AppConfig(servers: [SavedServer(name: "默认服务器", sshHost: "my-tunnel", probeHost: "my-server")], selected: 0)
}

func saveConfig(_ c: AppConfig) {
    try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(c) { try? d.write(to: URL(fileURLWithPath: CONFIG_FILE)) }
}

func blockMarkers(_ host: String) -> (String, String) {
    ("# >>> remote-tunnel-app \(host)", "# <<< remote-tunnel-app \(host)")
}

func sshBlock(_ s: SavedServer) -> String {
    let (b, e) = blockMarkers(s.sshHost)
    return """
    \(b)
    Host \(s.sshHost)
      HostName \(s.hostName)
      Port \(s.port)
      User \(s.userName)
      IdentityFile \(s.identityFile)
      IdentitiesOnly yes
      PubkeyAuthentication yes
      PreferredAuthentications publickey,password
      RemoteForward 127.0.0.1:\(s.remoteModelPort) 127.0.0.1:\(s.localMagpiePort)
      RemoteForward 127.0.0.1:\(s.remoteProxyPort) 127.0.0.1:\(s.localClashPort)
      ControlMaster no
      ControlPath none
      ServerAliveInterval 15
      ServerAliveCountMax 3
    \(e)
    """
}

func writeSSHBlock(_ s: SavedServer) -> String {
    if s.hostName.isEmpty { return "请先填写「SSH 主机名」再保存（不会写占位符覆盖现有配置）" }
    if s.userName.isEmpty { return "请先填写「SSH 用户名」再保存" }
    guard var text = try? String(contentsOfFile: SSH_CONFIG, encoding: .utf8) else { return "读不到 \(SSH_CONFIG)" }
    let (b, e) = blockMarkers(s.sshHost)
    var lines = text.components(separatedBy: "\n")
    var kept: [String] = []
    var inBlock = false
    for line in lines {
        if line.contains(b) { inBlock = true; continue }
        if line.contains(e) { inBlock = false; continue }
        if !inBlock { kept.append(line) }
    }
    lines = kept
    kept = []
    var skipping = false
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Host ") {
            skipping = t.dropFirst(5).split(separator: " ").map(String.init).contains(s.sshHost)
        }
        if !skipping { kept.append(line) }
    }
    text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + sshBlock(s) + "\n"
    do { try text.write(toFile: SSH_CONFIG, atomically: true, encoding: .utf8); return "" }
    catch { return "写入失败: \(error)" }
}

func removeSSHBlock(_ host: String) {
    guard var text = try? String(contentsOfFile: SSH_CONFIG, encoding: .utf8) else { return }
    let (b, e) = blockMarkers(host)
    var kept: [String] = []
    var inBlock = false
    for line in text.components(separatedBy: "\n") {
        if line.contains(b) { inBlock = true; continue }
        if line.contains(e) { inBlock = false; continue }
        if !inBlock { kept.append(line) }
    }
    text = kept.joined(separator: "\n")
    try? text.write(toFile: SSH_CONFIG, atomically: true, encoding: .utf8)
}

func appendHistory(_ action: String, _ s: SavedServer) {
    try? FileManager.default.createDirectory(atPath: ROOT + "/log", withIntermediateDirectories: true)
    let line = String(format: "%@ | %@ | %@ (%@ → %@)\n", ISO8601DateFormatter().string(from: Date()), action, s.name, s.sshHost, s.probeHost)
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: HISTORY_FILE) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? line.write(toFile: HISTORY_FILE, atomically: true, encoding: .utf8) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    var config = loadConfig()

    let serverPopup = NSPopUpButton()
    let statusLabel = NSTextField(labelWithString: "状态：检查中…")
    let detailLabel = NSTextField(labelWithString: "")
    let actionLabel = NSTextField(labelWithString: "")
    let logView = NSTextView()
    let reportView = NSTextView()
    var fields: [String: NSTextField] = [:]
    var busy = false
    var timer: Timer?
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
        NSApp.setActivationPolicy(.regular)
        buildUI()
        window.title = "远程隧道"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        logView.string = "（本次会话日志从这里开始）\n"
        reloadServerUI()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshLog()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: UI
    func buildUI() {
        let content = NSView(); window.contentView = content
        window.contentMinSize = NSSize(width: 800, height: 640)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // 占满内容宽度的辅助函数：先加入 stack，再约束宽度（顺序很重要）
        func fullWidth(_ v: NSView) {
            v.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        func btn(_ t: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .rounded
            return b
        }

        let title = NSTextField(labelWithString: "远程隧道（常驻反向转发：模型网关 + 出网代理）")
        title.font = NSFont.boldSystemFont(ofSize: 15)
        stack.addArrangedSubview(title)

        let serverRow = NSStackView(); serverRow.orientation = .horizontal; serverRow.spacing = 8
        serverRow.addArrangedSubview(NSTextField(labelWithString: "服务器："))
        serverPopup.target = self; serverPopup.action = #selector(onServerChanged)
        serverPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        serverRow.addArrangedSubview(serverPopup)
        serverRow.addArrangedSubview(btn("＋ 添加", #selector(onAddServer)))
        serverRow.addArrangedSubview(btn("－ 删除", #selector(onRemoveServer)))
        stack.addArrangedSubview(serverRow)

        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(statusLabel)
        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(detailLabel)

        let ops = NSStackView(); ops.orientation = .horizontal; ops.spacing = 8
        for (t, sel) in [("启动", #selector(onStart)), ("停止", #selector(onStop)), ("重启", #selector(onRestart)),
                         ("修复连接", #selector(onHeal)), ("刷新状态", #selector(onRefresh)),
                         ("打开日志", #selector(onOpenLogs)), ("复制日志", #selector(onCopyLog)),
                         ("查看历史", #selector(onOpenHistory)), ("清空历史", #selector(onClearHistory))] {
            ops.addArrangedSubview(btn(t, sel))
        }
        stack.addArrangedSubview(ops)

        // 标签页
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        func tabContainer() -> (NSView, NSStackView) {
            let box = NSView()
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 8
            inner.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            inner.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.topAnchor.constraint(equalTo: box.topAnchor),
                inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            return (box, inner)
        }

        // Tab 1：配置 + 日志
        let tab1 = NSTabViewItem(identifier: "tunnel"); tab1.label = "隧道与日志"
        let (box1, inner1) = tabContainer()
        // 配置行：两列布局（减少高度，避免与日志区争空间）
        let cols = NSStackView(); cols.orientation = .horizontal; cols.spacing = 22; cols.alignment = .top
        let colA = NSStackView(); colA.orientation = .vertical; colA.spacing = 6; colA.alignment = .leading
        let colB = NSStackView(); colB.orientation = .vertical; colB.spacing = 6; colB.alignment = .leading
        var rowIndex = 0
        func addRow(_ label: String, _ key: String) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            let l = NSTextField(labelWithString: label); l.alignment = .left
            l.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let f = NSTextField(string: ""); f.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            f.widthAnchor.constraint(equalToConstant: 190).isActive = true
            fields[key] = f
            row.addArrangedSubview(l); row.addArrangedSubview(f)
            if rowIndex % 2 == 0 { colA.addArrangedSubview(row) } else { colB.addArrangedSubview(row) }
            rowIndex += 1
        }
        for (label, key) in [("显示名", "name"), ("SSH 隧道 Host", "sshHost"), ("探测 Host（桌面端）", "probeHost"),
                             ("SSH 主机名", "hostName"), ("SSH 端口", "port"), ("SSH 用户名", "userName"),
                             ("私钥路径", "identityFile"), ("远端模型端口", "remoteModelPort"),
                             ("远端代理端口", "remoteProxyPort"), ("本机 magpie 端口", "localMagpiePort"),
                             ("本机 Clash 端口", "localClashPort")] {
            addRow(label, key)
        }
        cols.addArrangedSubview(colA); cols.addArrangedSubview(colB)
        inner1.addArrangedSubview(cols)
        let cfgOps = NSStackView(); cfgOps.orientation = .horizontal; cfgOps.spacing = 8
        cfgOps.addArrangedSubview(btn("保存并重启", #selector(onSaveConfig)))
        cfgOps.addArrangedSubview(btn("只写 ssh config", #selector(onWriteSSHOnly)))
        inner1.addArrangedSubview(cfgOps)

        logView.isEditable = false; logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        inner1.addArrangedSubview(logScroll)
        let lw = logScroll.widthAnchor.constraint(equalTo: inner1.widthAnchor, constant: -20); lw.priority = .defaultHigh; lw.isActive = true
        let lh = logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110); lh.priority = .defaultHigh; lh.isActive = true
        tab1.view = box1
        tabs.addTabViewItem(tab1)

        // Tab 2：远端分流监测
        let tab2 = NSTabViewItem(identifier: "routing"); tab2.label = "远端分流监测"
        let (box2, inner2) = tabContainer()
        let repOps = NSStackView(); repOps.orientation = .horizontal; repOps.spacing = 8
        repOps.addArrangedSubview(btn("刷新分流报告", #selector(onRefreshReport)))
        repOps.addArrangedSubview(btn("复制报告", #selector(onCopyReport)))
        inner2.addArrangedSubview(repOps)
        reportView.isEditable = false; reportView.isSelectable = true
        reportView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        reportView.autoresizingMask = [.width]
        let repScroll = NSScrollView()
        repScroll.documentView = reportView
        repScroll.hasVerticalScroller = true
        repScroll.borderType = .bezelBorder
        repScroll.translatesAutoresizingMaskIntoConstraints = false
        inner2.addArrangedSubview(repScroll)
        let rw = repScroll.widthAnchor.constraint(equalTo: inner2.widthAnchor, constant: -20); rw.priority = .defaultHigh; rw.isActive = true
        let rh = repScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200); rh.priority = .defaultHigh; rh.isActive = true
        tab2.view = box2
        tabs.addTabViewItem(tab2)

        fullWidth(tabs)
        let th = tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 360); th.priority = .defaultHigh; th.isActive = true

        actionLabel.font = NSFont.systemFont(ofSize: 11)
        actionLabel.textColor = .secondaryLabelColor
        actionLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(actionLabel)
    }

    func reloadServerUI() {
        serverPopup.removeAllItems()
        for (i, s) in config.servers.enumerated() {
            let mark = s.lastUsed > 0 ? "  · \(Self.dateString(s.lastUsed))" : ""
            serverPopup.addItem(withTitle: "\(s.name) — \(s.sshHost)\(mark)")
            serverPopup.item(at: i)?.tag = i
        }
        if !config.servers.isEmpty {
            serverPopup.selectItem(at: min(max(config.selected, 0), config.servers.count - 1))
        }
        let s = current
        fields["name"]?.stringValue = s?.name ?? ""
        fields["sshHost"]?.stringValue = s?.sshHost ?? ""
        fields["probeHost"]?.stringValue = s?.probeHost ?? ""
        fields["hostName"]?.stringValue = s?.hostName ?? ""
        fields["port"]?.stringValue = "\(s?.port ?? 22)"
        fields["userName"]?.stringValue = s?.userName ?? ""
        fields["identityFile"]?.stringValue = s?.identityFile ?? ""
        fields["remoteModelPort"]?.stringValue = "\(s?.remoteModelPort ?? 3425)"
        fields["remoteProxyPort"]?.stringValue = "\(s?.remoteProxyPort ?? 58922)"
        fields["localMagpiePort"]?.stringValue = "\(s?.localMagpiePort ?? 3425)"
        fields["localClashPort"]?.stringValue = "\(s?.localClashPort ?? 7897)"
        refreshLog()
    }

    static func dateString(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    func touch(_ s: SavedServer, _ action: String) {
        if let i = config.servers.firstIndex(where: { $0.sshHost == s.sshHost }) {
            config.servers[i].lastUsed = Date().timeIntervalSince1970
            saveConfig(config)
        }
        appendHistory(action, s)
        reloadServerUI()
        serverPopup.selectItem(at: config.selected)
    }

    func run(_ desc: String, _ cmd: String, done: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        actionLabel.stringValue = "\(desc)…"
        DispatchQueue.global().async {
            let (_, out) = shell(cmd)
            DispatchQueue.main.async {
                self.actionLabel.stringValue = out.isEmpty ? "\(desc) 完成" : (out.split(separator: "\n").last.map(String.init) ?? "\(desc) 完成")
                self.busy = false
                done?()
            }
        }
    }

    func refreshLog() {
        let host = current?.sshHost ?? "my-tunnel"
        let cmd = "tail -n 300 '\(ROOT)/log/tunnel-resident-\(host).log' 2>/dev/null | awk -v s='\(sessionSince)' 'substr($0,1,19) >= s'"
        let (_, out) = shell(cmd, timeout: 6)
        logView.string = "（本次会话日志，\(sessionSince) 起；旧日志已隐藏）\n" + (out.isEmpty ? "（暂无新日志）" : out)
        logView.scrollToEndOfDocument(nil)
    }

    func refreshStatus() {
        guard let s = current, !busy else { return }
        busy = true
        statusLabel.stringValue = "状态：检查中…（\(s.name)）"
        let cmd = "cd \(ROOT) && ./scripts/resident.sh status \(s.sshHost)"
        DispatchQueue.global().async {
            let (rc, out) = shell(cmd, timeout: 60)
            var model = "?"
            for line in out.components(separatedBy: "\n") where line.contains("/v1/models") {
                if let v = line.split(separator: "=").last { model = v.trimmingCharacters(in: .whitespaces) }
            }
            DispatchQueue.main.async {
                let ok = rc == 0 && model == "200"
                self.statusLabel.stringValue = "\(s.name)：\(ok ? "正常" : "异常")（模型 \(model)）"
                self.detailLabel.stringValue = ok ? "常驻隧道在跑，远端转发与模型接口正常" : "点「修复连接」或查看日志"
                self.busy = false
            }
        }
    }

    func currentFromFields() -> SavedServer? {
        guard var s = current else { return nil }
        s.name = fields["name"]?.stringValue ?? s.name
        s.sshHost = fields["sshHost"]?.stringValue ?? s.sshHost
        s.probeHost = fields["probeHost"]?.stringValue ?? s.probeHost
        guard let m = Int(fields["remoteModelPort"]?.stringValue ?? ""), let p = Int(fields["remoteProxyPort"]?.stringValue ?? ""),
              let lm = Int(fields["localMagpiePort"]?.stringValue ?? ""), let lc = Int(fields["localClashPort"]?.stringValue ?? "") else {
            actionLabel.stringValue = "端口必须是数字"; return nil
        }
        s.remoteModelPort = m; s.remoteProxyPort = p; s.localMagpiePort = lm; s.localClashPort = lc
        s.hostName = fields["hostName"]?.stringValue ?? s.hostName
        s.userName = fields["userName"]?.stringValue ?? s.userName
        s.identityFile = fields["identityFile"]?.stringValue ?? s.identityFile
        s.port = Int(fields["port"]?.stringValue ?? "") ?? s.port
        return s
    }

    // MARK: actions
    @objc func onServerChanged() {
        config.selected = max(0, serverPopup.indexOfSelectedItem)
        saveConfig(config)
        logView.string = "（本次会话日志从这里开始）\n"
        reloadServerUI()
        refreshStatus()
        if let s = current { touch(s, "切换") }
    }

    @objc func onAddServer() {
        let alert = NSAlert(); alert.messageText = "添加 SSH 服务器"
        alert.informativeText = "填写显示名、隧道用 Host（会写入 RemoteForward 配置）和探测用 Host（桌面端连接用的别名）。"
        let accessory = NSStackView(); accessory.orientation = .vertical; accessory.spacing = 6
        func field(_ ph: String) -> NSTextField { let f = NSTextField(string: ""); f.placeholderString = ph; f.widthAnchor.constraint(equalToConstant: 260).isActive = true; accessory.addArrangedSubview(f); return f }
        let nameF = field("显示名，如：实验室服务器")
        let sshF = field("隧道 Host，如：lab-tunnel")
        let probeF = field("探测 Host，如：lab-key")
        alert.accessoryView = accessory
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameF.stringValue.isEmpty ? sshF.stringValue : nameF.stringValue
        guard !sshF.stringValue.isEmpty else { actionLabel.stringValue = "隧道 Host 不能为空"; return }
        let s = SavedServer(name: name, sshHost: sshF.stringValue, probeHost: probeF.stringValue.isEmpty ? sshF.stringValue : probeF.stringValue)
        config.servers.append(s); config.selected = config.servers.count - 1
        saveConfig(config)
        let err = writeSSHBlock(s)
        actionLabel.stringValue = err.isEmpty ? "已添加 \(s.name)；记得在服务器上装好 magpie/mihomo，再点启动" : err
        touch(s, "添加"); refreshStatus()
    }

    @objc func onRemoveServer() {
        guard let s = current else { return }
        let alert = NSAlert(); alert.messageText = "删除服务器 \(s.name)？"
        alert.informativeText = "会停止它的常驻隧道、删除对应 ssh config 段，并从列表移除。历史日志保留。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("删除服务器", "cd \(ROOT) && ./scripts/resident.sh stop \(s.sshHost); ./scripts/resident.sh uninstall \(s.sshHost)") {
            removeSSHBlock(s.sshHost)
            if let i = self.config.servers.firstIndex(where: { $0.sshHost == s.sshHost }) { self.config.servers.remove(at: i) }
            self.config.selected = max(0, min(self.config.selected, self.config.servers.count - 1))
            saveConfig(self.config)
            appendHistory("删除", s)
            self.reloadServerUI(); self.refreshStatus()
        }
    }

    @objc func onStart() { guard let s = current else { return }; touch(s, "启动"); run("启动隧道", "cd \(ROOT) && ./scripts/resident.sh start \(s.sshHost)") { self.refreshStatus() } }
    @objc func onStop() { guard let s = current else { return }; touch(s, "停止"); run("停止隧道", "cd \(ROOT) && ./scripts/resident.sh stop \(s.sshHost)") { self.refreshStatus() } }
    @objc func onRestart() { guard let s = current else { return }; touch(s, "重启"); run("重启隧道", "cd \(ROOT) && ./scripts/resident.sh stop \(s.sshHost); ./scripts/resident.sh start \(s.sshHost)") { self.refreshStatus() } }
    @objc func onHeal() { guard let s = current else { return }; touch(s, "修复"); run("修复连接", "cd \(ROOT) && ./scripts/heal.sh heal") { self.refreshStatus(); self.refreshLog() } }
    @objc func onRefresh() { refreshStatus(); refreshLog() }
    @objc func onCopyLog() {
        let text: String
        if let sel = logView.selectedRanges.first as? NSRange, sel.length > 0 {
            text = (logView.string as NSString).substring(with: sel)
        } else {
            text = logView.string
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actionLabel.stringValue = "日志已复制（\(text.count) 字符）"
    }

    @objc func onOpenLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: ROOT + "/log")) }
    @objc func onOpenHistory() {
        if !FileManager.default.fileExists(atPath: HISTORY_FILE) { try? "".write(toFile: HISTORY_FILE, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.open(URL(fileURLWithPath: HISTORY_FILE))
    }
    @objc func onClearHistory() {
        let alert = NSAlert(); alert.messageText = "清空连接历史？"; alert.addButton(withTitle: "清空"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? "".write(toFile: HISTORY_FILE, atomically: true, encoding: .utf8)
        actionLabel.stringValue = "历史已清空"
    }

    @objc func onWriteSSHOnly() {
        guard let s = currentFromFields() else { return }
        let err = writeSSHBlock(s)
        if err.isEmpty {
            if let i = config.servers.firstIndex(where: { $0.sshHost == s.sshHost }) { config.servers[i] = s } else { config.servers.append(s) }
            saveConfig(config); reloadServerUI(); actionLabel.stringValue = "已写入 ssh config（未重启）"
        } else { actionLabel.stringValue = err }
    }

    @objc func onSaveConfig() {
        guard let s = currentFromFields() else { return }
        let old = current
        let err = writeSSHBlock(s)
        if !err.isEmpty { actionLabel.stringValue = err; return }
        if let i = config.servers.firstIndex(where: { $0.sshHost == old?.sshHost ?? s.sshHost }) { config.servers[i] = s } else { config.servers.append(s) }
        saveConfig(config); reloadServerUI()
        touch(s, "保存配置")
        run("保存并重启", "cd \(ROOT) && ./scripts/resident.sh stop \(s.sshHost); ./scripts/resident.sh start \(s.sshHost)") { self.refreshStatus() }
    }

    @objc func onRefreshReport() {
        guard let s = current, !busy else { return }
        busy = true; reportView.string = "检测中…（\(s.name)）"
        let cmd = "cd \(ROOT) && ./scripts/routing-report.sh \(s.probeHost)"
        DispatchQueue.global().async {
            let (_, out) = shell(cmd, timeout: 150)
            DispatchQueue.main.async {
                self.reportView.string = out.isEmpty ? "（没有拿到报告：检查探测 Host 是否可登录）" : out
                self.busy = false
                self.appendHistory2("分流检测", s)
            }
        }
    }
    func appendHistory2(_ action: String, _ s: SavedServer) { appendHistory(action, s) }

    @objc func onCopyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportView.string, forType: .string)
        actionLabel.stringValue = "报告已复制到剪贴板"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
