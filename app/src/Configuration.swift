import Cocoa

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
    var healthKey: String { [sshHost, probeHost, String(remoteModelPort), String(remoteProxyPort)].joined(separator: "\u{1F}") }
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
