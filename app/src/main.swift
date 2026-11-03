import Cocoa

let ROOT = ProcessInfo.processInfo.environment["REMOTE_TUNNEL_ROOT"]
    ?? (NSHomeDirectory() + "/Documents/DSH/codex-remote")
let SSH_CONFIG = NSHomeDirectory() + "/.ssh/config"
let SUPPORT = NSHomeDirectory() + "/Library/Application Support/RemoteTunnel"
let CONFIG_FILE = SUPPORT + "/config.json"
let HISTORY_FILE = ROOT + "/log/history.log"
let CHATGPT_APP = "/Applications/ChatGPT.app"
let MAGPIE_APP = "/Applications/magpie.app"
let LOCAL_PROXY = "http://127.0.0.1:7897"
let LOCAL_PROXY_PORT = 7897
let LOCAL_MAGPIE_PORT = 3425

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

// 日志保留最近 N 天：更早的整文件删除，活跃文件里更早的行裁掉
func cleanupOldLogs(days: Int = 7) -> (removed: Int, trimmed: Int) {
    let fm = FileManager.default
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let cutoff = df.string(from: cutoffDate)

    func trimLines(_ path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var changed = false
        for line in lines {
            let prefix = String(line.prefix(10))
            if prefix.count == 10, prefix.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil {
                if prefix < cutoff { changed = true; continue }
            }
            kept.append(line)
        }
        if changed { try? kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        return changed ? 1 : 0
    }

    var removed = 0, trimmed = 0
    let logDir = ROOT + "/log"
    if let files = try? fm.contentsOfDirectory(atPath: logDir) {
        for name in files where name.hasSuffix(".log") || name.hasSuffix(".out") || name.hasSuffix(".err") {
            let path = logDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date, mtime < cutoffDate {
                try? fm.removeItem(atPath: path); removed += 1
            } else {
                trimmed += trimLines(path)
            }
        }
    }
    let launcherLog = NSHomeDirectory() + "/Library/Logs/CodexProxyLauncher.log"
    if let attrs = try? fm.attributesOfItem(atPath: launcherLog),
       let mtime = attrs[.modificationDate] as? Date, mtime < cutoffDate {
        try? fm.removeItem(atPath: launcherLog); removed += 1
    } else if fm.fileExists(atPath: launcherLog) {
        trimmed += trimLines(launcherLog)
    }
    return (removed, trimmed)
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

func appendRawHistory(_ action: String) {
    try? FileManager.default.createDirectory(atPath: ROOT + "/log", withIntermediateDirectories: true)
    let line = ISO8601DateFormatter().string(from: Date()) + " | " + action + "\n"
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: HISTORY_FILE) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? line.write(toFile: HISTORY_FILE, atomically: true, encoding: .utf8) }
    }
}

func appendHistory(_ action: String, _ s: SavedServer) {
    try? FileManager.default.createDirectory(atPath: ROOT + "/log", withIntermediateDirectories: true)
    let line = String(format: "%@ | %@ | %@ (%@ → %@)\n", ISO8601DateFormatter().string(from: Date()), action, s.name, s.sshHost, s.probeHost)
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: HISTORY_FILE) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? line.write(toFile: HISTORY_FILE, atomically: true, encoding: .utf8) }
    }
}

func serverSetupText(_ s: SavedServer) -> String {
    let tpl = #"""
    # 任务：把远程服务器配置成「模型与出网走本机隧道」的形态

    背景：本机已有 SSH 反向隧道，服务器上请把 127.0.0.1:%MODELPORT% 当模型网关、127.0.0.1:%PROXYPORT% 当出网代理入口。
    目标：服务器 codex 用网关取模型；ChatGPT/OpenAI 域名经本机代理；其余流量服务器直连。
    SSH 别名：%PROBE%    （登录命令：ssh %PROBE%）

    ## 步骤

    1. 确认可登录
       ssh %PROBE% 'echo ok'

    2. 确认 codex CLI
       ssh %PROBE% 'bash -lc "command -v codex && codex --version"'
       没有就安装；保证登录 shell 的 PATH 能找得到。

    3. 安装 mihomo（若未装）
       - 下载 linux-amd64 单文件到 ~/.local/bin/mihomo，chmod +x
       - 配置 ~/.config/mihomo/config.yaml：
         mixed-port: 7890
         proxies: [{ name: MAC, type: http, server: 127.0.0.1, port: %PROXYPORT% }]
         proxy-groups: [{ name: PROXY, type: select, proxies: [MAC] }]
         rules: openai.com、chatgpt.com、chatgpt.site、oaistatic.com、oaiusercontent.com、sora.com → PROXY；MATCH → DIRECT
       - systemd --user 服务：ExecStart=%h/.local/bin/mihomo -d %h/.config/mihomo，Restart=always，enable --now

    4. 写 ~/.codex/network.env（权限 600）并在 ~/.profile 里 source
       HTTP_PROXY=HTTPS_PROXY=ALL_PROXY=http://127.0.0.1:7890
       NO_PROXY=localhost,127.0.0.1,::1

    5. 改 ~/.codex/config.toml（先备份）
       model_provider = "magpie"
       model_catalog_json = "/home/<用户名>/.codex/magpie-models.json"
       [model_providers.magpie]
       base_url = "http://127.0.0.1:%MODELPORT%/v1"
       wire_api = "responses"
       experimental_bearer_token = "magpie"
       http_headers = { "x-openai-actor-authorization" = "magpie" }
       requires_openai_auth = false
       [mcp_servers.magpie]
       url = "http://127.0.0.1:3425/mcp/magpie/hub"
       删除其它逐条 [mcp_servers.*]。

    6. 服务器 sshd 开启保活（需要 root）
       ClientAliveInterval 15
       ClientAliveCountMax 3
       改后 systemctl reload ssh。

    7. 可选：把本机 ~/.config/magpie/library/skills 同步到服务器 ~/.codex/skills。

    ## 验收（全部满足才算完成）

    - bash -lc 'curl -s -o /dev/null -w "%{http_code}" --noproxy "*" http://127.0.0.1:%MODELPORT%/v1/models'  → 200
    - bash -lc 'curl -s -o /dev/null -w "%{http_code}" https://api.openai.com/v1/models'  → 401
    - bash -lc 'curl -s -o /dev/null -w "%{http_code}" https://github.com'  → 200
    - bash -lc 'echo $HTTPS_PROXY'  → http://127.0.0.1:7890
    - systemctl --user is-active mihomo  → active

    ## 约束

    - 不改本机；不额外开监听端口；不把密钥写进配置或日志。
    - 需要 sudo 密码时停下来告知用户，由用户输入。
    - 改 config.toml / network.env 前先备份。

    ## 回滚

    恢复 config.toml 与 network.env 的备份；systemctl --user disable --now mihomo。
    """#
    return tpl
        .replacingOccurrences(of: "%PROBE%", with: s.probeHost)
        .replacingOccurrences(of: "%MODELPORT%", with: "\(s.remoteModelPort)")
        .replacingOccurrences(of: "%PROXYPORT%", with: "\(s.remoteProxyPort)")
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
    let setupView = NSTextView()
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
        // 防止恢复成屏幕外的位置导致“看不到窗口”
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.setFrameOrigin(NSPoint(x: 120, y: 120))
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        logView.string = "（本次会话日志从这里开始）\n"
        DispatchQueue.global().async {
            let r = cleanupOldLogs()
            DispatchQueue.main.async {
                if r.removed > 0 || r.trimmed > 0 {
                    self.actionLabel.stringValue = "日志保留最近 7 天：删除 \(r.removed) 个旧文件，裁剪 \(r.trimmed) 个文件"
                }
            }
        }
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

        let codexRow = NSStackView(); codexRow.orientation = .horizontal; codexRow.spacing = 8
        codexRow.addArrangedSubview(NSTextField(labelWithString: "本机 ChatGPT 代理启动："))
        codexRow.addArrangedSubview(btn("启动 ChatGPT（走 Clash 代理）", #selector(onLaunchChatGPT)))
        stack.addArrangedSubview(codexRow)

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

        // Tab 3：服务器初始化说明（整段复制给 agent）
        let tab3 = NSTabViewItem(identifier: "setup"); tab3.label = "服务器初始化说明"
        let (box3, inner3) = tabContainer()
        let tip = NSTextField(labelWithString: "把下面整段复制给 agent 去配服务器；也可先点「检查服务器依赖」。")
        tip.lineBreakMode = .byTruncatingTail
        inner3.addArrangedSubview(tip)
        let setupOps = NSStackView(); setupOps.orientation = .horizontal; setupOps.spacing = 8
        setupOps.addArrangedSubview(btn("复制给 agent", #selector(onCopySetup)))
        setupOps.addArrangedSubview(btn("检查服务器依赖", #selector(onCheckServerDeps)))
        inner3.addArrangedSubview(setupOps)
        setupView.isEditable = false; setupView.isSelectable = true
        setupView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        setupView.autoresizingMask = [.width]
        let setupScroll = NSScrollView()
        setupScroll.documentView = setupView
        setupScroll.hasVerticalScroller = true
        setupScroll.borderType = .bezelBorder
        setupScroll.translatesAutoresizingMaskIntoConstraints = false
        inner3.addArrangedSubview(setupScroll)
        let sw = setupScroll.widthAnchor.constraint(equalTo: inner3.widthAnchor, constant: -20); sw.priority = .defaultHigh; sw.isActive = true
        let sh = setupScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240); sh.priority = .defaultHigh; sh.isActive = true
        tab3.view = box3
        tabs.addTabViewItem(tab3)

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
        setupView.string = s.map { serverSetupText($0) } ?? "（先添加一台服务器）"
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

    func run(_ desc: String, _ cmd: String, timeout: TimeInterval = 120, done: (() -> Void)? = nil) {
        guard !busy else { actionLabel.stringValue = "上一个操作还在进行，请稍候…"; return }
        busy = true
        actionLabel.stringValue = "\(desc)…"
        appendRawHistory("点击：\(desc)")
        DispatchQueue.global().async {
            let (_, out) = shell(cmd, timeout: timeout)
            DispatchQueue.main.async {
                self.busy = false
                self.actionLabel.stringValue = out.isEmpty ? "\(desc) 完成" : (out.split(separator: "\n").last.map(String.init) ?? "\(desc) 完成")
                done?()
            }
        }
    }

    func refreshLog() {
        let host = current?.sshHost ?? "my-tunnel"
        let cmd = "tail -n 400 '\(ROOT)/log/tunnel-resident-\(host).log' 2>/dev/null | awk -v s='\(sessionSince)' '{ ts=substr($0,1,19); if (ts ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) { keep = (ts >= s) } if (keep) print }'"
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
        DispatchQueue.global().async {
            let r = cleanupOldLogs()
            DispatchQueue.main.async {
                if r.removed > 0 || r.trimmed > 0 {
                    self.actionLabel.stringValue = "日志保留最近 7 天：删除 \(r.removed) 个旧文件，裁剪 \(r.trimmed) 个文件"
                }
            }
        }
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
    @objc func onHeal() {
        guard let s = current else { return }
        touch(s, "修复")
        run("修复连接（清理残留会话并重启隧道）",
            "cd \(ROOT) && ./scripts/heal.sh heal \(s.sshHost) \(s.probeHost)",
            timeout: 220) { self.refreshStatus(); self.refreshLog() }
    }
    @objc func onRefresh() { refreshStatus(); refreshLog() }
    // MARK: 整合「Codex 代理启动」：确保 Clash/magpie，并以 --proxy-server 启动 ChatGPT
    func portOpen(_ port: Int) -> Bool {
        shell("/usr/bin/nc -z -G 2 127.0.0.1 \(port)").0 == 0
    }

    func chatGPTPid() -> String {
        shell("/usr/bin/pgrep -f 'ChatGPT.app/Contents/MacOS/ChatGPT' | head -1").1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "好"); a.runModal()
    }

    func openChatGPT() -> String {
        var cmd = "/usr/bin/open"
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            cmd += " --env " + "'" + k + "=" + LOCAL_PROXY + "'"
        }
        for k in ["NO_PROXY", "no_proxy"] {
            cmd += " --env '" + k + "=localhost,127.0.0.1,::1'"
        }
        cmd += " --env 'NODE_USE_ENV_PROXY=1'"
        cmd += " -a '" + CHATGPT_APP + "'"
        cmd += " --args '--proxy-server=" + LOCAL_PROXY + "' '--proxy-bypass-list=localhost;127.0.0.1;[::1]'"
        let (rc, out) = shell(cmd, timeout: 30)
        return rc == 0 ? "" : out
    }

    @objc func onLaunchChatGPT() {
        appendRawHistory("点击：启动 ChatGPT（代理模式）")
        actionLabel.stringValue = "检查 Clash / magpie…"
        busy = true
        DispatchQueue.global().async {
            if !self.portOpen(LOCAL_PROXY_PORT) {
                DispatchQueue.main.async {
                    self.busy = false
                    self.showAlert("Clash 7897 未运行", "请先打开 Clash Verge，确认 127.0.0.1:7897 可用，再点此按钮。")
                }
                return
            }
            if !self.portOpen(LOCAL_MAGPIE_PORT) {
                _ = shell("/usr/bin/open -g -a '" + MAGPIE_APP + "'")
                var waited = 0.0
                while waited < 10.0 && !self.portOpen(LOCAL_MAGPIE_PORT) { usleep(300_000); waited += 0.3 }
                if !self.portOpen(LOCAL_MAGPIE_PORT) {
                    DispatchQueue.main.async {
                        self.busy = false
                        self.showAlert("magpie 3425 未就绪", "请先打开 magpie（Dock 或 /Applications/magpie.app），再重试。")
                    }
                    return
                }
            }
            let pid = self.chatGPTPid()
            var proxied = false
            if !pid.isEmpty {
                let ps = shell("/bin/ps -o command= -p \(pid)").1
                proxied = ps.contains("--proxy-server=" + LOCAL_PROXY)
            }
            DispatchQueue.main.async {
                if proxied {
                    _ = shell("/usr/bin/open -a '" + CHATGPT_APP + "'")
                    self.busy = false
                    self.actionLabel.stringValue = "ChatGPT 已在代理模式运行，已切到前台"
                    appendRawHistory("启动 ChatGPT（已在代理模式）")
                    return
                }
                if !pid.isEmpty {
                    self.actionLabel.stringValue = "正在退出 ChatGPT…"
                    _ = shell("/usr/bin/osascript -e 'tell application id \"com.openai.codex\" to quit'", timeout: 20)
                    var waited = 0.0
                    while waited < 15.0 && !self.chatGPTPid().isEmpty { sleep(1); waited += 1 }
                }
                let err = self.openChatGPT()
                self.busy = false
                if err.isEmpty {
                    self.actionLabel.stringValue = "已按代理模式启动 ChatGPT（Clash 7897 + magpie 3425）"
                    appendRawHistory("启动 ChatGPT（代理模式）")
                } else {
                    self.actionLabel.stringValue = "启动失败：\(err)"
                    self.showAlert("ChatGPT 启动失败", err)
                }
            }
        }
    }

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

    @objc func onCopySetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupView.string, forType: .string)
        actionLabel.stringValue = "服务器初始化说明已复制，可直接粘贴给 agent"
        appendRawHistory("复制服务器初始化说明")
    }

    @objc func onCheckServerDeps() {
        guard let s = current, !busy else { actionLabel.stringValue = "上一个操作还在进行，请稍候…"; return }
        busy = true
        actionLabel.stringValue = "检查服务器依赖…"
        let remote = #"""
        set -u
        echo "codex: $(bash -lc 'command -v codex 2>/dev/null || echo MISSING')"
        echo "mihomo: $(systemctl --user is-active mihomo 2>/dev/null || echo inactive)"
        echo "network.env HTTPS_PROXY: $(bash -lc 'echo ${HTTPS_PROXY:-EMPTY}')"
        echo "models: $(bash -lc 'curl -s -o /dev/null -m 6 -w "%{http_code}" --noproxy "*" http://127.0.0.1:%M%/v1/models' 2>/dev/null)"
        echo "openai: $(bash -lc 'curl -s -o /dev/null -m 10 -w "%{http_code}" https://api.openai.com/v1/models' 2>/dev/null)"
        echo "github: $(bash -lc 'curl -s -o /dev/null -m 8 -w "%{http_code}" https://github.com' 2>/dev/null)"
        echo "base_url: $(grep -m1 'base_url' ~/.codex/config.toml 2>/dev/null || echo MISSING)"
        echo "sshd keepalive: $(grep -E '^\s*ClientAliveInterval' /etc/ssh/sshd_config 2>/dev/null | head -1 || echo '未设置（需 root）')"
        """#
            .replacingOccurrences(of: "%M%", with: "\(s.remoteModelPort)")
        let quoted = "'" + remote.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none \(s.probeHost) \(quoted)"
        DispatchQueue.global().async {
            let (_, out) = shell(cmd, timeout: 90)
            DispatchQueue.main.async {
                self.busy = false
                self.setupView.string = serverSetupText(s) + "\n\n==== 服务器依赖检查 ====\n" + (out.isEmpty ? "（检查失败：确认探测 Host 可登录）" : out)
                self.actionLabel.stringValue = "依赖检查完成"
                appendRawHistory("检查服务器依赖")
            }
        }
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
