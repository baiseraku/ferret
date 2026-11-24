import Cocoa

extension AppDelegate {
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
        chatSub.lineBreakMode = .byTruncatingTail
        chatSub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chatText = NSStackView(views: [chatTitle, chatSub])
        chatText.orientation = .vertical
        chatText.alignment = .leading
        chatText.spacing = 2
        chatText.translatesAutoresizingMaskIntoConstraints = false
        chatCard.addSubview(chatText)
        let chatBtn = pill("启动 ChatGPT", #selector(onLaunchChatGPT), primary: true, height: 30)
        let cliProxyLabel = NSTextField(labelWithString: "CLI 走代理")
        cliProxyLabel.font = .systemFont(ofSize: 12)
        let cliProxySwitch = NSSwitch()
        cliProxySwitch.controlSize = .small
        cliProxySwitch.state = CodexCLIProxy.currentUser.isEnabled ? .on : .off
        cliProxySwitch.target = self
        cliProxySwitch.action = #selector(onToggleCodexCLIProxy(_:))
        cliProxySwitch.setAccessibilityLabel("终端 Codex CLI 走代理")
        cliProxySwitch.toolTip = "终端里的 codex 使用与 ChatGPT 相同的代理。首次开启后请重开终端。"
        let chatActions = NSStackView(views: [chatBtn, cliProxyLabel, cliProxySwitch])
        chatActions.orientation = .horizontal
        chatActions.alignment = .centerY
        chatActions.spacing = 6
        chatActions.setCustomSpacing(12, after: chatBtn)
        chatActions.translatesAutoresizingMaskIntoConstraints = false
        chatCard.addSubview(chatActions)

        NSLayoutConstraint.activate([
            chatCard.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 14),
            chatCard.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            chatCard.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            chatText.leadingAnchor.constraint(equalTo: chatCard.leadingAnchor, constant: 14),
            chatText.centerYAnchor.constraint(equalTo: chatCard.centerYAnchor),
            chatActions.trailingAnchor.constraint(equalTo: chatCard.trailingAnchor, constant: -12),
            chatActions.centerYAnchor.constraint(equalTo: chatCard.centerYAnchor),
            chatActions.leadingAnchor.constraint(greaterThanOrEqualTo: chatText.trailingAnchor, constant: 12),
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

        let box1 = makeTunnelTab()
        let box2 = makeReportTab()
        let box3 = makeSetupTab()
        let box4 = makeSyncTab()

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
}
