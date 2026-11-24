import Cocoa

extension AppDelegate {
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

    @objc func onCompareSkills() {
        guard let server = current, window.attachedSheet == nil else { return }
        guard !busy else {
            actionLabel.stringValue = "上一个操作还在进行，请稍候…"
            return
        }
        let paths = persistSyncPaths()
        let client = SkillsSyncClient(host: server.probeHost, localPath: paths.skillsSrc, remotePath: paths.skillsDest)
        let controller = SkillsComparisonController(serverName: server.name, client: client)
        guard let sheet = controller.window else { return }
        skillsComparisonController = controller
        window.beginSheet(sheet) { [weak self] _ in self?.skillsComparisonController = nil }
        controller.refresh()
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
}
