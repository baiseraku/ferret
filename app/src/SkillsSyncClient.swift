import Foundation

struct SkillsComparison: Decodable {
    let localCount: Int
    let remoteCount: Int
    let skills: [ComparedSkill]
}

enum SkillDifference: String, Decodable {
    case same, different, localOnly, remoteOnly, unavailable

    var label: String {
        switch self {
        case .same: return "一致"
        case .different: return "内容不同"
        case .localOnly: return "仅本机"
        case .remoteOnly: return "仅服务器"
        case .unavailable: return "读取失败"
        }
    }
}

struct ComparedSkill: Decodable {
    let name: String
    let local: Side?
    let remote: Side?
    let changes: [FileChange]

    struct Side: Decodable {
        let revision: String?
        let version: String?
        let error: String?

        var versionLabel: String {
            guard let revision else { return "读取失败" }
            return "\(version.map { "版本 \($0)" } ?? "未标版本") · \(revision.prefix(8))"
        }
    }

    struct FileChange: Decodable {
        let path: String
        let status: SkillDifference
    }

    var difference: SkillDifference {
        if local?.error != nil || remote?.error != nil { return .unavailable }
        if remote == nil { return .localOnly }
        if local == nil { return .remoteOnly }
        return local?.revision == remote?.revision ? .same : .different
    }
}

struct SkillDiffPreview: Decodable {
    let text: String
}

struct SkillUpdateResult: Decodable {
    let backup: String?
}

struct SkillsSyncClient {
    let host: String
    let localPath: String
    let remotePath: String

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func request<Response: Decodable & Sendable>(_ type: Response.Type, _ arguments: [String],
                                                 completion: @escaping (Result<Response, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.run(Response.self, arguments: arguments) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func run<Response: Decodable>(_ type: Response.Type, arguments: [String]) throws -> Response {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = URL(fileURLWithPath: ROOT, isDirectory: true)
        process.arguments = ["python3", "-B", ROOT + "/scripts/skills_sync.py",
                             "--host=" + host, "--local=" + localPath, "--remote=" + remotePath] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "Skills 操作失败，请重试。" : detail)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Failure(message: "无法读取 Skills 操作结果，请刷新对比。")
        }
    }
}
