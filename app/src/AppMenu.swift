import Cocoa

extension AppDelegate {
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示窗口", action: #selector(onShowWindow), keyEquivalent: "0")
        let statusMenuItem = appMenu.addItem(withTitle: "连接状态与流量", action: #selector(onShowStatusMenu), keyEquivalent: "t")
        statusMenuItem.target = self
        statusMenuItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(withTitle: "隐藏 Ferret", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 Ferret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单：没有它，输入框/日志里的 ⌘C ⌘V ⌘A 都不会生效
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc func onShowStatusMenu() { statusBar?.showMenu() }

    @objc func onShowWindow() {
        presentingWindow = true
        defer { presentingWindow = false; updateDockVisibility() }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateDockVisibility() {
        guard !presentingWindow else { return }
        let visible = window.isVisible && !window.isMiniaturized && !NSApp.isHidden
        let policy: NSApplication.ActivationPolicy = hideDockWhenWindowHidden && !visible ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func applicationDidHide(_ notification: Notification) { updateDockVisibility() }
    func applicationDidUnhide(_ notification: Notification) { updateDockVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateDockVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateDockVisibility() }
    func windowDidBecomeKey(_ notification: Notification) { updateDockVisibility() }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        statusTimer?.invalidate()
        trafficTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        autoSaveSyncPaths()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        autoSaveSyncPaths()
        sender.orderOut(nil)   // 只隐藏窗口，进程继续跑（常驻隧道不受影响）
        updateDockVisibility()
        return false
    }

    func buildStatusBar() {
        let bar = StatusBarController()
        bar.hideDockWhenWindowHidden = hideDockWhenWindowHidden
        bar.onLaunchChatGPT = { [weak self] in self?.onLaunchChatGPT() }
        bar.onShowWindow = { [weak self] in self?.onShowWindow() }
        bar.onToggleDock = { [weak self] in
            guard let self = self else { return }
            self.hideDockWhenWindowHidden.toggle()
            self.statusBar?.hideDockWhenWindowHidden = self.hideDockWhenWindowHidden
            self.updateDockVisibility()
        }
        bar.onMenuOpen = { [weak self] in self?.updateStatusBar(); self?.refreshTraffic() }
        statusBar = bar
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshTraffic() }
        // 菜单展开期间也持续刷新速率。
        RunLoop.main.add(timer, forMode: .common)
        trafficTimer = timer
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)
        refreshTraffic()
    }

    func updateStatusBar() {
        let s = current
        statusBar?.update(serverName: s?.name, health: s.flatMap { tunnelHealth[$0.healthKey] },
                          traffic: s.flatMap { trafficReadings[$0.sshHost] })
    }

    func refreshTraffic() {
        guard !trafficInFlight, !isSleeping else { return }
        trafficInFlight = true
        let hosts = config.servers.map { $0.sshHost }
        let generation = trafficGeneration
        trafficQueue.async { [weak self] in
            guard let self = self else { return }
            let readings = self.trafficSampler.sample(hosts: hosts)
            DispatchQueue.main.async {
                self.trafficInFlight = false
                guard !self.isSleeping, self.trafficGeneration == generation else { return }
                let configured = Set(self.config.servers.map { $0.sshHost })
                self.trafficReadings = readings.filter { configured.contains($0.key) }
                self.updateStatusBar()
            }
        }
    }

    @objc func onSystemSleep() {
        isSleeping = true
        trafficGeneration += 1
        for host in Array(trafficReadings.keys) {
            trafficReadings[host]?.uploadRate = nil
            trafficReadings[host]?.downloadRate = nil
        }
        updateStatusBar()
    }

    @objc func onSystemWake() {
        isSleeping = false
        trafficGeneration += 1
        trafficQueue.async { [weak self] in self?.trafficSampler.resetBaselines() }
        tunnelHealth.removeAll()
        refreshTraffic()
        refreshStatus()
    }
}
