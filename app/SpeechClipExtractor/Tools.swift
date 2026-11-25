import Foundation

enum ToolError: LocalizedError {
    case notFound(String)
    case failed(String, Int32, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "Couldn't find \(name). Install it with Homebrew, or check the paths in Settings."
        case .failed(let name, let status, let tail):
            return "\(name) exited with status \(status).\n\(tail)"
        case .message(let text):
            return text
        }
    }
}

// Finding the command-line tools the skill uses.
enum Tools {
    /*
     * A GUI app doesn't inherit the shell's PATH, so the app searches the
     * usual install folders itself, in this order. mlx_whisper lives in
     * ~/.local/bin on this Mac; yt-dlp may be Homebrew's or Anaconda's.
     */
    static let searchDirs: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        "/opt/anaconda3/bin",
        "/usr/bin",
        "/bin",
    ]

    static func find(_ name: String) -> String? {
        for dir in searchDirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func require(_ name: String) throws -> String {
        guard let path = find(name) else { throw ToolError.notFound(name) }
        return path
    }

    // The environment every child process gets: the search folders on PATH, so yt-dlp and mlx_whisper can find ffmpeg.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }
}

/*
 * Splits a child process's output into lines. A line ending in "\r" is a
 * progress-bar redraw (tqdm, yt-dlp, ffmpeg), so it's reported as progress
 * rather than as a new log line. The lock is needed because the pipe's
 * reader and the termination handler run on different threads.
 */
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private var recent: [String] = []
    private let lock = NSLock()
    private let onLine: (String, Bool) -> Void

    init(onLine: @escaping (String, Bool) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        // Emit every complete line (ended by \n or \r) and keep the remainder.
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let isProgress = pending[index] == 0x0D
            let lineData = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            emit(lineData, isProgress: isProgress)
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            emit(pending, isProgress: false)
            pending.removeAll()
        }
    }

    // The last lines of output, for error messages.
    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return recent.suffix(12).joined(separator: "\n")
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recent
    }

    private func emit(_ data: Data, isProgress: Bool) {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if !isProgress {
            recent.append(line)
            if recent.count > 400 { recent.removeFirst(recent.count - 400) }
        }
        onLine(line, isProgress)
    }
}

enum ProcessRunner {
    /*
     * Runs a tool and waits for it, streaming its output (stdout and stderr
     * merged) to onLine. Cancelling the Swift task terminates the process.
     * Returns the exit status and the buffer holding the output.
     */
    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        onLine: @escaping (String, Bool) -> Void
    ) async throws -> (status: Int32, output: LineBuffer) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Tools.environment
        if let cwd { process.currentDirectoryURL = cwd }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let buffer = LineBuffer(onLine: onLine)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(data)
            }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    // Stop the live reader, then drain whatever is still in the pipe.
                    reader.readabilityHandler = nil
                    buffer.append(reader.readDataToEndOfFile())
                    buffer.flush()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    reader.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled { throw CancellationError() }
        return (status, buffer)
    }
}
