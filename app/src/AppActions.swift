import Cocoa

extension AppDelegate {
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
