import Cocoa

extension AppDelegate {
    func makeTunnelTab() -> NSView {
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
        return box1
    }
}
