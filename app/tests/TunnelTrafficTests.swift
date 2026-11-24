import Foundation

@main
struct TunnelTrafficTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: " + message) }
    }

    static func main() {
        let csv = """
        time,,bytes_in,bytes_out,
        12:00:00.000000,ssh.101,2000,1000,
        12:00:00.000000,ssh.102,40,80,
        12:00:00.000000,other.103,900,900,
        12:00:00.000000,ssh.104,,99,
        12:00:00.000000,ssh.105,-1,99,
        time,,bytes_in,bytes_out,
        12:00:02.000000,ssh.101,2400,1200,
        """
        let counters = TunnelTrafficSampler.parseCounters(csv)
        expect(counters.count == 2, "ignore unrelated processes and invalid counters")
        expect(counters[101] == TunnelCounters(received: 2400, sent: 1200), "last snapshot wins")
        expect(counters[102] == TunnelCounters(received: 40, sent: 80), "keep servers separate")
        let reordered = TunnelTrafficSampler.parseCounters(",bytes_out,bytes_in,\nssh.101,12,34,\n")
        expect(reordered[101] == TunnelCounters(received: 34, sent: 12), "map CSV columns by heading")
        expect(TunnelTrafficSampler.parseCounters("garbage\n").isEmpty, "missing header is unavailable")
        expect(TunnelTrafficSampler.launchLabel(for: "lab_key.example") == "local.ferret.tunnel-lab-key-example", "match resident.sh label escaping")

        var history = TunnelTrafficHistory()
        var value = history.update(state: .running, pid: 101, counters: .init(received: 2000, sent: 1000), time: 10)
        expect(value.uploadRate == nil && value.uploaded == 0, "existing SSH traffic is not counted at app startup")
        value = history.update(state: .running, pid: 101, counters: .init(received: 2600, sent: 1200), time: 12)
        expect(value.uploadRate == 100 && value.downloadRate == 300, "Mac upload/download directions and elapsed time")
        expect(value.uploaded == 200 && value.downloaded == 600, "accumulate observed deltas")
        value = history.update(state: .running, pid: 101, counters: .init(received: 2600, sent: 1200), time: 14)
        expect(value.uploadRate == 0 && value.downloadRate == 0, "idle is zero, not unavailable")
        value = history.update(state: .running, pid: 202, counters: .init(received: 50, sent: 30), time: 16)
        expect(value.uploadRate == nil && value.uploaded == 200, "PID change resets rate without losing total")
        value = history.update(state: .running, pid: 202, counters: .init(received: 70, sent: 90), time: 18)
        expect(value.uploadRate == 30 && value.downloadRate == 10 && value.uploaded == 260, "resume after SSH reconnect")
        value = history.update(state: .running, pid: 202, counters: .init(received: 1, sent: 1), time: 20)
        expect(value.uploadRate == nil && value.uploaded == 260, "counter reset does not underflow")
        value = history.update(state: .unavailable, time: 22)
        expect(value.uploadRate == nil && value.uploaded == 260, "sampling failure preserves totals and shows no rate")
        value = history.update(state: .running, pid: 202, counters: .init(received: 10000, sent: 10000), time: 24)
        expect(value.uploadRate == nil && value.uploaded == 260, "recovery establishes a new baseline")
        history.resetBaseline()
        value = history.update(state: .running, pid: 202, counters: .init(received: 20000, sent: 20000), time: 2000)
        expect(value.uploadRate == nil && value.uploaded == 260, "wake does not report sleep interval as a rate")
        value = history.update(state: .running, pid: 202, counters: .init(received: 20010, sent: 20040), time: 2020)
        expect(value.uploadRate == nil && value.uploaded == 300, "long gaps retain bytes but suppress stale rates")
        value = history.update(state: .stopped, time: 2022)
        expect(value.state == .stopped && value.uploadRate == nil && value.uploaded == 300, "stopped state retains observed total")

        var rolling = TunnelTrafficHistory()
        for time in stride(from: 0.0, through: 120.0, by: 1.0) {
            _ = rolling.update(state: .running, pid: 1,
                               counters: .init(received: UInt64(time * 200), sent: UInt64(time * 100)), time: time)
        }
        expect(rolling.traffic.samples.count == 61, "chart retains one minute at one-second intervals")
        expect(rolling.traffic.samples.first?.time == 60 && rolling.traffic.samples.last?.time == 120, "chart evicts older timestamps")
        let gap = rolling.update(state: .unavailable, time: 122)
        expect(gap.samples.last?.upload == nil && gap.samples.last?.download == nil, "chart records gaps rather than fake zero traffic")
        _ = rolling.update(state: .running, pid: 1, counters: .init(received: 30000, sent: 15000), time: 300)
        expect(rolling.traffic.samples.count == 1 && rolling.traffic.samples.last?.upload == nil, "chart clears pre-sleep data after a long gap")

        let positions: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 1000),
                                    CGPoint(x: 2.2, y: 1), CGPoint(x: 5, y: 1), CGPoint(x: 7, y: 800), CGPoint(x: 10, y: 0)]
        let segments = TrafficCurve.segments(through: positions)
        expect(segments.count == positions.count - 1 && zip(segments, positions.dropFirst()).allSatisfy {
            $0.end.x == $1.x && $0.end.y == $1.y
        }, "smooth curve passes through the actual samples")
        var withinBounds = true
        for (i, segment) in segments.enumerated() {
            let start = positions[i]
            for step in 0...100 {
                let t = CGFloat(step) / 100, u = 1 - t
                let y = u * u * u * start.y + 3 * u * u * t * segment.control1.y
                    + 3 * u * t * t * segment.control2.y + t * t * t * segment.end.y
                withinBounds = withinBounds && y >= min(start.y, segment.end.y) - 0.000001
                    && y <= max(start.y, segment.end.y) + 0.000001
            }
        }
        expect(withinBounds, "smooth curve never invents negative traffic or overshoots a measured peak")
        expect(TrafficCurve.segments(through: []).isEmpty, "empty curve has no segments")
        expect(TrafficCurve.segments(through: [CGPoint(x: 1, y: 3)]).isEmpty, "single sample has no invented curve")
        expect(TrafficCurve.segments(through: [CGPoint(x: 1, y: 3), CGPoint(x: 1, y: 4)]).isEmpty, "duplicate timestamps cannot divide by zero")

        let sampler = TunnelTrafficSampler()
        let stopped = sampler.sample(hosts: ["nonexistent-ferret-traffic-test"])
        expect(stopped["nonexistent-ferret-traffic-test"]?.state == .stopped, "real launchctl distinguishes unloaded jobs")
        expect(sampler.sample(hosts: []).isEmpty, "empty server list")
        let failure = trafficCommand("/usr/bin/false", [])
        expect(failure?.status != 0, "command errors remain errors")
        let timed = Date()
        let timeout = trafficCommand("/bin/sleep", ["10"], timeout: 0.1)
        expect(timeout?.status != 0 && Date().timeIntervalSince(timed) < 3, "sampling commands have a bounded lifetime")
        print("PASS: \(checks) traffic checks")

        if CommandLine.arguments.contains("--live") {
            let configURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Ferret/config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = config["servers"] as? [[String: Any]] else { fatalError("live config unavailable") }
            let hosts = servers.compactMap { $0["sshHost"] as? String }
            let live = TunnelTrafficSampler()
            let first = live.sample(hosts: hosts)
            let running = first.filter { $0.value.state == .running }.map(\.key)
            expect(!running.isEmpty, "live SSH sample available")
            Thread.sleep(forTimeInterval: 2)
            let second = live.sample(hosts: hosts)
            for host in running {
                expect(second[host]?.uploadRate != nil && second[host]?.downloadRate != nil, "live consecutive samples produce rates")
            }
            print("PASS: live external-interface samples for \(running.count) running tunnel(s); no SSH lifecycle changes")
        }
    }
}
