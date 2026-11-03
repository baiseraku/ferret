import Cocoa

let ROOT = ProcessInfo.processInfo.environment["FERRET_ROOT"]
    ?? (NSHomeDirectory() + "/Documents/DSH/ferret")
let SSH_CONFIG = NSHomeDirectory() + "/.ssh/config"
let SUPPORT = NSHomeDirectory() + "/Library/Application Support/Ferret"
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
    ("# >>> ferret-app \(host)", "# <<< ferret-app \(host)")
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
       url = "http://127.0.0.1:%MODELPORT%/mcp/magpie/hub"
       删除其它逐条 [mcp_servers.*]。

       说明：这里的网关与 MCP 共用「远端模型端口」%MODELPORT%（本机端口映射来自隧道 RemoteForward）。
       若在软件里改了这个端口，base_url 与 MCP hub URL 两处都要改成同一个值。

    6. 服务器 sshd 开启保活（需要 root）
       ClientAliveInterval 15
       ClientAliveCountMax 3
       改后 systemctl reload ssh。

    7. 先询问用户，再决定是否同步这两项（用户不确认就跳过，并在总结里说明未同步）
       - skills：本机 ~/.config/magpie/library/skills → 服务器 ~/.codex/skills（保留服务器已有 .system）
       - 模型列表：本机 ~/.codex/magpie-models.json → 服务器 ~/.codex/magpie-models.json
         并确认 config.toml 的 model_catalog_json 指向该文件
       同步后用 ls 数量核对；不同步不影响前 6 步的验收。

    ## 验收（全部满足才算完成）

    - bash -lc 'curl -s -o /dev/null -w "%{http_code}" --noproxy "*" http://127.0.0.1:%MODELPORT%/v1/models'  → 200
    - bash -lc 'curl -s -o /dev/null -w "%{http_code}" https://api.openai.com/v1/models'  → 401
    - bash -lc 'curl -s -o /dev/null -w "%{http_code}" https://github.com'  → 200
    - bash -lc 'echo $HTTPS_PROXY'  → http://127.0.0.1:7890
    - bash -lc 'curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:%MODELPORT%/mcp/magpie/hub -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"'  → 200
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
    static let rowSelected = adaptive(NSColor(srgbRed: 0.918, green: 0.918, blue: 0.925, alpha: 1),
                                      NSColor(srgbRed: 0.216, green: 0.216, blue: 0.227, alpha: 1))
}


// MARK: - 自适应外观组件（切换深浅色时自动重设 CALayer 颜色）
class AdaptiveView: NSView {
    var fillColor: NSColor = .clear { didSet { applyColors() } }
    var strokeColor: NSColor = .clear { didSet { applyColors() } }
    var radius: CGFloat = 0 { didSet { layer?.cornerRadius = radius } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func applyColors() {
        guard let layer = layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = self.fillColor.cgColor
            layer.borderColor = self.strokeColor.cgColor
            layer.borderWidth = self.strokeColor == .clear ? 0 : 1
            layer.cornerRadius = self.radius
        }
    }
}

final class PillButton: NSButton {
    var fill: NSColor = Theme.hover
    var labelColor: NSColor = .labelColor
    var fontForTitle: NSFont = .systemFont(ofSize: 12, weight: .medium)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
    func applyStyle() {
        wantsLayer = true
        layer?.cornerRadius = 7
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: fontForTitle,
                .foregroundColor: labelColor,
            ])
        }
    }
}

final class BorderedScrollView: NSScrollView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        wantsLayer = true
        layer?.cornerRadius = 8
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = 1
            layer?.borderColor = Theme.border.cgColor
        }
    }
}

final class CardView: AdaptiveView {
    init(fill: NSColor = Theme.cardBG, radius: CGFloat = 10, bordered: Bool = true) {
        super.init(frame: .zero)
        self.fillColor = fill
        self.radius = radius
        self.strokeColor = bordered ? Theme.border : .clear
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ServerRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    var onSelect: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        subLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        for v in [dot, nameLabel, subLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var selectedState = false
    private var healthyState = false

    func configure(name: String, sub: String, selected: Bool, healthy: Bool) {
        nameLabel.stringValue = name
        subLabel.stringValue = sub
        selectedState = selected
        healthyState = healthy
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        wantsLayer = true
        layer?.cornerRadius = 8
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selectedState ? Theme.rowSelected : NSColor.clear).cgColor
            dot.layer?.backgroundColor = (healthyState ? Theme.accent : NSColor.tertiaryLabelColor).cgColor
        }
    }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
    let segmented = NSSegmentedControl(labels: ["隧道与日志", "远端分流监测", "服务器初始化说明"],
                                       trackingMode: .selectOne, target: nil, action: nil)
    var tabBoxes: [NSView] = []
    var lastOK = false
    var fields: [String: NSTextField] = [:]
    var busy = false
    var timer: Timer?
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

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示窗口", action: #selector(onShowWindow), keyEquivalent: "0")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 Ferret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc func onShowWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)   // 只隐藏窗口，进程继续跑（常驻隧道不受影响）
        return false
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        reloadServerUI()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshLog()
        }
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
        if !flag {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    // MARK: UI
    // MARK: 样式辅助
    func pill(_ title: String, _ sel: Selector, primary: Bool = false, height: CGFloat = 28) -> NSButton {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 24
        let b = PillButton(title: title, target: self, action: sel)
        b.isBordered = false
        b.focusRingType = .none
        b.fontForTitle = font
        b.fill = primary ? Theme.accent : Theme.hover
        b.labelColor = primary ? NSColor.white : NSColor.labelColor
        b.applyStyle()
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.heightAnchor.constraint(equalToConstant: height),
            b.widthAnchor.constraint(equalToConstant: w),
        ])
        return b
    }

    func makeField(_ key: String) -> NSView {
        let f = NSTextField(string: "")
        f.font = .systemFont(ofSize: 12)
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.cell?.usesSingleLineMode = true
        f.cell?.wraps = false
        f.translatesAutoresizingMaskIntoConstraints = false
        fields[key] = f

        let box = AdaptiveView()
        box.fillColor = Theme.fieldBG
        box.radius = 6
        box.applyColors()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(f)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 26),
            f.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            f.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
            f.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        let bw = box.widthAnchor.constraint(equalToConstant: 190)
        bw.priority = .defaultHigh
        bw.isActive = true
        return box
    }

    func makeTextView(_ tv: NSTextView) -> NSScrollView {
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.autoresizingMask = [.width]
        tv.drawsBackground = true
        tv.backgroundColor = Theme.windowBG
        let sc = BorderedScrollView()
        sc.documentView = tv
        sc.hasVerticalScroller = true
        sc.borderType = .noBorder
        sc.drawsBackground = false
        sc.translatesAutoresizingMaskIntoConstraints = false
        return sc
    }

    func buildUI() {
        let content = AdaptiveView()
        content.fillColor = Theme.windowBG
        content.applyColors()
        window.contentView = content
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1000, height: 700))

        // ---------- 左侧边栏 ----------
        let sidebar = AdaptiveView()
        sidebar.fillColor = Theme.sidebarBG
        sidebar.applyColors()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        let appTitle = NSTextField(labelWithString: "Ferret")
        appTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let appSub = NSTextField(labelWithString: "远程隧道")
        appSub.font = .systemFont(ofSize: 11)
        appSub.textColor = .secondaryLabelColor
        let headStack = NSStackView(views: [appTitle, appSub])
        headStack.orientation = .vertical
        headStack.alignment = .leading
        headStack.spacing = 1
        headStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(headStack)

        let sectionLabel = NSTextField(labelWithString: "服务器")
        sectionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sectionLabel.textColor = .secondaryLabelColor
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sectionLabel)

        serverListStack.orientation = .vertical
        serverListStack.alignment = .leading
        serverListStack.spacing = 4
        serverListStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(serverListStack)

        let addServerBtn = pill("＋ 添加服务器", #selector(onAddServer), height: 30)
        let delServerBtn = pill("删除当前服务器", #selector(onRemoveServer), height: 30)
        let sideBtns = NSStackView(views: [addServerBtn, delServerBtn])
        sideBtns.orientation = .vertical
        sideBtns.alignment = .leading
        sideBtns.spacing = 6
        sideBtns.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sideBtns)

        // ---------- 右侧主区 ----------
        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(main)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 236),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            main.topAnchor.constraint(equalTo: content.topAnchor),
            main.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            headStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            headStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            sectionLabel.topAnchor.constraint(equalTo: headStack.bottomAnchor, constant: 20),
            sectionLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            serverListStack.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 6),
            serverListStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            serverListStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            sideBtns.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sideBtns.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -14),
        ])

        // 顶部标题
        headerName.font = .systemFont(ofSize: 20, weight: .semibold)
        headerName.lineBreakMode = .byTruncatingTail
        headerSub.font = .systemFont(ofSize: 11)
        headerSub.textColor = .secondaryLabelColor
        headerSub.lineBreakMode = .byTruncatingTail
        let headerStack = NSStackView(views: [headerName, headerSub])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(headerStack)

        // 状态胶囊
        (statusPill as? AdaptiveView)?.fillColor = Theme.hover
        (statusPill as? AdaptiveView)?.radius = 12
        (statusPill as? AdaptiveView)?.applyColors()
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(statusPill)
        (statusDot as? AdaptiveView)?.fillColor = NSColor.tertiaryLabelColor
        (statusDot as? AdaptiveView)?.radius = 3.5
        (statusDot as? AdaptiveView)?.applyColors()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusDot)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusPill.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            statusPill.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),
            statusPill.heightAnchor.constraint(equalToConstant: 24),
            statusDot.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 10),
            statusDot.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
        ])

        // 操作按钮
        let actions = NSStackView(views: [
            pill("启动", #selector(onStart), primary: true),
            pill("停止", #selector(onStop)),
            pill("重启", #selector(onRestart)),
            pill("修复连接", #selector(onHeal)),
            pill("刷新状态", #selector(onRefresh)),
            pill("复制日志", #selector(onCopyLog)),
        ])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(actions)

        // ChatGPT 代理卡片
        let chatCard = CardView(fill: Theme.cardBG, radius: 10)
        chatCard.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(chatCard)
        let chatTitle = NSTextField(labelWithString: "ChatGPT 桌面端代理")
        chatTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let chatSub = NSTextField(labelWithString: "以 Clash 7897 为代理启动 ChatGPT；模型请求走本机 magpie 3425")
        chatSub.font = .systemFont(ofSize: 11)
        chatSub.textColor = .secondaryLabelColor
        let chatText = NSStackView(views: [chatTitle, chatSub])
        chatText.orientation = .vertical
        chatText.alignment = .leading
        chatText.spacing = 2
        chatText.translatesAutoresizingMaskIntoConstraints = false
        chatCard.addSubview(chatText)
        let chatBtn = pill("启动 ChatGPT", #selector(onLaunchChatGPT), primary: true, height: 30)
        chatCard.addSubview(chatBtn)
        NSLayoutConstraint.activate([
            chatCard.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 16),
            chatCard.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            chatCard.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            chatText.leadingAnchor.constraint(equalTo: chatCard.leadingAnchor, constant: 14),
            chatText.centerYAnchor.constraint(equalTo: chatCard.centerYAnchor),
            chatBtn.trailingAnchor.constraint(equalTo: chatCard.trailingAnchor, constant: -12),
            chatBtn.centerYAnchor.constraint(equalTo: chatCard.centerYAnchor),
            chatBtn.leadingAnchor.constraint(greaterThanOrEqualTo: chatText.trailingAnchor, constant: 12),
            chatCard.heightAnchor.constraint(equalToConstant: 62),
        ])

        // 分段控件
        segmented.target = self
        segmented.action = #selector(onSegmentChanged)
        segmented.segmentStyle = .rounded
        segmented.selectedSegment = 0
        segmented.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(segmented)

        // 内容容器
        let host = CardView(fill: Theme.cardBG, radius: 10)
        host.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(host)

        // Tab 1：配置 + 日志
        let box1 = NSView(); box1.translatesAutoresizingMaskIntoConstraints = false
        let configCard = CardView(fill: Theme.windowBG, radius: 8)
        configCard.translatesAutoresizingMaskIntoConstraints = false
        box1.addSubview(configCard)
        let colA = NSStackView(); colA.orientation = .vertical; colA.alignment = .leading; colA.spacing = 8
        let colB = NSStackView(); colB.orientation = .vertical; colB.alignment = .leading; colB.spacing = 8
        var rowIndex = 0
        func addRow(_ label: String, _ key: String) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            row.alignment = .centerY
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let f = makeField(key)
            row.addArrangedSubview(l)
            row.addArrangedSubview(f)
            l.centerYAnchor.constraint(equalTo: f.centerYAnchor).isActive = true
            if rowIndex % 2 == 0 { colA.addArrangedSubview(row) } else { colB.addArrangedSubview(row) }
            rowIndex += 1
        }
        for (label, key) in [("显示名", "name"), ("SSH 隧道 Host", "sshHost"), ("探测 Host", "probeHost"),
                             ("SSH 主机名", "hostName"), ("SSH 端口", "port"), ("SSH 用户名", "userName"),
                             ("私钥路径", "identityFile")] {
            addRow(label, key)
        }
        // 端口映射区：每行“远端 → 本机”，与 RemoteForward 一一对应
        let mapTitle = NSTextField(labelWithString: "端口映射（远端 → 本机）")
        mapTitle.font = .systemFont(ofSize: 11, weight: .medium)
        mapTitle.textColor = .secondaryLabelColor
        let mapStack = NSStackView()
        mapStack.orientation = .vertical
        mapStack.alignment = .leading
        mapStack.spacing = 8
        func mapRow(_ leftLabel: String, _ leftKey: String, _ rightLabel: String, _ rightKey: String) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            row.alignment = .centerY
            let ll = NSTextField(labelWithString: leftLabel)
            ll.font = .systemFont(ofSize: 11); ll.textColor = .secondaryLabelColor
            ll.translatesAutoresizingMaskIntoConstraints = false
            ll.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let lf = makeField(leftKey)
            let arrow = NSTextField(labelWithString: "→")
            arrow.font = .systemFont(ofSize: 13, weight: .semibold)
            arrow.textColor = Theme.accent
            let rl = NSTextField(labelWithString: rightLabel)
            rl.font = .systemFont(ofSize: 11); rl.textColor = .secondaryLabelColor
            rl.translatesAutoresizingMaskIntoConstraints = false
            rl.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let rf = makeField(rightKey)
            row.addArrangedSubview(ll); row.addArrangedSubview(lf)
            row.addArrangedSubview(arrow)
            row.addArrangedSubview(rl); row.addArrangedSubview(rf)
            ll.centerYAnchor.constraint(equalTo: lf.centerYAnchor).isActive = true
            rl.centerYAnchor.constraint(equalTo: rf.centerYAnchor).isActive = true
            arrow.centerYAnchor.constraint(equalTo: lf.centerYAnchor).isActive = true
            mapStack.addArrangedSubview(row)
        }
        mapRow("远端模型端口", "remoteModelPort", "本机 magpie 端口", "localMagpiePort")
        mapRow("远端代理端口", "remoteProxyPort", "本机 Clash 端口", "localClashPort")

        let cfgOps = NSStackView(views: [
            pill("保存并重启", #selector(onSaveConfig), primary: true, height: 26),
            pill("只写 ssh config", #selector(onWriteSSHOnly), height: 26),
        ])
        cfgOps.orientation = .horizontal
        cfgOps.spacing = 8
        colsBox: do {
            let cols = NSStackView(views: [colA, colB])
            cols.orientation = .horizontal
            cols.spacing = 24
            cols.alignment = .top
            cols.translatesAutoresizingMaskIntoConstraints = false
            configCard.addSubview(cols)
            cols.leadingAnchor.constraint(equalTo: configCard.leadingAnchor, constant: 14).isActive = true
            cols.trailingAnchor.constraint(equalTo: configCard.trailingAnchor, constant: -14).isActive = true
            cols.topAnchor.constraint(equalTo: configCard.topAnchor, constant: 14).isActive = true
            colA.widthAnchor.constraint(equalTo: colB.widthAnchor).isActive = true

            let mapAll = NSStackView(views: [mapTitle, mapStack])
            mapAll.orientation = .vertical
            mapAll.alignment = .leading
            mapAll.spacing = 6
            mapAll.translatesAutoresizingMaskIntoConstraints = false
            configCard.addSubview(mapAll)
            mapAll.leadingAnchor.constraint(equalTo: configCard.leadingAnchor, constant: 14).isActive = true
            mapAll.topAnchor.constraint(equalTo: cols.bottomAnchor, constant: 12).isActive = true

            cfgOps.translatesAutoresizingMaskIntoConstraints = false
            configCard.addSubview(cfgOps)
            cfgOps.leadingAnchor.constraint(equalTo: configCard.leadingAnchor, constant: 14).isActive = true
            cfgOps.topAnchor.constraint(equalTo: mapAll.bottomAnchor, constant: 12).isActive = true
            cfgOps.bottomAnchor.constraint(equalTo: configCard.bottomAnchor, constant: -14).isActive = true
        }
        NSLayoutConstraint.activate([
            configCard.topAnchor.constraint(equalTo: box1.topAnchor),
            configCard.leadingAnchor.constraint(equalTo: box1.leadingAnchor),
            configCard.trailingAnchor.constraint(equalTo: box1.trailingAnchor),
        ])
        let logScroll = makeTextView(logView)
        box1.addSubview(logScroll)
        NSLayoutConstraint.activate([
            logScroll.topAnchor.constraint(equalTo: configCard.bottomAnchor, constant: 10),
            logScroll.leadingAnchor.constraint(equalTo: box1.leadingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: box1.trailingAnchor),
            logScroll.bottomAnchor.constraint(equalTo: box1.bottomAnchor),
        ])

        // Tab 2：分流监测
        let box2 = NSView(); box2.translatesAutoresizingMaskIntoConstraints = false
        let repOps = NSStackView(views: [
            pill("刷新分流报告", #selector(onRefreshReport), primary: true, height: 26),
            pill("复制报告", #selector(onCopyReport), height: 26),
        ])
        repOps.orientation = .horizontal
        repOps.spacing = 8
        repOps.translatesAutoresizingMaskIntoConstraints = false
        box2.addSubview(repOps)
        let repScroll = makeTextView(reportView)
        box2.addSubview(repScroll)
        NSLayoutConstraint.activate([
            repOps.topAnchor.constraint(equalTo: box2.topAnchor),
            repOps.leadingAnchor.constraint(equalTo: box2.leadingAnchor),
            repScroll.topAnchor.constraint(equalTo: repOps.bottomAnchor, constant: 10),
            repScroll.leadingAnchor.constraint(equalTo: box2.leadingAnchor),
            repScroll.trailingAnchor.constraint(equalTo: box2.trailingAnchor),
            repScroll.bottomAnchor.constraint(equalTo: box2.bottomAnchor),
        ])

        // Tab 3：初始化说明
        let box3 = NSView(); box3.translatesAutoresizingMaskIntoConstraints = false
        let tip = NSTextField(labelWithString: "把下面整段复制给 agent 去配服务器；也可先检查服务器依赖。")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.translatesAutoresizingMaskIntoConstraints = false
        box3.addSubview(tip)
        let setupOps = NSStackView(views: [
            pill("复制给 agent", #selector(onCopySetup), primary: true, height: 26),
            pill("检查服务器依赖", #selector(onCheckServerDeps), height: 26),
        ])
        setupOps.orientation = .horizontal
        setupOps.spacing = 8
        setupOps.translatesAutoresizingMaskIntoConstraints = false
        box3.addSubview(setupOps)
        let setupScroll = makeTextView(setupView)
        box3.addSubview(setupScroll)
        NSLayoutConstraint.activate([
            tip.topAnchor.constraint(equalTo: box3.topAnchor),
            tip.leadingAnchor.constraint(equalTo: box3.leadingAnchor),
            setupOps.topAnchor.constraint(equalTo: tip.bottomAnchor, constant: 8),
            setupOps.leadingAnchor.constraint(equalTo: box3.leadingAnchor),
            setupScroll.topAnchor.constraint(equalTo: setupOps.bottomAnchor, constant: 10),
            setupScroll.leadingAnchor.constraint(equalTo: box3.leadingAnchor),
            setupScroll.trailingAnchor.constraint(equalTo: box3.trailingAnchor),
            setupScroll.bottomAnchor.constraint(equalTo: box3.bottomAnchor),
        ])

        tabBoxes = [box1, box2, box3]
        for b in tabBoxes {
            b.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(b)
            NSLayoutConstraint.activate([
                b.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
                b.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                b.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
                b.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
            ])
            b.isHidden = true
        }
        box1.isHidden = false

        actionLabel.font = .systemFont(ofSize: 11)
        actionLabel.textColor = .secondaryLabelColor
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(actionLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: main.topAnchor, constant: 22),
            headerStack.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: statusPill.leadingAnchor, constant: -12),
            actions.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 16),
            actions.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            segmented.topAnchor.constraint(equalTo: chatCard.bottomAnchor, constant: 16),
            segmented.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            host.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),
            host.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            host.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            host.bottomAnchor.constraint(equalTo: actionLabel.topAnchor, constant: -10),
            actionLabel.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            actionLabel.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            actionLabel.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -14),
        ])
    }

    @objc func onSegmentChanged() {
        let idx = max(0, min(segmented.selectedSegment, tabBoxes.count - 1))
        for (i, b) in tabBoxes.enumerated() { b.isHidden = (i != idx) }
    }

    func reloadServerUI() {
        // 左侧服务器列表
        for v in serverListStack.arrangedSubviews { v.removeFromSuperview() }
        for (i, srv) in config.servers.enumerated() {
            let row = ServerRowView()
            row.configure(name: srv.name, sub: srv.sshHost,
                          selected: i == config.selected,
                          healthy: i == config.selected && lastOK)
            row.onSelect = { [weak self] in self?.selectServer(i) }
            serverListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: serverListStack.widthAnchor).isActive = true
        }

        let s = current
        headerName.stringValue = s?.name ?? "未选择服务器"
        headerSub.stringValue = s.map { "\($0.sshHost)  ·  \($0.hostName.isEmpty ? "未填主机名" : $0.hostName)" } ?? ""

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

    func selectServer(_ index: Int) {
        guard index >= 0, index < config.servers.count else { return }
        config.selected = index
        saveConfig(config)
        lastOK = false
        reloadServerUI()
        refreshStatus()
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
                self.appendFeedback(out.isEmpty ? "\(desc) 完成" : out, title: desc)
                self.actionLabel.stringValue = out.isEmpty ? "\(desc) 完成" : (out.split(separator: "\n").last.map(String.init) ?? "\(desc) 完成")
                done?()
            }
        }
    }

    func appendFeedback(_ text: String, title: String? = nil) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let stamp = f.string(from: Date())
        if let t = title { feedback.append("[\(stamp)] —— \(t) ——") }
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            feedback.append("[\(stamp)] " + line)
        }
        if feedback.count > 300 { feedback.removeFirst(feedback.count - 300) }
        refreshLog()
    }

    func refreshLog() {
        let host = current?.sshHost ?? "my-tunnel"
        let cmd = "tail -n 400 '\(ROOT)/log/tunnel-resident-\(host).log' 2>/dev/null | awk -v s='\(sessionSince)' '{ ts=substr($0,1,19); if (ts ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) { keep = (ts >= s) } if (keep) print }'"
        let (_, out) = shell(cmd, timeout: 6)
        var body = "（本次会话日志，\(sessionSince) 起；旧日志已隐藏）\n"
        body += out.isEmpty ? "（隧道日志暂无新内容）" : out
        if !feedback.isEmpty {
            body += "\n—— 操作反馈（本次会话）——\n" + feedback.joined(separator: "\n")
        }
        logView.string = body
        logView.scrollToEndOfDocument(nil)
    }

    func probeStatus(_ s: SavedServer, completion: @escaping (Bool, String) -> Void) {
        let cmd = "cd \(ROOT) && CODEX_PROBE_HOST='\(s.probeHost)' ./scripts/resident.sh status \(s.sshHost)"
        DispatchQueue.global().async {
            let (rc, out) = shell(cmd, timeout: 40)
            var model = "?"
            for line in out.components(separatedBy: "\n") where line.contains("/v1/models") {
                if let v = line.split(separator: "=").last { model = v.trimmingCharacters(in: .whitespaces) }
            }
            // 以模型接口是否 200 为准；rc 只用来区分“连不上/端口不全”，不当成异常结论
            let ok = (model == "200")
            DispatchQueue.main.async { completion(ok, model + (rc == 0 ? "" : " (rc=\(rc))")) }
        }
    }

    func updateStatusPill(ok: Bool?, text: String) {
        statusLabel.stringValue = text
        func paint(_ pill: NSColor, _ dot: NSColor) {
            if let p = statusPill as? AdaptiveView { p.fillColor = pill; p.applyColors() }
            if let d = statusDot as? AdaptiveView { d.fillColor = dot; d.applyColors() }
        }
        if let ok = ok {
            paint(ok ? Theme.accentSoft : Theme.hover, ok ? Theme.accent : Theme.bad)
            statusLabel.textColor = ok ? Theme.accent : NSColor.secondaryLabelColor
            lastOK = ok
        } else {
            paint(Theme.hover, NSColor.tertiaryLabelColor)
            statusLabel.textColor = NSColor.secondaryLabelColor
        }
    }

    func refreshStatus() {
        guard let s = current else { return }
        updateStatusPill(ok: nil, text: "检查中…")
        probeStatus(s) { ok, detail in
            if ok {
                self.updateStatusPill(ok: true, text: "正常 · 模型 200")
                self.reloadServerUI()
            } else {
                self.updateStatusPill(ok: nil, text: "首次探测 \(detail)，重试中…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.probeStatus(s) { ok2, detail2 in
                        self.updateStatusPill(ok: ok2, text: ok2 ? "正常 · 模型 200" : "异常 · \(detail2)")
                        self.reloadServerUI()
                    }
                }
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
            timeout: 220) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refreshStatus() }
                self.refreshLog()
            }
    }
    @objc func onRefresh() { refreshStatus(); refreshLog() }
    // MARK: 本机代理启动：确保 Clash/magpie，并以 --proxy-server 启动 ChatGPT（原独立启动器的功能）
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
                    self.appendFeedback("ChatGPT 已在代理模式运行，已切到前台", title: "启动 ChatGPT")
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
                    self.appendFeedback(err, title: "启动 ChatGPT")
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
        echo "mcp_hub: $(grep -A2 '^\[mcp_servers.magpie\]' ~/.codex/config.toml 2>/dev/null | grep -m1 'url' || echo MISSING)"
        echo "mihomo 上游端口: $(grep -m1 -E '^\s*port:' ~/.config/mihomo/config.yaml 2>/dev/null || echo MISSING)  (应为 %PROXYPORT%)"
        echo "sshd keepalive: $(grep -E '^\s*ClientAliveInterval' /etc/ssh/sshd_config 2>/dev/null | head -1 || echo '未设置（需 root）')"
        """#
            .replacingOccurrences(of: "%M%", with: "\(s.remoteModelPort)")
            .replacingOccurrences(of: "%PROXYPORT%", with: "\(s.remoteProxyPort)")
        let quoted = "'" + remote.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none \(s.probeHost) \(quoted)"
        DispatchQueue.global().async {
            let (_, out) = shell(cmd, timeout: 90)
            DispatchQueue.main.async {
                self.busy = false
                self.appendFeedback(out.isEmpty ? "（检查失败：确认探测 Host 可登录）" : out,
                                    title: "服务器依赖检查（\(s.name)）")
                self.actionLabel.stringValue = "依赖检查完成，结果见「隧道与日志」"
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
