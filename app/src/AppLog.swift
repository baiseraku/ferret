import Cocoa

extension AppDelegate {
    func run(_ desc: String, _ cmd: String, timeout: TimeInterval = 120, done: (() -> Void)? = nil) {
        guard !busy else { actionLabel.stringValue = "上一个操作还在进行，请稍候…"; return }
        busy = true
        actionLabel.stringValue = "\(desc)…"
        appendRawHistory("点击：\(desc)")
        DispatchQueue.global().async {
            let (_, out) = shell(cmd, timeout: timeout)
            DispatchQueue.main.async {
                self.busy = false
                self.appendFeedback(out.isEmpty ? "\(desc) 完成" : out, title: desc)
                self.actionLabel.stringValue = out.isEmpty ? "\(desc) 完成" : (out.split(separator: "\n").last.map(String.init) ?? "\(desc) 完成")
                done?()
            }
        }
    }

    func appendFeedback(_ text: String, title: String? = nil) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let stamp = f.string(from: Date())
        if let t = title { feedback.append("[\(stamp)] —— \(t) ——") }
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            feedback.append("[\(stamp)] " + line)
        }
        if feedback.count > 300 { feedback.removeFirst(feedback.count - 300) }
        refreshLog()
    }

    func refreshLog() {
        guard !logInFlight else { return }
        logInFlight = true
        let host = current?.sshHost ?? "my-tunnel"
        let since = sessionSince
        if logView.string.isEmpty { logView.string = "（正在读取本次会话日志…）" }
        // 文件打开也可能阻塞；整个读取过程在后台执行，且只允许一个在途任务。
        DispatchQueue.global(qos: .utility).async {
            var lines: [String] = []
            if let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: ROOT + "/log/tunnel-resident-\(host).log")) {
                defer { try? file.close() }
                let end = (try? file.seekToEnd()) ?? 0
                try? file.seek(toOffset: end > 262144 ? end - 262144 : 0)
                if let data = try? file.readToEnd() {
                    var keep = false
                    for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n").suffix(400) {
                        let stamp = String(line.prefix(19))
                        if stamp.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil {
                            keep = stamp >= since
                        }
                        if keep { lines.append(line) }
                    }
                }
            }
            let text = lines.isEmpty ? "（隧道日志暂无新内容）" : lines.joined(separator: "\n")
            DispatchQueue.main.async {
                self.logInFlight = false
                guard (self.current?.sshHost ?? "my-tunnel") == host else { self.refreshLog(); return }
                var body = "（本次会话日志，\(since) 起；旧日志已隐藏）\n" + text
                if !self.feedback.isEmpty { body += "\n—— 操作反馈（本次会话）——\n" + self.feedback.joined(separator: "\n") }
                self.logView.string = body
                self.logView.scrollToEndOfDocument(nil)
            }
        }
    }
}
