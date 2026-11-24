import Cocoa

import Darwin

let ROOT = ProcessInfo.processInfo.environment["FERRET_ROOT"]
    ?? (NSHomeDirectory() + "/Documents/DSH/ferret")
let SSH_CONFIG = NSHomeDirectory() + "/.ssh/config"
let SUPPORT = NSHomeDirectory() + "/Library/Application Support/Ferret"
let CONFIG_FILE = SUPPORT + "/config.json"
let HISTORY_FILE = ROOT + "/log/history.log"
let CHATGPT_APP = "/Applications/ChatGPT.app"
let MAGPIE_APP = "/Applications/magpie.app"
let LOCAL_PROXY = "http://127.0.0.1:7897"
let LOCAL_PROXY_PORT = 7897
let LOCAL_MAGPIE_PORT = 3425
let LOCAL_PROXY_ENV: [(name: String, value: String)] =
    ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"].map { ($0, LOCAL_PROXY) }
    + ["NO_PROXY", "no_proxy"].map { ($0, "localhost,127.0.0.1,::1") }

// 日志保留最近 N 天：更早的整文件删除，活跃文件里更早的行裁掉
func cleanupOldLogs(days: Int = 7) -> (removed: Int, trimmed: Int) {
    let fm = FileManager.default
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let cutoff = df.string(from: cutoffDate)

    func trimLines(_ path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var changed = false
        for line in lines {
            let prefix = String(line.prefix(10))
            if prefix.count == 10, prefix.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil {
                if prefix < cutoff { changed = true; continue }
            }
            kept.append(line)
        }
        if changed { try? kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        return changed ? 1 : 0
    }

    var removed = 0, trimmed = 0
    let logDir = ROOT + "/log"
    if let files = try? fm.contentsOfDirectory(atPath: logDir) {
        for name in files where name.hasSuffix(".log") || name.hasSuffix(".out") || name.hasSuffix(".err") {
            let path = logDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date, mtime < cutoffDate {
                try? fm.removeItem(atPath: path); removed += 1
            } else {
                trimmed += trimLines(path)
            }
        }
    }
    let launcherLog = NSHomeDirectory() + "/Library/Logs/CodexProxyLauncher.log"
    if let attrs = try? fm.attributesOfItem(atPath: launcherLog),
       let mtime = attrs[.modificationDate] as? Date, mtime < cutoffDate {
        try? fm.removeItem(atPath: launcherLog); removed += 1
    } else if fm.fileExists(atPath: launcherLog) {
        trimmed += trimLines(launcherLog)
    }
    return (removed, trimmed)
}

func shell(_ command: String, timeout: TimeInterval = 120) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-lc", command]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "启动失败: \(error)") }
    // 父进程关闭写端，否则子进程退出后也拿不到 EOF
    out.fileHandleForWriting.closeFile()

    let limit = max(1, timeout)
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { usleep(50_000) }

    var timedOut = false
    if p.isRunning {
        timedOut = true
        p.terminate()
        let grace = Date().addingTimeInterval(2)
        while p.isRunning && Date() < grace { usleep(50_000) }
        if p.isRunning {
            kill(-p.processIdentifier, SIGKILL)   // 连同子进程（ssh 等）一起结束
            kill(p.processIdentifier, SIGKILL)
            let hard = Date().addingTimeInterval(2)
            while p.isRunning && Date() < hard { usleep(50_000) }
        }
    }

    // 非阻塞读，避免残留子进程握住管道导致永久卡死
    let fd = out.fileHandleForReading.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var data = Data()
    let readDeadline = Date().addingTimeInterval(3)
    var buf = [UInt8](repeating: 0, count: 65536)
    while Date() < readDeadline {
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            data.append(buf, count: n)
        } else if n == 0 {
            break
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            break
        } else {
            usleep(20_000)
        }
    }
    try? out.fileHandleForReading.close()

    // 只有确认已退出才读 terminationStatus：否则 NSConcreteTask 会抛 ObjC 异常，整个 app abort
    var status: Int32 = -1
    if !p.isRunning {
        status = p.terminationStatus
    }
    let text = (String(data: data, encoding: .utf8) ?? "") + (timedOut ? "\n(shell 超时 \(Int(limit))s，已终止)" : "")
    return (status, text)
}

func appendRawHistory(_ action: String) {
    try? FileManager.default.createDirectory(atPath: ROOT + "/log", withIntermediateDirectories: true)
    let line = ISO8601DateFormatter().string(from: Date()) + " | " + action + "\n"
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: HISTORY_FILE) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? line.write(toFile: HISTORY_FILE, atomically: true, encoding: .utf8) }
    }
}

func appendHistory(_ action: String, _ s: SavedServer) {
    try? FileManager.default.createDirectory(atPath: ROOT + "/log", withIntermediateDirectories: true)
    let line = String(format: "%@ | %@ | %@ (%@ → %@)\n", ISO8601DateFormatter().string(from: Date()), action, s.name, s.sshHost, s.probeHost)
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: HISTORY_FILE) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? line.write(toFile: HISTORY_FILE, atomically: true, encoding: .utf8) }
    }
}
