import AppKit
import AVFoundation
import Foundation

struct Track: Identifiable, Equatable, Codable, Sendable {
    private(set) var id = UUID()
    let url: URL?
    let netEaseID: String?
    let artist: String
    let title: String
    let year: String?
    var duration: TimeInterval = 0

    init(netEase song: NetEaseSong) {
        url = nil
        netEaseID = song.id
        artist = song.artist
        title = song.title
        year = song.year
        duration = song.duration
    }

    init(url: URL) {
        self.url = url
        netEaseID = nil
        let stem = url.deletingPathExtension().lastPathComponent
        let pieces = stem.components(separatedBy: " - ")
        let ncmMetadata = url.pathExtension.lowercased() == "ncm" ? NCMDecoder.readMetadata(url: url) : nil
        let asset = AVURLAsset(url: url)
        let metadata = asset.commonMetadata
        let taggedArtist = ncmMetadata?.artist ?? metadata.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue
        let taggedTitle = ncmMetadata?.title ?? metadata.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue
        let rawYear = metadata.first(where: { $0.commonKey == .commonKeyCreationDate })?.stringValue
        year = rawYear.flatMap { String($0.prefix(4)).range(of: "^\\d{4}$", options: .regularExpression) == nil ? nil : String($0.prefix(4)) }
        if let taggedArtist, !taggedArtist.isEmpty {
            artist = taggedArtist.components(separatedBy: CharacterSet(charactersIn: ",;/&、，")).first?.trimmingCharacters(in: .whitespaces) ?? taggedArtist
        } else if pieces.count > 1 {
            artist = pieces[0].trimmingCharacters(in: .whitespaces)
        } else {
            artist = "未知歌手"
        }
        if let taggedTitle, !taggedTitle.isEmpty {
            title = taggedTitle
        } else if pieces.count > 1 {
            title = pieces.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        } else {
            title = stem
        }
    }
}

private struct SongCache: Codable {
    let scope: [String]
    let tracks: [Track]

    static func read(_ name: String, scope: [String]) -> [Track] {
        guard let data = try? Data(contentsOf: url(name)),
              let cache = try? JSONDecoder().decode(Self.self, from: data),
              cache.scope == scope else { return [] }
        return cache.tracks
    }

    static func write(_ name: String, scope: [String], tracks: [Track]) {
        let path = url(name)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Self(scope: scope, tracks: tracks)) {
            try? data.write(to: path, options: .atomic)
        }
    }

    private static func url(_ name: String) -> URL {
        URL.cachesDirectory.appending(path: "com.zhengxinshushe.side-player/\(name)-songs.json")
    }
}

@MainActor
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = PlayerModel()
    @Published var tracks: [Track] = []
    @Published var currentIndex = 0
    @Published var isPlaying = false
    @Published private var lyrics: [LyricLine] = []
    private var lyricsRequest: Task<Void, Never>?

    var currentLyric: String {
        lyrics.last { $0.time <= currentTime }?.text ?? ""
    }

    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoading = false
    private static var defaultMusicFolder: URL {
        URL.musicDirectory.appending(path: "Music/Media.localized", directoryHint: .isDirectory)
    }

    @Published var musicFolder = UserDefaults.standard.string(forKey: "musicFolder")
        .flatMap { $0.isEmpty ? nil : $0 } ?? PlayerModel.defaultMusicFolder.path
    @Published var selectedPositionLocal = UserDefaults.standard.object(forKey: "sourceLocal") as? Bool ?? true
    @Published var selectedPositionNetEase = UserDefaults.standard.object(forKey: "sourceNetEase") as? Bool ?? true
    @Published var sortRandom = UserDefaults.standard.bool(forKey: "randomSort")
    @Published var playbackError: String?

    private var audioPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var ffmpegEngine: AVAudioEngine?
    private var ffmpegPlayer: AVAudioPlayerNode?
    private var ffmpegFile: AVAudioFile?
    private var ffmpegTemporaryURL: URL?
    private var ffmpegSeekBase: TimeInterval = 0
    private var streamEndObserver: NSObjectProtocol?
    private var streamStatusObserver: NSKeyValueObservation?
    private var streamRequest: Task<Void, Never>?
    private var downloadedStreamURL: URL?
    private var timer: Timer?
    private var decodedTemporaryURL: URL?
    private var activeRequest = UUID()
    private var cloudRefresh: Task<Void, Never>?
    private var localRefresh: Task<Void, Never>?
    private var localScope: [String]?
    private var cloudScope: [String]?
    private var localTracks: [Track] = []
    private var netEaseTracks: [Track] = []
    private let extensions = Set(["mp3", "m4a", "aac", "alac", "wav", "aiff", "aif", "flac", "ape", "wv", "ogg", "opus", "ncm"])
    var currentTrack: Track? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        panel.directoryURL = URL(fileURLWithPath: musicFolder, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        musicFolder = url.path
        UserDefaults.standard.set(url.path, forKey: "musicFolder")
        refreshSongs()
    }

    func restoreSongLists() {
        localScope = [musicFolder]
        if selectedPositionLocal { localTracks = SongCache.read("local", scope: [musicFolder]) }
        let client = NetEaseClient.shared
        if selectedPositionNetEase, let scope = selectedCloudScope(client) {
            cloudScope = scope
            netEaseTracks = SongCache.read("netease", scope: scope)
        }
        rebuildQueue()
    }

    func refreshSongs() {
        localRefresh?.cancel()
        guard selectedPositionLocal, !musicFolder.isEmpty else {
            rebuildQueue()
            return
        }
        let scope = [musicFolder]
        if localScope != scope {
            localScope = scope
            localTracks = SongCache.read("local", scope: scope)
            rebuildQueue()
        }
        let folder = URL(fileURLWithPath: musicFolder, isDirectory: true)
        let acceptedExtensions = extensions
        let existing = Dictionary(localTracks.compactMap { track in track.url.map { ($0, track) } }, uniquingKeysWith: { first, _ in first })
        let scan = Task.detached(priority: .utility) { () -> [Track]? in
            var failed = false
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return false }) else { return nil }
            var tracks: [Track] = []
            for case let url as URL in files {
                if Task.isCancelled { return nil }
                guard acceptedExtensions.contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                tracks.append(existing[url] ?? Track(url: url))
            }
            return failed ? nil : tracks
        }
        localRefresh = Task {
            let scanned = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled, let scanned else { return }
            localTracks = scanned
            SongCache.write("local", scope: scope, tracks: scanned)
            rebuildQueue()
        }
    }

    private func selectedCloudScope(_ client: NetEaseClient) -> [String]? {
        let ids = Set(UserDefaults.standard.stringArray(forKey: "selectedNetEasePlaylists") ?? [])
        guard !ids.isEmpty, let account = client.playlistCacheScope else { return nil }
        return [account] + ids.sorted()
    }

    func refreshSelectedSources() {
        refreshSongs()
        refreshNetEaseSource()
    }

    func refreshNetEaseSource() {
        cloudRefresh?.cancel()
        let client = NetEaseClient.shared
        guard selectedPositionNetEase, let scope = selectedCloudScope(client) else {
            cloudScope = nil
            setNetEaseSongs([])
            return
        }
        if cloudScope != scope {
            cloudScope = scope
            netEaseTracks = SongCache.read("netease", scope: scope)
            rebuildQueue()
        }
        let ids = Set(scope.dropFirst())
        cloudRefresh = Task {
            do {
                let songs = try await client.loadSongs(playlistIDs: ids)
                try Task.checkCancellation()
                if selectedCloudScope(client) == scope {
                    client.reportError(nil)
                    setNetEaseSongs(songs)
                    SongCache.write("netease", scope: scope, tracks: netEaseTracks)
                }
            } catch {
                if !Task.isCancelled { client.reportError("读取选中歌单失败：\(error.localizedDescription)") }
            }
        }
    }

    func sortTracks() {
        if sortRandom { tracks.shuffle() }
        else { tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    }

    func setSources(local: Bool? = nil, netEase: Bool? = nil) {
        if let local { selectedPositionLocal = local }
        if let netEase { selectedPositionNetEase = netEase }
        rebuildQueue()
    }

    func setNetEaseSongs(_ songs: [NetEaseSong]) {
        var seen = Set<String>()
        let existing = Dictionary(uniqueKeysWithValues: netEaseTracks.compactMap { track in track.netEaseID.map { ($0, track) } })
        netEaseTracks = songs.filter { seen.insert($0.id).inserted }.map { existing[$0.id] ?? Track(netEase: $0) }
        rebuildQueue()
    }

    private func rebuildQueue() {
        let selectedID = currentTrack?.id
        var combined = (selectedPositionLocal ? localTracks : []) + (selectedPositionNetEase ? netEaseTracks : [])
        if sortRandom { combined.shuffle() }
        else { combined.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        tracks = combined
        if let selectedID, let newIndex = tracks.firstIndex(where: { $0.id == selectedID }) {
            currentIndex = newIndex
        } else {
            if selectedID != nil { stop() }
            currentIndex = min(currentIndex, max(0, tracks.count - 1))
            if tracks.isEmpty { stop() }
        }
    }

    func playPause() {
        guard !tracks.isEmpty else { return }
        guard !isLoading else { return }
        if isPlaying { audioPlayer?.pause(); streamPlayer?.pause(); ffmpegPlayer?.pause(); isPlaying = false; timer?.invalidate() }
        else if audioPlayer != nil || streamPlayer != nil || ffmpegPlayer != nil { audioPlayer?.play(); streamPlayer?.play(); ffmpegPlayer?.play(); isPlaying = true; startTimer() }
        else { play(index: currentIndex) }
    }

    func play(index: Int) {
        guard tracks.indices.contains(index) else { return }
        clearCurrentAudio()
        currentIndex = index
        let request = UUID()
        activeRequest = request
        let track = tracks[index]
        currentTime = 0
        playbackError = nil
        loadLyrics(for: track, request: request)
        if let songID = track.netEaseID {
            isLoading = true
            let downloadFolder = URL(fileURLWithPath: musicFolder, isDirectory: true)
            streamRequest = Task {
                do {
                    let stream = try await NetEaseClient.shared.streamURL(for: songID)
                    guard !Task.isCancelled, activeRequest == request else { return }
                    startStream(at: stream, expectedDuration: track.duration, request: request, downloadFolder: downloadFolder)
                } catch {
                    guard !Task.isCancelled, activeRequest == request else { return }
                    isLoading = false
                    playbackError = error.localizedDescription
                }
            }
            return
        }
        guard let url = track.url else { return }
        if url.pathExtension.lowercased() == "ncm" {
            isLoading = true
            Task {
                do {
                    let decodedURL = try await Task.detached(priority: .userInitiated) { try NCMDecoder.decode(url: url) }.value
                    guard activeRequest == request else {
                        try? FileManager.default.removeItem(at: decodedURL)
                        return
                    }
                    decodedTemporaryURL = decodedURL
                    do { try startAudio(at: decodedURL) }
                    catch { await startFFmpeg(at: decodedURL, request: request) }
                } catch {
                    guard activeRequest == request else { return }
                    isLoading = false
                    if let decodedTemporaryURL { try? FileManager.default.removeItem(at: decodedTemporaryURL) }
                    decodedTemporaryURL = nil
                    playbackError = "NCM 文件无法解密或解码。\n\n\(error.localizedDescription)\n\n\(url.lastPathComponent)"
                }
            }
        } else {
            do { try startAudio(at: url) }
            catch {
                isLoading = true
                Task { guard activeRequest == request else { return }; await startFFmpeg(at: url, request: request) }
            }
        }
    }

    private func loadLyrics(for track: Track, request: UUID) {
        lyricsRequest = Task {
            let source: String?
            if let songID = track.netEaseID {
                source = try? await NetEaseClient.shared.lyrics(for: songID)
            } else if let url = track.url {
                let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
                source = await Task.detached {
                    try? String(contentsOf: lrc, encoding: .utf8)
                }.value
            } else {
                source = nil
            }
            guard !Task.isCancelled, activeRequest == request else { return }
            lyrics = source.map(LyricLine.parse) ?? []
        }
    }

    func next() { guard !tracks.isEmpty else { return }; play(index: (currentIndex + 1) % tracks.count) }
    func previous() { guard !tracks.isEmpty else { return }; play(index: (currentIndex - 1 + tracks.count) % tracks.count) }
    func seek(to value: Double) {
        let target = min(max(value, 0), duration)
        currentTime = target
        audioPlayer?.currentTime = target
        streamPlayer?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        if ffmpegPlayer != nil {
            scheduleFFmpegAudio(startingAt: target)
            if isPlaying { ffmpegPlayer?.play() }
        }
    }
    func stop() { activeRequest = UUID(); clearCurrentAudio(); currentTime = 0 }

    private func startAudio(at url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { throw CocoaError(.fileReadCorruptFile) }
        audioPlayer = player
        duration = player.duration
        currentTime = 0
        isLoading = false
        isPlaying = true
        startTimer()
    }

    private func startStream(at stream: NetEaseStream, expectedDuration: TimeInterval, request: UUID, downloadFolder: URL) {
        let item = AVPlayerItem(url: stream.url)
        let player = AVPlayer(playerItem: item)
        streamPlayer = player
        duration = expectedDuration
        streamStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.activeRequest == request, let item = self.streamPlayer?.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    if self.isLoading {
                        self.isLoading = false
                        self.isPlaying = true
                        self.startTimer()
                    }
                case .failed:
                    self.streamStatusObserver = nil
                    self.streamPlayer = nil
                    if let observer = self.streamEndObserver { NotificationCenter.default.removeObserver(observer) }
                    self.streamEndObserver = nil
                    self.timer?.invalidate()
                    self.isPlaying = false
                    self.isLoading = true
                    self.streamRequest = Task {
                        await self.downloadAndPlayStream(at: stream, request: request, streamError: item.error, folder: downloadFolder)
                    }
                default: break
                }
            }
        }
        streamEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeRequest == request else { return }
                self.next()
            }
        }
        player.play()
    }

    private func downloadAndPlayStream(at stream: NetEaseStream, request: UUID, streamError: Error?, folder: URL) async {
        do {
            var address = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)
            if address?.scheme == "http" { address?.scheme = "https" }
            guard let secureURL = address?.url else { throw URLError(.badURL) }

            var download = URLRequest(url: secureURL, timeoutInterval: 25)
            download.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            download.setValue("audio/*, application/octet-stream", forHTTPHeaderField: "Accept")
            let (file, response) = try await URLSession.shared.download(for: download)
            defer { try? FileManager.default.removeItem(at: file) }
            guard !Task.isCancelled, activeRequest == request else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "HTTP", code: code, userInfo: [NSLocalizedDescriptionKey: "音频服务器返回 HTTP \(code)。"])
            }
            let type = response.mimeType?.lowercased() ?? ""
            guard !type.hasPrefix("text/"), !type.contains("json") else {
                throw NSError(domain: "SidePlayer.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频服务器返回了网页或错误消息。"])
            }

            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let signature = try handle.read(upToCount: 4) ?? Data()
            let isFLAC = signature == Data("fLaC".utf8)
            let isMP3 = signature.starts(with: Data("ID3".utf8)) || signature.count >= 2
                && signature[0] == 0xFF && signature[1] & 0xE0 == 0xE0
            guard (stream.format == "flac" && isFLAC) || (stream.format == "mp3" && isMP3) else {
                throw NSError(domain: "SidePlayer.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "网易云返回的音频格式与请求格式不符。"])
            }
            let suffix = stream.format == "flac" ? "flac" : "mp3"
            let local = folder.appendingPathComponent(".side-player-\(UUID().uuidString).\(suffix)")
            do {
                try FileManager.default.moveItem(at: file, to: local)
            } catch {
                try? FileManager.default.removeItem(at: local)
                throw NSError(domain: "SidePlayer.Audio", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "无法在选中的音乐文件夹保存临时音频：\(error.localizedDescription)"
                ])
            }
            downloadedStreamURL = local
            try startAudio(at: local)
        } catch {
            guard !Task.isCancelled, activeRequest == request else { return }
            let failure = error as NSError
            let streamCode = (streamError as NSError?).map { "\($0.domain) \($0.code)" } ?? "未知"
            stop()
            playbackError = "网易云音频加载失败。\n\(failure.localizedDescription)（\(failure.domain) \(failure.code)）\n流式播放错误：\(streamCode)"
        }
    }

    private func startFFmpeg(at source: URL, request: UUID) async {
        isLoading = true
        var convertedURL: URL?
        do {
            let wavURL = try await Task.detached(priority: .userInitiated) { try FFmpegTranscoder.transcodeToWAV(source) }.value
            convertedURL = wavURL
            guard activeRequest == request else {
                try? FileManager.default.removeItem(at: wavURL)
                return
            }
            let file = try AVAudioFile(forReading: wavURL)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            try engine.start()
            ffmpegEngine = engine
            ffmpegPlayer = player
            ffmpegFile = file
            ffmpegTemporaryURL = wavURL
            duration = Double(file.length) / file.processingFormat.sampleRate
            currentTime = 0
            ffmpegSeekBase = 0
            isLoading = false
            scheduleFFmpegAudio(startingAt: 0)
            player.play()
            isPlaying = true
            startTimer()
        } catch {
            guard activeRequest == request else {
                if let convertedURL { try? FileManager.default.removeItem(at: convertedURL) }
                return
            }
            if let convertedURL { try? FileManager.default.removeItem(at: convertedURL) }
            isLoading = false
            playbackError = "FFmpeg 音频解码失败。\n\n\(error.localizedDescription)\n\n\(source.lastPathComponent)"
        }
    }

    private func scheduleFFmpegAudio(startingAt seconds: TimeInterval) {
        guard let player = ffmpegPlayer, let file = ffmpegFile else { return }
        let request = activeRequest
        player.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(min(max(0, seconds * sampleRate), Double(file.length)))
        let remaining = max(0, file.length - startFrame)
        ffmpegSeekBase = Double(startFrame) / sampleRate
        currentTime = ffmpegSeekBase
        guard remaining > 0 else { next(); return }
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil) { [weak self] in
            Task { @MainActor in
                guard let self, self.activeRequest == request, self.ffmpegPlayer != nil else { return }
                self.next()
            }
        }
    }

    private func clearCurrentAudio() {
        lyricsRequest?.cancel()
        lyricsRequest = nil
        lyrics = []
        streamRequest?.cancel()
        streamRequest = nil
        streamStatusObserver = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if let downloadedStreamURL { try? FileManager.default.removeItem(at: downloadedStreamURL) }
        downloadedStreamURL = nil
        streamPlayer?.pause()
        streamPlayer = nil
        ffmpegPlayer?.stop()
        ffmpegEngine?.stop()
        ffmpegPlayer = nil
        ffmpegEngine = nil
        ffmpegFile = nil
        if let streamEndObserver { NotificationCenter.default.removeObserver(streamEndObserver) }
        streamEndObserver = nil
        isPlaying = false
        isLoading = false
        duration = 0
        timer?.invalidate()
        timer = nil
        if let decodedTemporaryURL { try? FileManager.default.removeItem(at: decodedTemporaryURL) }
        decodedTemporaryURL = nil
        if let ffmpegTemporaryURL { try? FileManager.default.removeItem(at: ffmpegTemporaryURL) }
        ffmpegTemporaryURL = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.audioPlayer != nil || self.streamPlayer != nil || self.ffmpegPlayer != nil else { return }
                if let stream = self.streamPlayer {
                    let time = stream.currentTime().seconds
                    if time.isFinite { self.currentTime = time }
                } else if let player = self.ffmpegPlayer, let file = self.ffmpegFile,
                          let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
                    self.currentTime = min(self.duration, self.ffmpegSeekBase + Double(playerTime.sampleTime) / file.processingFormat.sampleRate)
                } else {
                    self.currentTime = self.audioPlayer?.currentTime ?? 0
                }
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        next()
    }
    static func clock(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "00:00" }
        return String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
