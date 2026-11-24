import Cocoa

extension AppDelegate {
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
        guard let s = current else { updateStatusBar(); completion?(); return }
        let request = UUID()
        healthRequests[s.healthKey] = request
        updateStatusPill(ok: nil, text: "检查中…")
        updateStatusBar()
        runHealthCheck(s) { h in
            defer { completion?() }
            guard self.healthRequests[s.healthKey] == request,
                  self.config.servers.contains(where: { $0.healthKey == s.healthKey }) else { return }
            let r = self.statusText(for: h)
            self.tunnelHealth[s.healthKey] = TunnelHealth(ok: r.ok, text: r.text)
            self.updateStatusBar()
            // 切换服务器后，较早的异步检查不能覆盖当前服务器的状态。
            guard self.current?.healthKey == s.healthKey else { return }
            self.updateStatusPill(ok: r.ok, text: r.text)
            self.lastStatusDetail = r.detail
            self.lastOK = (r.ok == true)
            self.reloadServerUI()
        }
    }
}
