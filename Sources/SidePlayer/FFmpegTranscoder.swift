import Foundation

enum FFmpegTranscoder {
    enum Error: LocalizedError {
        case missingExecutable
        case conversionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .missingExecutable: "未找到 FFmpeg。请安装 FFmpeg，或将 Universal 2 版 ffmpeg 放入 side-player.app/Contents/Frameworks。"
            case .conversionFailed(let code): "FFmpeg 解码失败（退出码 \(code)）。"
            }
        }
    }

    static func transcodeToWAV(_ source: URL) throws -> URL {
        guard let executable = findExecutable() else { throw Error.missingExecutable }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("side-player-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-nostdin", "-v", "error", "-y", "-i", source.path, "-vn", "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw Error.missingExecutable }
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else {
            try? FileManager.default.removeItem(at: destination)
            throw Error.conversionFailed(process.terminationStatus)
        }
        return destination
    }

    private static func findExecutable() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        for entry in pathEntries {
            let path = URL(fileURLWithPath: String(entry)).appendingPathComponent("ffmpeg").path
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
