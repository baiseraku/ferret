import Cocoa

extension AppDelegate {
    func makeSyncTab() -> NSView {
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
            pill("对比 Skills…", #selector(onCompareSkills), primary: true, height: 26),
            pill("同步 Skills", #selector(onSyncSkills), height: 26), skillsMirror,
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
        return box4
    }
}
