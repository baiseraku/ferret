import Foundation
import Darwin

struct TunnelCounters: Equatable {
    var received: UInt64
    var sent: UInt64
}

enum TunnelConnectionState {
    case stopped, connecting, running, unavailable
}

struct TunnelTrafficPoint {
    var time: TimeInterval
    var upload: Double?
    var download: Double?
}

struct TunnelTraffic {
    var samples: [TunnelTrafficPoint] = []
    var state: TunnelConnectionState = .connecting
    var uploadRate: Double?
    var downloadRate: Double?
    var uploaded: UInt64 = 0
    var downloaded: UInt64 = 0
}

struct TunnelTrafficHistory {
    var traffic = TunnelTraffic()
    private var previous: (pid: Int32, counters: TunnelCounters, time: TimeInterval)?

    mutating func update(state: TunnelConnectionState, pid: Int32? = nil,
                         counters: TunnelCounters? = nil, time: TimeInterval) -> TunnelTraffic {
        traffic.state = state
        traffic.uploadRate = nil
        traffic.downloadRate = nil
        if let pid = pid, let counters = counters {
            if let old = previous, old.pid == pid,
               counters.sent >= old.counters.sent, counters.received >= old.counters.received {
                let sent = counters.sent - old.counters.sent
                let received = counters.received - old.counters.received
                traffic.uploaded += sent
                traffic.downloaded += received
                let elapsed = time - old.time
                // 唤醒或采样长时间中断后只恢复基线，不把整段间隔当作实时速率。
                if elapsed > 0 && elapsed <= 8 {
                    traffic.uploadRate = Double(sent) / elapsed
                    traffic.downloadRate = Double(received) / elapsed
                }
            }
            previous = (pid, counters, time)
        } else {
            previous = nil
        }
        traffic.samples.append(TunnelTrafficPoint(time: time, upload: traffic.uploadRate, download: traffic.downloadRate))
        traffic.samples.removeAll { $0.time < time - 60 }
        return traffic
    }

    mutating func resetBaseline() { previous = nil }
}

// 只运行系统采样工具，不经过 shell，也不接触 SSH 的配置或生命周期。
struct TrafficCommandResult {
    var status: Int32
    var output: String
}

func trafficCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval = 4) -> TrafficCommandResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    try? pipe.fileHandleForWriting.close()
    let expiry = DispatchWorkItem {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: expiry)
    // 边读边排空管道，避免 ps / launchctl 输出填满管道后互相等待。
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    expiry.cancel()
    try? pipe.fileHandleForReading.close()
    return TrafficCommandResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
}

final class TunnelTrafficSampler {
    private var wrappers: [String: (pid: Int32, checkedAt: TimeInterval)] = [:]
    private var histories: [String: TunnelTrafficHistory] = [:]

    static func launchLabel(for host: String) -> String {
        let slug = host.utf8.map { byte -> String in
            let allowed = (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
            return allowed ? String(UnicodeScalar(byte)) : "-"
        }.joined()
        return "local.ferret.tunnel-" + slug
    }

    static func parseCounters(_ csv: String) -> [Int32: TunnelCounters] {
        var receivedIndex: Int?
        var sentIndex: Int?
        var result: [Int32: TunnelCounters] = [:]
        for line in csv.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let received = columns.firstIndex(of: "bytes_in"), let sent = columns.firstIndex(of: "bytes_out") {
                receivedIndex = received
                sentIndex = sent
                continue
            }
            guard let received = receivedIndex, let sent = sentIndex,
                  columns.indices.contains(received), columns.indices.contains(sent),
                  let processName = columns.first(where: { $0.hasPrefix("ssh.") }),
                  let pid = Int32(processName.dropFirst(4)),
                  let bytesIn = UInt64(columns[received]), let bytesOut = UInt64(columns[sent]) else { continue }
            result[pid] = TunnelCounters(received: bytesIn, sent: bytesOut)
        }
        return result
    }

    func resetBaselines() {
        for host in Array(histories.keys) { histories[host]?.resetBaseline() }
        wrappers.removeAll()
    }

    // 由同一串行队列调用；每次把所有已配置隧道一起采样，切换服务器不会串用流量。
    func sample(hosts: [String]) -> [String: TunnelTraffic] {
        let hosts = Set(hosts)
        histories = histories.filter { hosts.contains($0.key) }
        wrappers = wrappers.filter { hosts.contains($0.key) }
        guard !hosts.isEmpty else { return [:] }
        guard let processes = trafficCommand("/bin/ps", ["-axo", "pid=,ppid=,comm="]), processes.status == 0 else {
            return Dictionary(uniqueKeysWithValues: hosts.map { ($0, record($0, state: .unavailable)) })
        }
        var children: [Int32: [Int32]] = [:]
        for line in processes.output.split(whereSeparator: \.isNewline) {
            let columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard columns.count == 3, let pid = Int32(columns[0]), let parent = Int32(columns[1]),
                  (String(columns[2]) as NSString).lastPathComponent == "ssh" else { continue }
            children[parent, default: []].append(pid)
        }

        let now = ProcessInfo.processInfo.systemUptime
        var pids: [String: Int32] = [:]
        var states: [String: TunnelConnectionState] = [:]
        for host in hosts.sorted() {
            var wrapper = wrappers[host]?.pid
            if wrapper == nil || now - (wrappers[host]?.checkedAt ?? 0) >= 10 || children[wrapper ?? -1] == nil {
                let job = trafficCommand("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.launchLabel(for: host))"])
                guard let job = job else { states[host] = .unavailable; continue }
                guard job.status == 0 else {
                    wrappers.removeValue(forKey: host)
                    states[host] = job.status == 113 ? .stopped : .unavailable
                    continue
                }
                wrapper = job.output.split(whereSeparator: \.isNewline).compactMap { line -> Int32? in
                    let parts = line.split(whereSeparator: \.isWhitespace)
                    return parts.count == 3 && parts[0] == "pid" && parts[1] == "=" ? Int32(parts[2]) : nil
                }.first
                if let wrapper = wrapper { wrappers[host] = (wrapper, now) }
                else { wrappers.removeValue(forKey: host) }
            }
            if let wrapper = wrapper, let pid = children[wrapper]?.first {
                pids[host] = pid
            } else {
                states[host] = .connecting
            }
        }

        var counters: [Int32: TunnelCounters] = [:]
        if !pids.isEmpty {
            // 外部接口只计 SSH 线路，排除 ssh 到本机 magpie / Clash 的 loopback，避免重复计数。
            var args = ["-n", "-m", "tcp", "-t", "external", "-x", "-P", "-L", "1", "-J", "bytes_in,bytes_out"]
            for pid in Set(pids.values).sorted() { args += ["-p", String(pid)] }
            if let output = trafficCommand("/usr/bin/nettop", args), output.status == 0 {
                counters = Self.parseCounters(output.output)
            }
        }
        var readings: [String: TunnelTraffic] = [:]
        for host in hosts {
            if let pid = pids[host], let counter = counters[pid] {
                readings[host] = record(host, state: .running, pid: pid, counters: counter)
            } else {
                readings[host] = record(host, state: states[host] ?? .unavailable)
            }
        }
        return readings
    }

    private func record(_ host: String, state: TunnelConnectionState, pid: Int32? = nil,
                        counters: TunnelCounters? = nil) -> TunnelTraffic {
        var history = histories[host] ?? TunnelTrafficHistory()
        let reading = history.update(state: state, pid: pid, counters: counters, time: Date().timeIntervalSinceReferenceDate)
        histories[host] = history
        return reading
    }
}
