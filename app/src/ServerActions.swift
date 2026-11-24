import Cocoa

extension AppDelegate {
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
}
