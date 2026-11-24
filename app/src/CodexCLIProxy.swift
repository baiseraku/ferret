import Foundation

struct CodexCLIProxy {
    static let currentUser = CodexCLIProxy(
        startupFile: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    )
    private static let beginMarker = "# >>> Ferret Codex CLI proxy >>>"
    private static let endMarker = "# <<< Ferret Codex CLI proxy <<<"

    let startupFile: URL

    var isEnabled: Bool {
        guard let contents = try? Data(contentsOf: startupFile) else { return false }
        return Self.blockStart(in: contents) != nil
    }

    func setEnabled(_ enabled: Bool) throws {
        let file = startupFile.resolvingSymlinksInPath()
        let original: Data?
        do {
            original = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            original = nil
        }
        let contents = original ?? Data()

        if let start = Self.blockStart(in: contents) {
            guard let end = contents.range(of: Data("\n\(Self.endMarker)\n".utf8),
                                           in: start..<contents.endIndex) else {
                throw StartupFileError.incompleteBlock
            }
            if enabled { return }

            var restored = Data(contents[..<start])
            let following = contents[end.upperBound...]
            if let last = restored.last, let first = following.first, last != 10, first != 10 {
                restored.append(10)
            }
            restored.append(contentsOf: following)
            let createdFile = start == 0 && contents.first != 10
            if createdFile && restored.isEmpty {
                try FileManager.default.removeItem(at: file)
            } else {
                try restored.write(to: file, options: .atomic)
            }
        } else if enabled {
            var updated = contents
            // 额外换行属于 Ferret 的配置段，以便关闭时按原样还原已有文件。
            if original != nil { updated.append(10) }
            updated.append(contentsOf: Self.shellBlock.utf8)
            try updated.write(to: file, options: .atomic)
        }
    }

    private static func blockStart(in contents: Data) -> Data.Index? {
        let marker = Data("\(beginMarker)\n".utf8)
        if contents.starts(with: marker) { return contents.startIndex }
        return contents.range(of: Data([10]) + marker)?.lowerBound
    }

    private static var shellBlock: String {
        let environment = LOCAL_PROXY_ENV.map { "\($0.name)='\($0.value)'" }.joined(separator: " ")
        return """
        \(beginMarker)
        function codex {
            if /usr/bin/grep -Fqx '\(beginMarker)' "$HOME/.zshrc" 2>/dev/null; then
                \(environment) command codex "$@"
            else
                command codex "$@"
            fi
        }
        \(endMarker)

        """
    }

    private enum StartupFileError: LocalizedError {
        case incompleteBlock

        var errorDescription: String? {
            "检测到不完整的 Ferret CLI 代理配置段，请检查 .zshrc。"
        }
    }
}
