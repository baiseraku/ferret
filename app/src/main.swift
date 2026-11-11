import Darwin
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

struct SyncPaths: Codable {
    var skillsSrc: String = "~/.agents/skills"
    var skillsDest: String = "~/.codex/skills"
    var modelsSrc: String = "~/.codex/magpie-models.json"
    var modelsDest: String = "~/.codex/magpie-models.json"
    var agentsSrc: String = "~/.codex/AGENTS.md"
    var agentsDest: String = "~/.codex/AGENTS.md"
    var mirror: Bool = true
}

struct AppConfig: Codable {
    var servers: [SavedServer] = []
    var selected: Int = 0
    var compression: [String: Bool]? = nil   // 每个连接是否开启 SSH 压缩（key = sshHost）
    var syncPaths: SyncPaths? = nil           // skills / 模型 / AGENTS.md 的同步来源与目标
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
    // 父进程关闭写端，否则子进程退出后也拿不到 EOF
    out.fileHandleForWriting.closeFile()

    let limit = max(1, timeout)
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { usleep(50_000) }

    var timedOut = false
    if p.isRunning {
        timedOut = true
        p.terminate()
        let grace = Date().addingTimeInterval(2)
        while p.isRunning && Date() < grace { usleep(50_000) }
        if p.isRunning {
            kill(-p.processIdentifier, SIGKILL)   // 连同子进程（ssh 等）一起结束
            kill(p.processIdentifier, SIGKILL)
            let hard = Date().addingTimeInterval(2)
            while p.isRunning && Date() < hard { usleep(50_000) }
        }
    }

    // 非阻塞读，避免残留子进程握住管道导致永久卡死
    let fd = out.fileHandleForReading.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var data = Data()
    let readDeadline = Date().addingTimeInterval(3)
    var buf = [UInt8](repeating: 0, count: 65536)
    while Date() < readDeadline {
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            data.append(buf, count: n)
        } else if n == 0 {
            break
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            break
        } else {
            usleep(20_000)
        }
    }
    try? out.fileHandleForReading.close()

    // 只有确认已退出才读 terminationStatus：否则 NSConcreteTask 会抛 ObjC 异常，整个 app abort
    var status: Int32 = -1
    if !p.isRunning {
        status = p.terminationStatus
    }
    let text = (String(data: data, encoding: .utf8) ?? "") + (timedOut ? "\n(shell 超时 \(Int(limit))s，已终止)" : "")
    return (status, text)
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

func sshBlock(_ s: SavedServer, compression: Bool) -> String {
    let (b, e) = blockMarkers(s.sshHost)
    let compLine = compression ? "  Compression yes\n" : ""
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
    \(compLine)\(e)
    """
}

func compressionFromSSHConfig(_ host: String) -> Bool {
    guard let text = try? String(contentsOfFile: SSH_CONFIG, encoding: .utf8) else { return false }
    var inside = false
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") { continue }
        if line.hasPrefix("Host ") {
            inside = line.dropFirst(5).split(separator: " ").map(String.init).contains(host)
            continue
        }
        if inside, line.lowercased().hasPrefix("compression") {
            return line.lowercased().contains("yes")
        }
    }
    return false
}

func writeSSHBlock(_ s: SavedServer, compression: Bool) -> String {
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
    text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + sshBlock(s, compression: compression) + "\n"
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
    var onAppearanceChange: (() -> Void)?
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
        defer { onAppearanceChange?() }
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
    var contextField: NSTextField?
    var contextWindowField: NSTextField?
    var asyncCompactionCheck: NSButton?
    var statusTimer: Timer?
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

        // 编辑菜单：没有它，输入框/日志里的 ⌘C ⌘V ⌘A 都不会生效
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }

    @objc func onShowWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoSaveSyncPaths()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        autoSaveSyncPaths()
        sender.orderOut(nil)   // 只隐藏窗口，进程继续跑（常驻隧道不受影响）
        return false
    }

    func applicationDidFinishLaunching(_ n: Notification) {
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
        reloadServerUI()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshLog()
        }
        // 每 20 秒做一次深度健康检查（端口/网关/出口/封禁）
        statusTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self = self, !self.busy, !self.healthInFlight else { return }
            self.healthInFlight = true
            self.refreshStatus { self.healthInFlight = false }
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
        // 外观切换时统一刷新所有可编辑输入框与文本视图的文字颜色
        // （嵌套在 layer-backed 视图里的字段经常保留旧外观解析出的颜色，导致白底白字）
        content.onAppearanceChange = { [weak content] in
            guard let root = content else { return }
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let color = dark ? NSColor.white : NSColor.black
            func walk(_ v: NSView) {
                if let tf = v as? NSTextField, tf.isEditable {
                    tf.textColor = color
                    tf.needsDisplay = true
                }
                if let tv = v as? NSTextView {
                    tv.textColor = color
                    tv.needsDisplay = true
                }
                v.subviews.forEach(walk)
            }
            walk(root)
        }
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
        let sideBtns = NSStackView(views: [addServerBtn])
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
        // 「更多」用和普通按钮一致的自绘胶囊，点开二级菜单
        let moreBtn = pill("更多 ▾", #selector(onMoreMenu(_:)))
        buildMoreMenu()

        let actions = NSStackView(views: [
            pill("启动", #selector(onStart), primary: true),
            pill("停止", #selector(onStop)),
            pill("重启", #selector(onRestart)),
            pill("刷新状态", #selector(onRefresh)),
            moreBtn,
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
            chatCard.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 14),
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

        let compCheck = NSButton(checkboxWithTitle: "SSH 压缩 Compression yes",
                                 target: self, action: #selector(onToggleCompression))
        compCheck.font = .systemFont(ofSize: 11)
        compressionCheck = compCheck
        let cfgOps = NSStackView(views: [
            pill("保存并重启", #selector(onSaveConfig), primary: true, height: 26),
            pill("只写 ssh config", #selector(onWriteSSHOnly), height: 26),
            compCheck,
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

        // Tab 4：同步（来源/目标可自定义）
        let box4 = NSView(); box4.translatesAutoresizingMaskIntoConstraints = false
        let syncStack = NSStackView()
        syncStack.orientation = .vertical
        syncStack.alignment = .leading
        syncStack.spacing = 8
        syncStack.translatesAutoresizingMaskIntoConstraints = false
        box4.addSubview(syncStack)
        NSLayoutConstraint.activate([
            syncStack.topAnchor.constraint(equalTo: box4.topAnchor),
            syncStack.leadingAnchor.constraint(equalTo: box4.leadingAnchor),
            syncStack.trailingAnchor.constraint(equalTo: box4.trailingAnchor),
        ])
        let syncBottom = syncStack.bottomAnchor.constraint(lessThanOrEqualTo: box4.bottomAnchor)
        syncBottom.priority = .defaultHigh
        syncBottom.isActive = true

        func syncField(_ key: String, _ placeholder: String) -> NSView {
            let f = NSTextField(string: "")
            f.placeholderString = placeholder
            f.font = .systemFont(ofSize: 12)
            f.isBezeled = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.translatesAutoresizingMaskIntoConstraints = false
            f.delegate = self
            syncFields[key] = f

            let box = AdaptiveView()
            box.fillColor = Theme.fieldBG
            box.radius = 6
            box.applyColors()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(f)
            NSLayoutConstraint.activate([
                box.heightAnchor.constraint(equalToConstant: 26),
                f.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                f.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -16),
                f.heightAnchor.constraint(equalToConstant: 18),
                f.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
            box.onAppearanceChange = { [weak f] in
                f?.textColor = .labelColor
                f?.needsDisplay = true
            }
            return box
        }

        func syncCard(_ title: String, _ srcKey: String, _ destKey: String, buttons: [NSView]) -> NSView {
            let card = CardView(fill: Theme.windowBG, radius: 8)
            card.translatesAutoresizingMaskIntoConstraints = false
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            ])
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            row.alignment = .centerY
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 13, weight: .semibold)
            t.translatesAutoresizingMaskIntoConstraints = false
            t.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let src = syncField(srcKey, "本机路径")
            let arrow = NSTextField(labelWithString: "→")
            arrow.font = .systemFont(ofSize: 12, weight: .semibold)
            arrow.textColor = Theme.accent
            let dst = syncField(destKey, "服务器路径")
            row.addArrangedSubview(t)
            row.addArrangedSubview(src)
            row.addArrangedSubview(arrow)
            row.addArrangedSubview(dst)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            src.widthAnchor.constraint(equalTo: dst.widthAnchor).isActive = true

            let br = NSStackView(views: buttons)
            br.orientation = .horizontal
            br.spacing = 8
            stack.addArrangedSubview(br)
            return card
        }

        let skillsMirror = NSButton(checkboxWithTitle: "镜像：删除服务器多余技能",
                                    target: self, action: #selector(onToggleSyncMirror))
        skillsMirror.font = .systemFont(ofSize: 11)
        syncMirrorCheck = skillsMirror

        let skillsCard = syncCard("Skills", "skillsSrc", "skillsDest", buttons: [
            pill("同步 Skills", #selector(onSyncSkills), primary: true, height: 26), skillsMirror,
        ])
        let modelsCard = syncCard("模型目录", "modelsSrc", "modelsDest", buttons: [
            pill("同步模型", #selector(onSyncModels), primary: true, height: 26),
        ])
        let agentsCard = syncCard("AGENTS.md", "agentsSrc", "agentsDest", buttons: [
            pill("同步到服务器", #selector(onSyncAgents), primary: true, height: 26),
            pill("从服务器拉取", #selector(onPullAgents), height: 26),
            pill("强制覆盖", #selector(onForceSyncAgents), height: 26),
        ])
        for card in [skillsCard, modelsCard, agentsCard] {
            syncStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: syncStack.widthAnchor).isActive = true
        }

        // 远端 codex 上下文（model_auto_compact_token_limit）
        let ctxCard = CardView(fill: Theme.windowBG, radius: 8)
        ctxCard.translatesAutoresizingMaskIntoConstraints = false
        let ctxStack = NSStackView()
        ctxStack.orientation = .vertical
        ctxStack.alignment = .leading
        ctxStack.spacing = 6
        ctxStack.translatesAutoresizingMaskIntoConstraints = false
        ctxCard.addSubview(ctxStack)
        NSLayoutConstraint.activate([
            ctxStack.topAnchor.constraint(equalTo: ctxCard.topAnchor, constant: 10),
            ctxStack.leadingAnchor.constraint(equalTo: ctxCard.leadingAnchor, constant: 12),
            ctxStack.trailingAnchor.constraint(equalTo: ctxCard.trailingAnchor, constant: -12),
            ctxStack.bottomAnchor.constraint(equalTo: ctxCard.bottomAnchor, constant: -10),
        ])
        let ctxTitle = NSTextField(labelWithString: "远端 codex 上下文")
        ctxTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        ctxStack.addArrangedSubview(ctxTitle)
        let ctxHint = NSTextField(labelWithString: "服务器 ~/.codex/config.toml 的 model_auto_compact_token_limit；留空表示不设置")
        ctxHint.font = .systemFont(ofSize: 11)
        ctxHint.textColor = .secondaryLabelColor
        ctxStack.addArrangedSubview(ctxHint)
        let ctxRow = NSStackView(); ctxRow.orientation = .horizontal; ctxRow.spacing = 8
        let ctxLabel = NSTextField(labelWithString: "自动压缩阈值")
        ctxLabel.font = .systemFont(ofSize: 11)
        ctxLabel.textColor = .secondaryLabelColor
        ctxLabel.translatesAutoresizingMaskIntoConstraints = false
        ctxLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let cf = NSTextField(string: "")
        cf.placeholderString = "例如 200000"
        cf.font = .systemFont(ofSize: 12)
        cf.isBezeled = false
        cf.drawsBackground = false
        cf.focusRingType = .none
        cf.translatesAutoresizingMaskIntoConstraints = false
        contextField = cf
        let cfBox = AdaptiveView()
        cfBox.fillColor = Theme.fieldBG
        cfBox.radius = 6
        cfBox.applyColors()
        cfBox.translatesAutoresizingMaskIntoConstraints = false
        cfBox.addSubview(cf)
        NSLayoutConstraint.activate([
            cfBox.heightAnchor.constraint(equalToConstant: 26),
            cfBox.widthAnchor.constraint(equalToConstant: 150),
            cf.leadingAnchor.constraint(equalTo: cfBox.leadingAnchor, constant: 8),
            cf.trailingAnchor.constraint(lessThanOrEqualTo: cfBox.trailingAnchor, constant: -8),
            cf.centerYAnchor.constraint(equalTo: cfBox.centerYAnchor),
        ])
        cfBox.onAppearanceChange = { [weak cf] in
            cf?.textColor = .labelColor
            cf?.needsDisplay = true
        }
        ctxRow.addArrangedSubview(ctxLabel)
        ctxRow.addArrangedSubview(cfBox)
        ctxRow.addArrangedSubview(pill("读取", #selector(onReadRemoteContext), height: 26))
        ctxRow.addArrangedSubview(pill("应用", #selector(onApplyRemoteContext), primary: true, height: 26))
        ctxRow.addArrangedSubview(pill("恢复默认", #selector(onResetRemoteContext), height: 26))
        ctxStack.addArrangedSubview(ctxRow)

        let ctxRow2 = NSStackView(); ctxRow2.orientation = .horizontal; ctxRow2.spacing = 8
        let ctxLabel2 = NSTextField(labelWithString: "上下文窗口")
        ctxLabel2.font = .systemFont(ofSize: 11)
        ctxLabel2.textColor = .secondaryLabelColor
        ctxLabel2.translatesAutoresizingMaskIntoConstraints = false
        ctxLabel2.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let cwf = NSTextField(string: "")
        cwf.placeholderString = "例如 400000"
        cwf.font = .systemFont(ofSize: 12)
        cwf.isBezeled = false
        cwf.drawsBackground = false
        cwf.focusRingType = .none
        cwf.translatesAutoresizingMaskIntoConstraints = false
        contextWindowField = cwf
        let cwfBox = AdaptiveView()
        cwfBox.fillColor = Theme.fieldBG
        cwfBox.radius = 6
        cwfBox.applyColors()
        cwfBox.translatesAutoresizingMaskIntoConstraints = false
        cwfBox.addSubview(cwf)
        NSLayoutConstraint.activate([
            cwfBox.heightAnchor.constraint(equalToConstant: 26),
            cwfBox.widthAnchor.constraint(equalToConstant: 150),
            cwf.leadingAnchor.constraint(equalTo: cwfBox.leadingAnchor, constant: 8),
            cwf.trailingAnchor.constraint(lessThanOrEqualTo: cwfBox.trailingAnchor, constant: -8),
            cwf.centerYAnchor.constraint(equalTo: cwfBox.centerYAnchor),
        ])
        cwfBox.onAppearanceChange = { [weak cwf] in
            cwf?.textColor = .labelColor
            cwf?.needsDisplay = true
        }
        let asyncCheck = NSButton(checkboxWithTitle: "启用异步压缩 [features.async_compaction]",
                                  target: nil, action: nil)
        asyncCheck.state = .off
        asyncCheck.font = .systemFont(ofSize: 11)
        asyncCompactionCheck = asyncCheck
        ctxRow2.addArrangedSubview(ctxLabel2)
        ctxRow2.addArrangedSubview(cwfBox)
        ctxRow2.addArrangedSubview(asyncCheck)
        ctxStack.addArrangedSubview(ctxRow2)
        syncStack.addArrangedSubview(ctxCard)
        ctxCard.widthAnchor.constraint(equalTo: syncStack.widthAnchor).isActive = true
        let depRow = NSStackView(views: [pill("检查服务器依赖", #selector(onCheckServerDeps), height: 26)])
        depRow.orientation = .horizontal
        syncStack.addArrangedSubview(depRow)
        tabBoxes.append(box4)

        tabBoxes = [box1, box2, box3, box4]
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
        if segmented.selectedSegment != 3 { autoSaveSyncPaths() }
        let idx = max(0, min(segmented.selectedSegment, tabBoxes.count - 1))
        for (i, b) in tabBoxes.enumerated() { b.isHidden = (i != idx) }
        if idx == 3, (contextField?.stringValue.isEmpty ?? false), !busy {
            onReadRemoteContext()
        }
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
        let sp = config.syncPaths ?? SyncPaths()
        syncFields["skillsSrc"]?.stringValue = sp.skillsSrc
        syncFields["skillsDest"]?.stringValue = sp.skillsDest
        syncFields["modelsSrc"]?.stringValue = sp.modelsSrc
        syncFields["modelsDest"]?.stringValue = sp.modelsDest
        syncFields["agentsSrc"]?.stringValue = sp.agentsSrc
        syncFields["agentsDest"]?.stringValue = sp.agentsDest
        syncMirrorCheck?.state = sp.mirror ? .on : .off

        compressionCheck?.state = (s.map { compressionEnabled($0.sshHost) } ?? false) ? .on : .off
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

    struct HealthResult {
        var ports = 0
        var models = "000"
        var openai = "000"
        var me = "000"
        var exitIP = ""
        var loc = ""
        var serverIP = ""
        var error = ""
        var localIP = ""
        var tcpOpen = false
        var sshBanner = false
    }

    func runHealthCheck(_ s: SavedServer, completion: @escaping (HealthResult) -> Void) {
        let cmd = "cd \(ROOT) && ./scripts/health-check.sh '\(s.probeHost)'"
        DispatchQueue.global().async {
            let (rc, out) = shell(cmd, timeout: 45)
            var h = HealthResult()
            if let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
               let data = String(line).data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                h.ports = obj["ports"] as? Int ?? 0
                h.models = String(describing: obj["models"] as? String ?? "000")
                h.openai = String(describing: obj["openai"] as? String ?? "000")
                h.me = String(describing: obj["me"] as? String ?? "000")
                h.exitIP = obj["exit"] as? String ?? ""
                h.loc = obj["loc"] as? String ?? ""
                h.serverIP = obj["server_ip"] as? String ?? ""
                h.error = obj["error"] as? String ?? ""
            } else {
                h.error = rc == 0 ? "parse" : "ssh"
            }
            if h.error == "ssh" {
                // 本机出口 IP + 服务器端口可达性/SSH banner，用来判断是不是本机 IP 被服务器封了
                let g = shell("/usr/bin/ssh -G '\(s.probeHost)' 2>/dev/null | awk '/^hostname /{print $2} /^port /{print $2}'").1
                    .split(separator: "\n").map(String.init)
                h.localIP = shell("/usr/bin/curl -s -m 5 --noproxy '*' https://ifconfig.me/ip", timeout: 10).1
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if g.count >= 2 {
                    let host = g[0], port = g[1]
                    h.tcpOpen = shell("/usr/bin/nc -z -G 4 \(host) \(port)", timeout: 10).0 == 0
                    if h.tcpOpen {
                        let banner = shell("(printf '\\n' | /usr/bin/nc -w 4 \(host) \(port)) 2>/dev/null | head -1", timeout: 10).1
                        h.sshBanner = banner.contains("SSH-")
                    }
                }
            }
            DispatchQueue.main.async { completion(h) }
        }
    }

    func statusText(for h: HealthResult) -> (ok: Bool?, text: String, detail: String) {
        if h.error == "ssh" {
            let ipInfo = h.localIP.isEmpty ? "" : "本机出口 IP \(h.localIP)"
            if h.sshBanner {
                return (false, "SSH 被拒 · 本机 IP 可能被封",
                        "\(ipInfo)；端口能连、SSH 也有 banner，但登录失败，多半是服务器端封禁/拒绝（fail2ban、allowusers、TCP wrapper）")
            }
            if h.tcpOpen {
                return (false, "服务器端口无 SSH 响应",
                        "\(ipInfo)；TCP 能连上但没有 SSH banner，可能被防火墙拦截或 sshd 异常")
            }
            return (false, "连不上服务器", "\(ipInfo)；TCP 也不可达，检查网络、DNS 或服务器是否在线")
        }
        if h.error == "parse" { return (false, "检查失败", "健康检查输出异常") }

        let modelOK = h.models == "200"
        let portsOK = h.ports >= 2
        let limited = ["429"].contains(h.openai) || ["429"].contains(h.me)
        let banned = ["403", "451"].contains(h.openai) || ["403", "451"].contains(h.me)
        let direct = !h.exitIP.isEmpty && !h.serverIP.isEmpty && h.exitIP == h.serverIP

        var text = modelOK ? "正常 · 模型 200" : "网关异常 · \(h.models)"
        if !portsOK { text = "端口异常 · \(h.ports)/2" }
        if !h.loc.isEmpty { text += " · \(h.loc)" }

        var detail = "出口 \(h.exitIP.isEmpty ? "未知" : h.exitIP)"
        if banned {
            return (false, "出口可能被封 · \(h.openai)", detail + "（OpenAI 返回 \(h.openai)，限流/封禁）")
        }
        if limited {
            return (true, "正常 · 但已限流 · \(h.loc)", detail + "（429，额度或速率限制）")
        }
        if direct {
            return (false, "出网未走隧道", detail + " = 服务器自身 IP，OpenAI 流量没走回本机")
        }
        if !modelOK || !portsOK {
            return (false, text, detail)
        }
        return (true, text, detail)
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

    func refreshStatus(completion: (() -> Void)? = nil) {
        guard let s = current else { completion?(); return }
        updateStatusPill(ok: nil, text: "检查中…")
        runHealthCheck(s) { h in
            let r = self.statusText(for: h)
            self.updateStatusPill(ok: r.ok, text: r.text)
            self.lastStatusDetail = r.detail
            self.lastOK = (r.ok == true)
            self.reloadServerUI()
            completion?()
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
        let err = writeSSHBlock(s, compression: compressionEnabled(s.sshHost))
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

    func quoteShell(_ v: String) -> String {
        "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func autoSaveSyncPaths() {
        var sp = config.syncPaths ?? SyncPaths()
        if let v = syncFields["skillsSrc"]?.stringValue, !v.isEmpty { sp.skillsSrc = v }
        if let v = syncFields["skillsDest"]?.stringValue, !v.isEmpty { sp.skillsDest = v }
        if let v = syncFields["modelsSrc"]?.stringValue, !v.isEmpty { sp.modelsSrc = v }
        if let v = syncFields["modelsDest"]?.stringValue, !v.isEmpty { sp.modelsDest = v }
        if let v = syncFields["agentsSrc"]?.stringValue, !v.isEmpty { sp.agentsSrc = v }
        if let v = syncFields["agentsDest"]?.stringValue, !v.isEmpty { sp.agentsDest = v }
        sp.mirror = (syncMirrorCheck?.state == .on)
        config.syncPaths = sp
        saveConfig(config)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, syncFields.values.contains(where: { $0 === f }) else { return }
        autoSaveSyncPaths()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        controlTextDidChange(obj)
    }

    @objc func onToggleSyncMirror() { autoSaveSyncPaths() }

    func persistSyncPaths() -> SyncPaths {
        var sp = config.syncPaths ?? SyncPaths()
        if let v = syncFields["skillsSrc"]?.stringValue, !v.isEmpty { sp.skillsSrc = v }
        if let v = syncFields["skillsDest"]?.stringValue, !v.isEmpty { sp.skillsDest = v }
        if let v = syncFields["modelsSrc"]?.stringValue, !v.isEmpty { sp.modelsSrc = v }
        if let v = syncFields["modelsDest"]?.stringValue, !v.isEmpty { sp.modelsDest = v }
        if let v = syncFields["agentsSrc"]?.stringValue, !v.isEmpty { sp.agentsSrc = v }
        if let v = syncFields["agentsDest"]?.stringValue, !v.isEmpty { sp.agentsDest = v }
        sp.mirror = (syncMirrorCheck?.state == .on)
        config.syncPaths = sp
        saveConfig(config)
        return sp
    }

    func runContextCommand(_ label: String, _ flag: String) {
        guard let s = current else { return }
        touch(s, label)
        run(label, "cd \(ROOT) && ./scripts/set-remote-context.sh \(flag) --host \(quoteShell(s.probeHost))", timeout: 60)
    }

    @objc func onReadRemoteContext() {
        guard let s = current, !busy else { return }
        busy = true
        actionLabel.stringValue = "读取远端上下文…"
        let cmd = "cd \(ROOT) && ./scripts/set-remote-context.sh --get --host \(quoteShell(s.probeHost))"
        DispatchQueue.global().async {
            let (_, out) = shell(cmd, timeout: 60)
            var limit = "", window = "", asyncOn: Bool? = nil
            if let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
               let data = String(line).data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                limit = obj["model_auto_compact_token_limit"] as? String ?? ""
                window = obj["model_context_window"] as? String ?? ""
                let a = obj["async_compaction"] as? String ?? "unset"
                asyncOn = (a == "true") ? true : (a == "false" ? false : nil)
            }
            DispatchQueue.main.async {
                self.busy = false
                func put(_ f: NSTextField?, _ v: String) {
                    f?.stringValue = (v.range(of: #"^\d+$"#, options: .regularExpression) != nil) ? v : ""
                }
                put(self.contextField, limit)
                put(self.contextWindowField, window)
                self.asyncCompactionCheck?.state = (asyncOn == true) ? .on : .off
                self.appendFeedback("自动压缩阈值: \(limit)，上下文窗口: \(window)，异步压缩: \(asyncOn.map { $0 ? "on" : "off" } ?? "unset")",
                                    title: "读取远端上下文")
                self.actionLabel.stringValue = "读取完成"
            }
        }
    }

    @objc func onApplyRemoteContext() {
        guard let s = current else { return }
        let limit = (contextField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let window = (contextWindowField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        func invalid(_ msg: String) {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert(); a.messageText = msg; a.informativeText = "留空表示该项保持不动；要清除请用「恢复默认」。"
            a.addButton(withTitle: "好"); a.runModal()
        }
        if !limit.isEmpty, Int(limit) == nil { invalid("自动压缩阈值必须是整数"); return }
        if !window.isEmpty, Int(window) == nil { invalid("上下文窗口必须是整数"); return }
        if limit.isEmpty && window.isEmpty && asyncCompactionCheck?.state != .on {
            // 仍然允许：只关闭异步压缩
        }
        var args = "--apply"
        if !limit.isEmpty { args += " --limit \(limit)" }
        if !window.isEmpty { args += " --window \(window)" }
        args += " --async \((asyncCompactionCheck?.state == .on) ? "1" : "0")"
        touch(s, "应用远端上下文")
        run("应用远端上下文",
            "cd \(ROOT) && ./scripts/set-remote-context.sh \(args) --host \(quoteShell(s.probeHost))",
            timeout: 60)
    }

    @objc func onResetRemoteContext() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "恢复远端默认上下文阈值？"
        a.informativeText = "会从服务器 ~/.codex/config.toml 删除 model_auto_compact_token_limit（修改前自动备份）。"
        a.addButton(withTitle: "恢复"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        contextField?.stringValue = ""
        contextWindowField?.stringValue = ""
        asyncCompactionCheck?.state = .off
        runContextCommand("恢复远端上下文默认值", "--reset")
    }

    @objc func onSyncSkills() {
        guard let s = current else { return }
        let sp = persistSyncPaths()
        var args = "--skills --host \(quoteShell(s.probeHost)) --skills-src \(quoteShell(sp.skillsSrc)) --skills-dest \(quoteShell(sp.skillsDest))"
        if !sp.mirror { args += " --no-mirror" }
        touch(s, "同步 Skills")
        run("同步 Skills", "cd \(ROOT) && ./scripts/sync-to-server.sh \(args)", timeout: 180)
    }

    @objc func onSyncModels() {
        guard let s = current else { return }
        let sp = persistSyncPaths()
        let args = "--models --host \(quoteShell(s.probeHost)) --models-src \(quoteShell(sp.modelsSrc)) --models-dest \(quoteShell(sp.modelsDest))"
        touch(s, "同步模型")
        run("同步模型", "cd \(ROOT) && ./scripts/sync-to-server.sh \(args)", timeout: 180)
    }

    @objc func onSyncAgents() {
        guard let s = current else { return }
        let sp = persistSyncPaths()
        let args = "--agents --host \(quoteShell(s.probeHost)) --agents-src \(quoteShell(sp.agentsSrc)) --agents-dest \(quoteShell(sp.agentsDest))"
        touch(s, "同步 AGENTS.md")
        run("同步 AGENTS.md", "cd \(ROOT) && ./scripts/sync-to-server.sh \(args)", timeout: 90)
    }

    @objc func onPullAgents() {
        guard let s = current else { return }
        let sp = persistSyncPaths()
        let args = "--agents-pull --host \(quoteShell(s.probeHost)) --agents-src \(quoteShell(sp.agentsSrc)) --agents-dest \(quoteShell(sp.agentsDest))"
        touch(s, "拉取 AGENTS.md")
        run("拉取 AGENTS.md", "cd \(ROOT) && ./scripts/sync-to-server.sh \(args)", timeout: 90)
    }

    @objc func onForceSyncAgents() {
        guard let s = current else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "强制用本机 AGENTS.md 覆盖服务器？"
        a.informativeText = "会先备份服务器上的旧文件。注意：服务器版本的机器专属内容（如 --catalog 参数）会被覆盖。"
        a.addButton(withTitle: "强制覆盖"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let sp = persistSyncPaths()
        var args = "--agents --force --host \(quoteShell(s.probeHost)) --agents-src \(quoteShell(sp.agentsSrc)) --agents-dest \(quoteShell(sp.agentsDest))"
        args += ""
        touch(s, "强制同步 AGENTS.md")
        run("强制同步 AGENTS.md", "cd \(ROOT) && ./scripts/sync-to-server.sh \(args)", timeout: 90)
    }

    func buildMoreMenu() {
        let menu = NSMenu()
        let entries: [(String, Selector?)] = [
            ("修复连接", #selector(onHeal)),
            ("复制日志", #selector(onCopyLog)),
            ("打开日志目录", #selector(onOpenLogs)),
            ("查看连接历史", #selector(onOpenHistory)),
            ("清空连接历史", #selector(onClearHistory)),
            ("", nil),
            ("重启远端 app-server", #selector(onRestartRemoteCodex)),
            ("重启本机 app-server", #selector(onRestartLocalAppServer)),
            ("检查服务器依赖", #selector(onCheckServerDeps)),
            ("", nil),
            ("删除当前服务器", #selector(onRemoveServer)),
        ]
        for (title, action) in entries {
            if let action = action {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            } else {
                menu.addItem(NSMenuItem.separator())
            }
        }
        moreMenu = menu
    }

    @objc func onMoreMenu(_ sender: NSButton) {
        guard let menu = moreMenu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    @objc func onRestartLocalAppServer() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重启本机 app-server？"
        alert.informativeText = "会结束 Mac 上的 codex app-server，本机正在进行的对话/回合会被中断。\n只影响本机，不影响服务器上的远程工作区。"
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("重启本机 app-server",
            "cd \(ROOT) && ./scripts/restart-local-app-server.sh",
            timeout: 60)
    }

    @objc func onRestartRemoteCodex() {
        guard let s = current else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重启远端 codex？"
        alert.informativeText = "会结束服务器上的 app-server，正在进行的对话/回合会被中断（之后需新建对话）。\n如果只是模型列表没刷新，可以等当前回合结束后再重启。"
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        touch(s, "重启远端 codex")
        run("重启远端 codex",
            "cd \(ROOT) && ./scripts/restart-remote-codex.sh '\(s.probeHost)'",
            timeout: 120)
    }

    func compressionEnabled(_ host: String) -> Bool {
        if let v = config.compression?[host] { return v }
        return compressionFromSSHConfig(host)
    }

    @objc func onToggleCompression(_ sender: NSButton) {
        guard let s = current else { return }
        var dict = config.compression ?? [:]
        dict[s.sshHost] = (sender.state == .on)
        config.compression = dict
        saveConfig(config)
        actionLabel.stringValue = (sender.state == .on ? "已开启压缩" : "已关闭压缩") + "，点「保存并重启」后生效"
    }

    @objc func onSyncToServer() {
        guard let s = current else { return }
        touch(s, "同步 skill/模型")
        run("同步 skill/模型",
            "cd \(ROOT) && ./scripts/sync-to-server.sh --skills --models --host '\(s.probeHost)'",
            timeout: 180) { self.refreshStatus() }
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
        let err = writeSSHBlock(s, compression: compressionEnabled(s.sshHost))
        if err.isEmpty {
            if let i = config.servers.firstIndex(where: { $0.sshHost == s.sshHost }) { config.servers[i] = s } else { config.servers.append(s) }
            saveConfig(config); reloadServerUI(); actionLabel.stringValue = "已写入 ssh config（未重启）"
        } else { actionLabel.stringValue = err }
    }

    @objc func onSaveConfig() {
        guard let s = currentFromFields() else { return }
        let old = current
        let err = writeSSHBlock(s, compression: compressionEnabled(s.sshHost))
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
