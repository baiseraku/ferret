import Cocoa

extension AppDelegate {
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
        updateStatusBar()
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
}
