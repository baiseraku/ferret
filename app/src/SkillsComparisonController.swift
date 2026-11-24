import Cocoa

final class SkillsComparisonController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let client: SkillsSyncClient
    private let serverName: String
    private var snapshot: SkillsComparison?
    private var rows: [ComparedSkill] = []
    private var refreshing = false
    private var updating = false
    private var reloadingRows = false
    private var previewID = UUID()

    private let summary = NSTextField(labelWithString: "正在读取两端 Skills…")
    private let feedback = NSTextField(labelWithString: "")
    private let selectionTitle = NSTextField(labelWithString: "选择一个 Skill")
    private let localVersion = NSTextField(labelWithString: "")
    private let remoteVersion = NSTextField(labelWithString: "")
    private let filePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let diffView = NSTextView()
    private let onlyDifferences = NSButton(checkboxWithTitle: "仅看差异", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let updateButton = NSButton(title: "更新到服务器", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    init(serverName: String, client: SkillsSyncClient) {
        self.serverName = serverName
        self.client = client
        let frame = NSRect(x: 0, y: 0, width: 860, height: 510)
        let sheet = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "对比 Skills"
        super.init(window: sheet)
        buildContent(in: sheet)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func buildContent(in sheet: NSWindow) {
        let title = NSTextField(labelWithString: "Skills · \(serverName)")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = horizontal([title, NSView(), refreshButton])
        let footer = horizontal([feedback, NSView(), updateButton, closeButton])
        feedback.font = .systemFont(ofSize: 12)
        feedback.lineBreakMode = .byTruncatingTail
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: 13, weight: .medium)

        for (button, action) in [(refreshButton, #selector(reloadComparison)), (closeButton, #selector(closeSheet)),
                                 (onlyDifferences, #selector(toggleFilter)), (updateButton, #selector(updateSelectedSkill))] {
            button.target = self
            button.action = action
        }
        closeButton.keyEquivalent = "\u{1b}"
        updateButton.isEnabled = false
        onlyDifferences.state = .on
        filePicker.target = self
        filePicker.action = #selector(showSelectedFile)
        filePicker.setAccessibilityLabel("差异文件")
        filePicker.lineBreakMode = .byTruncatingMiddle
        filePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let listScroll = makeSkillList()
        let localLabel = horizontal([localVersion, remoteVersion], spacing: 16)
        let previewScroll = makeDiffPreview()
        let details = vertical([selectionTitle, localLabel, filePicker, previewScroll], spacing: 8)
        let list = vertical([onlyDifferences, listScroll], spacing: 8)
        let body = horizontal([list, details], spacing: 14)
        body.alignment = .top
        let root = vertical([top, summary, body, footer], spacing: 12)
        let content = AdaptiveView()
        content.fillColor = Theme.windowBG
        sheet.contentView = content
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        let listWidth: CGFloat = 274
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            top.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
            list.widthAnchor.constraint(equalToConstant: listWidth),
            details.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -listWidth - body.spacing),
            list.heightAnchor.constraint(equalTo: body.heightAnchor),
            details.heightAnchor.constraint(equalTo: body.heightAnchor),
            listScroll.widthAnchor.constraint(equalTo: list.widthAnchor),
            previewScroll.widthAnchor.constraint(equalTo: details.widthAnchor),
            filePicker.widthAnchor.constraint(lessThanOrEqualTo: details.widthAnchor),
            localLabel.widthAnchor.constraint(lessThanOrEqualTo: details.widthAnchor),
            selectionTitle.widthAnchor.constraint(lessThanOrEqualTo: details.widthAnchor),
        ])
        selectionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        for label in [selectionTitle, localVersion, remoteVersion] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        localVersion.font = .systemFont(ofSize: 12)
        remoteVersion.font = localVersion.font
        showSelection()
    }

    private func makeSkillList() -> NSScrollView {
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Skill"
        name.width = 170
        name.minWidth = 110
        let status = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        status.title = "状态"
        status.width = 88
        status.minWidth = 78
        table.addTableColumn(name)
        table.addTableColumn(status)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("两端 Skills 成员及差异")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func makeDiffPreview() -> NSScrollView {
        diffView.frame = NSRect(x: 0, y: 0, width: 530, height: 280)
        diffView.autoresizingMask = [.width]
        diffView.isEditable = false
        diffView.isSelectable = true
        diffView.isVerticallyResizable = true
        diffView.textContainer?.widthTracksTextView = true
        diffView.textContainerInset = NSSize(width: 8, height: 8)
        diffView.setAccessibilityLabel("文件内容差异")
        let scroll = NSScrollView()
        scroll.documentView = diffView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private var selectedSkill: ComparedSkill? {
        let row = table.selectedRow
        return rows.indices.contains(row) ? rows[row] : nil
    }

    func refresh(preferredName: String? = nil) {
        guard !refreshing, !updating else { return }
        let selection = preferredName ?? selectedSkill?.name
        refreshing = true
        snapshot = nil
        summary.stringValue = "正在读取两端 Skills…"
        reloadRows(preferredName: nil)
        client.request(SkillsComparison.self, ["compare"]) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.updateSummary(snapshot)
                self.reloadRows(preferredName: selection)
            case .failure(let error):
                self.summary.stringValue = "读取失败，请刷新重试。"
                self.reloadRows(preferredName: nil)
                self.renderPreview(error.localizedDescription)
            }
        }
    }

    private func updateSummary(_ comparison: SkillsComparison) {
        let counts = Dictionary(grouping: comparison.skills, by: \.difference).mapValues(\.count)
        let statuses: [SkillDifference] = [.localOnly, .remoteOnly, .different]
        let parts = ["本机 \(comparison.localCount)", "服务器 \(comparison.remoteCount)"]
            + statuses.map { "\($0.label) \(counts[$0, default: 0])" }
            + (counts[.unavailable].map { ["读取失败 \($0)"] } ?? [])
        summary.stringValue = parts.joined(separator: "   ·   ")
    }

    private func reloadRows(preferredName: String?) {
        let differencesOnly = onlyDifferences.state == .on
        rows = (snapshot?.skills ?? []).filter { !differencesOnly || $0.difference != .same }
        reloadingRows = true
        table.reloadData()
        if !rows.isEmpty {
            let selected = rows.firstIndex { $0.name == preferredName } ?? 0
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        }
        reloadingRows = false
        showSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let isStatus = tableColumn?.identifier.rawValue == "status"
        let skill = rows[row]
        let text = isStatus ? skill.difference.label : skill.name
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !reloadingRows { showSelection() }
    }

    private func showSelection() {
        previewID = UUID()
        filePicker.removeAllItems()
        let skill = selectedSkill
        selectionTitle.stringValue = skill?.name ?? "选择一个 Skill"
        localVersion.stringValue = skill.map { "本机  " + ($0.local?.versionLabel ?? "缺少") } ?? ""
        remoteVersion.stringValue = skill.map { "服务器  " + ($0.remote?.versionLabel ?? "缺少") } ?? ""
        localVersion.toolTip = localVersion.stringValue
        remoteVersion.toolTip = remoteVersion.stringValue
        for change in skill?.changes ?? [] {
            let title = "\(change.status.label) · \(change.path)"
            filePicker.addItem(withTitle: title)
        }
        if filePicker.numberOfItems == 0 { filePicker.addItem(withTitle: "差异文件") }
        updateControls()

        if let skill {
            let errors = [skill.local?.error.map { "本机：\($0)" }, skill.remote?.error.map { "服务器：\($0)" }]
                .compactMap { $0 }
            if !errors.isEmpty {
                renderPreview(errors.joined(separator: "\n"))
            } else if skill.changes.isEmpty {
                renderPreview("两端文件内容一致。")
            } else {
                showSelectedFile()
            }
        } else if snapshot != nil {
            renderPreview(onlyDifferences.state == .on ? "没有差异项。" : "配置的目录中没有 Skills。")
        } else {
            renderPreview("")
        }
    }

    private func updateControls() {
        let skill = selectedSkill
        updateButton.title = skill?.difference == .localOnly ? "安装到服务器" : "更新到服务器"
        updateButton.isEnabled = !updating && !refreshing && (skill?.difference == .different || skill?.difference == .localOnly)
        refreshButton.isEnabled = !updating && !refreshing
        onlyDifferences.isEnabled = !updating && snapshot != nil
        table.isEnabled = !updating && !refreshing
        filePicker.isEnabled = !updating && (skill?.changes.isEmpty == false)
        closeButton.isEnabled = !updating
    }

    @objc private func showSelectedFile() {
        let index = filePicker.indexOfSelectedItem
        guard let skill = selectedSkill, skill.changes.indices.contains(index) else { return }
        let item = skill.changes[index]
        let requestID = UUID()
        previewID = requestID
        renderPreview("正在读取差异…")
        client.request(SkillDiffPreview.self, ["preview", "--", skill.name, item.path, item.status.rawValue]) { [weak self] result in
            guard let self, self.previewID == requestID else { return }
            switch result {
            case .success(let preview): self.renderPreview(preview.text)
            case .failure(let error): self.renderPreview(error.localizedDescription)
            }
        }
    }

    private func renderPreview(_ text: String) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let preview = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let color: NSColor
            if line.hasPrefix("+++ 本机/") || line.hasPrefix("--- 服务器/") || line.hasPrefix("@@ ") {
                color = .secondaryLabelColor
            } else if line.hasPrefix("+") {
                color = Theme.menuGreen
            } else if line.hasPrefix("-") {
                color = Theme.menuOrange
            } else {
                color = .textColor
            }
            preview.append(NSAttributedString(string: line + (index < lines.count - 1 ? "\n" : ""),
                                              attributes: [.font: font, .foregroundColor: color]))
        }
        diffView.textStorage?.setAttributedString(preview)
        diffView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    @objc private func reloadComparison() {
        feedback.stringValue = ""
        feedback.toolTip = nil
        refresh()
    }

    @objc private func toggleFilter() { reloadRows(preferredName: selectedSkill?.name) }

    @objc private func closeSheet() {
        guard !updating, let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func updateSelectedSkill() {
        guard updateButton.isEnabled, let skill = selectedSkill, let local = skill.local?.revision else { return }
        let remote = skill.remote?.revision ?? "-"
        updating = true
        feedback.stringValue = "正在上传「\(skill.name)」…"
        feedback.toolTip = nil
        updateControls()
        client.request(SkillUpdateResult.self, ["update", "--", skill.name, local, remote]) { [weak self] result in
            guard let self else { return }
            self.updating = false
            switch result {
            case .success(let update):
                self.feedback.stringValue = update.backup == nil ? "已安装「\(skill.name)」" : "已更新「\(skill.name)」，旧版已备份"
                self.feedback.toolTip = update.backup
                self.refresh(preferredName: skill.name)
            case .failure(let error):
                self.feedback.stringValue = "上传失败，请刷新对比后重试。"
                self.feedback.toolTip = error.localizedDescription
                self.previewID = UUID()
                self.renderPreview(error.localizedDescription)
                self.updateControls()
            }
        }
    }
}
