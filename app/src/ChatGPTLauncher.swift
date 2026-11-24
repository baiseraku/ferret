import Cocoa

extension AppDelegate {
    func portOpen(_ port: Int) -> Bool {
        shell("/usr/bin/nc -z -G 2 127.0.0.1 \(port)").0 == 0
    }

    func chatGPTPid() -> String {
        shell("/usr/bin/pgrep -f 'ChatGPT.app/Contents/MacOS/ChatGPT' | head -1").1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "好"); a.runModal()
    }

    func openChatGPT() -> String {
        var cmd = "/usr/bin/open"
        for (name, value) in LOCAL_PROXY_ENV {
            cmd += " --env '\(name)=\(value)'"
        }
        cmd += " --env 'NODE_USE_ENV_PROXY=1'"
        cmd += " -a '" + CHATGPT_APP + "'"
        cmd += " --args '--proxy-server=" + LOCAL_PROXY + "' '--proxy-bypass-list=localhost;127.0.0.1;[::1]'"
        let (rc, out) = shell(cmd, timeout: 30)
        return rc == 0 ? "" : out
    }

    @objc func onToggleCodexCLIProxy(_ sender: NSSwitch) {
        let proxy = CodexCLIProxy.currentUser
        let enabled = sender.state == .on
        do {
            try proxy.setEnabled(enabled)
            actionLabel.stringValue = enabled
                ? "CLI 代理已开启，首次开启请重新打开终端。"
                : "CLI 代理已关闭，终端启动设置已复原。"
        } catch {
            sender.state = proxy.isEnabled ? .on : .off
            showAlert("CLI 代理设置失败", error.localizedDescription)
        }
    }

    @objc func onLaunchChatGPT() {
        appendRawHistory("点击：启动 ChatGPT（代理模式）")
        actionLabel.stringValue = "检查 Clash / magpie…"
        busy = true
        DispatchQueue.global().async {
            if !self.portOpen(LOCAL_PROXY_PORT) {
                DispatchQueue.main.async {
                    self.busy = false
                    self.showAlert("Clash 7897 未运行", "请先打开 Clash Verge，确认 127.0.0.1:7897 可用，再点此按钮。")
                }
                return
            }
            if !self.portOpen(LOCAL_MAGPIE_PORT) {
                _ = shell("/usr/bin/open -g -a '" + MAGPIE_APP + "'")
                var waited = 0.0
                while waited < 10.0 && !self.portOpen(LOCAL_MAGPIE_PORT) { usleep(300_000); waited += 0.3 }
                if !self.portOpen(LOCAL_MAGPIE_PORT) {
                    DispatchQueue.main.async {
                        self.busy = false
                        self.showAlert("magpie 3425 未就绪", "请先打开 magpie（Dock 或 /Applications/magpie.app），再重试。")
                    }
                    return
                }
            }
            let pid = self.chatGPTPid()
            var proxied = false
            if !pid.isEmpty {
                let ps = shell("/bin/ps -o command= -p \(pid)").1
                proxied = ps.contains("--proxy-server=" + LOCAL_PROXY)
            }
            DispatchQueue.main.async {
                if proxied {
                    _ = shell("/usr/bin/open -a '" + CHATGPT_APP + "'")
                    self.busy = false
                    self.actionLabel.stringValue = "ChatGPT 已在代理模式运行，已切到前台"
                    self.appendFeedback("ChatGPT 已在代理模式运行，已切到前台", title: "启动 ChatGPT")
                    appendRawHistory("启动 ChatGPT（已在代理模式）")
                    return
                }
                if !pid.isEmpty {
                    self.actionLabel.stringValue = "正在退出 ChatGPT…"
                    _ = shell("/usr/bin/osascript -e 'tell application id \"com.openai.codex\" to quit'", timeout: 20)
                    var waited = 0.0
                    while waited < 15.0 && !self.chatGPTPid().isEmpty { sleep(1); waited += 1 }
                }
                let err = self.openChatGPT()
                self.busy = false
                if err.isEmpty {
                    self.actionLabel.stringValue = "已按代理模式启动 ChatGPT（Clash 7897 + magpie 3425）"
                    self.appendFeedback(err, title: "启动 ChatGPT")
                    appendRawHistory("启动 ChatGPT（代理模式）")
                } else {
                    self.actionLabel.stringValue = "启动失败：\(err)"
                    self.showAlert("ChatGPT 启动失败", err)
                }
            }
        }
    }
}
