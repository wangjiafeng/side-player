import AppKit
import SwiftUI

private enum Palette {
    static let text = Color(hex: "556775")
    static let adjacent = Color(hex: "c9c9ad")
    static let hover = Color(hex: "ceba7b")
    static let played = Color(hex: "273043")
    static let background = Color(hex: "2a3f52")
}

struct SidebarView: View {
    @EnvironmentObject private var model: PlayerModel
    @AppStorage("showArtist") private var showArtist = true
    @AppStorage("showTitle") private var showTitle = true
    @AppStorage("defaultFontSize") private var defaultFontSize = 9.0
    @AppStorage("hoverFontSize") private var hoverFontSize = 12.0
    @AppStorage("sidebarSongCount") private var sidebarSongCount = 8
    @AppStorage("color.文字（默认）") private var defaultTextHex = "556775"
    @AppStorage("color.歌词") private var lyricHex = "c9c9ad"
    @AppStorage("color.上下相邻歌曲") private var adjacentHex = "c9c9ad"
    @AppStorage("color.悬停歌曲") private var hoverHex = "ceba7b"
    @AppStorage("color.长线") private var longLineHex = "556775"
    @AppStorage("color.短线") private var shortLineHex = "556775"
    @AppStorage("color.进度（已播放）") private var playedHex = "273043"
    @AppStorage("color.进度（未播放）") private var unplayedHex = "556775"
    @AppStorage("color.播放时按钮图标与边框") private var playingButtonHex = "556775"
    @AppStorage("color.暂停时按钮图标与边框") private var pausedButtonHex = "556775"
    @AppStorage("sidebarSide") private var sidebarSide = "左侧"
    @State private var pointerY: CGFloat?
    @State private var effects: [UUID: CGFloat] = [:]
    @State private var rowFrames: [UUID: CGRect] = [:]

    private var onRight: Bool { sidebarSide == "右侧" }

    private var nearestID: UUID? {
        guard let pointerY else { return nil }
        return rowFrames.min { abs($0.value.midY - pointerY) < abs($1.value.midY - pointerY) }?.key
    }

    var body: some View {
        VStack(alignment: onRight ? .trailing : .leading, spacing: 27) {
            ScrollView {
                VStack(alignment: onRight ? .trailing : .leading, spacing: 11) {
                    let nearestIndex = model.tracks.firstIndex { $0.id == nearestID }
                    ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                        let emphasis = effects[track.id, default: 0]
                        let rowColor: Color? = model.currentTrack?.id == track.id ? Color(hex: lyricHex) :
                            (nearestIndex == index ? Color(hex: hoverHex) :
                                (nearestIndex.map { abs($0 - index) == 1 } == true ? Color(hex: adjacentHex) : nil))
                        let edge: Alignment = onRight ? .trailing : .leading
                        HStack(spacing: 12) {
                            if onRight { songName(track, emphasis: emphasis, color: rowColor) }
                            ZStack(alignment: onRight ? .topTrailing : .topLeading) {
                                Rectangle().fill(rowColor ?? Color(hex: longLineHex))
                                    .frame(width: 60, height: 1)
                                    .scaleEffect(x: 0.7 + emphasis * 0.5, y: 1, anchor: onRight ? .trailing : .leading)
                                    .offset(y: 10)
                                if index < model.tracks.count - 1 {
                                    Rectangle().fill(rowColor ?? Color(hex: shortLineHex))
                                        .frame(width: 30, height: 1)
                                        .offset(y: 26)
                                }
                            }
                            .frame(width: 60, height: 22, alignment: onRight ? .topTrailing : .topLeading)
                            .animation(.linear(duration: 0.1), value: rowColor)
                            if !onRight { songName(track, emphasis: emphasis, color: rowColor) }
                        }
                        .frame(height: 22)
                        .frame(maxWidth: .infinity, alignment: edge)
                        .contentShape(Rectangle())
                        .onTapGesture { pointerY = nil; model.play(index: index) }
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: SongRowFrames.self, value: [track.id: geometry.frame(in: .named("songList"))])
                            }
                        }
                    }
                    if model.tracks.isEmpty {
                        Text("请在通用设置中选择音乐文件夹或网易云歌单")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: defaultTextHex).opacity(0.75))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: model.tracks.isEmpty ? 22 : CGFloat(min(30, max(1, sidebarSongCount))) * 33 - 11)
            .coordinateSpace(name: "songList")
            .onPreferenceChange(SongRowFrames.self) { rowFrames = $0 }
            .task(id: pointerY != nil || !effects.isEmpty) {
                guard pointerY != nil || !effects.isEmpty else { return }
                let clock = ContinuousClock()
                var last = clock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    let now = clock.now
                    let elapsed = (now - last).components
                    last = now
                    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    let step = 1 - exp(-min(seconds, 0.05) / 0.1)
                    var next: [UUID: CGFloat] = [:]
                    for id in rowFrames.keys {
                        let target = hoverEffect(for: id)
                        let current = effects[id, default: 0]
                        let value = current + (target - current) * step
                        let settled = abs(target - value) <= 0.0015 ? target : value
                        if settled > 0 { next[id] = settled }
                    }
                    if next != effects { effects = next }
                    if pointerY == nil && next.isEmpty { return }
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): pointerY = point.y
                case .ended: pointerY = nil
                }
            }
            VStack(alignment: onRight ? .trailing : .leading, spacing: 12) {
                VStack(alignment: onRight ? .trailing : .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        SegmentedProgress(value: model.duration > 0 ? model.currentTime / model.duration : 0, playedHex: playedHex, unplayedHex: unplayedHex) { fraction in
                            model.seek(to: model.duration * fraction)
                        }
                        Text("\(PlayerModel.clock(model.currentTime)) / \(PlayerModel.clock(model.duration))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(hex: defaultTextHex))
                            .fixedSize()
                    }
                    .overlay(alignment: onRight ? .bottomTrailing : .bottomLeading) {
                        GeometryReader { geometry in
                            Text(model.currentLyric)
                                .font(.system(size: defaultFontSize, weight: .medium))
                                .foregroundStyle(Color(hex: lyricHex))
                                .lineLimit(1)
                                .multilineTextAlignment(onRight ? .trailing : .leading)
                                .frame(width: geometry.size.width, alignment: onRight ? .trailing : .leading)
                                .offset(y: geometry.size.height + 4)
                        }
                        .allowsHitTesting(false)
                    }
                    Color.clear.frame(width: 0, height: ceil(defaultFontSize * 1.4))
                }
                HStack(spacing: 8) {
                    spriteButton(sourceRect: NSRect(x: 0, y: 16, width: 73, height: 40)) { model.previous() }
                    spriteButton(sourceRect: model.isPlaying ? NSRect(x: 105, y: 114, width: 72, height: 72) : NSRect(x: 113, y: 0, width: 63, height: 70)) { model.playPause() }
                    spriteButton(sourceRect: NSRect(x: 208, y: 16, width: 73, height: 40)) { model.next() }
                }
                .frame(height: SegmentedProgress.height, alignment: .center)
                .frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
            }
        }
        .padding(.leading, onRight ? 18 : 12)
        .padding(.trailing, onRight ? 12 : 18)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(width: 300)
        .background(Color.clear)
        .alert("无法播放", isPresented: Binding(get: { model.playbackError != nil }, set: { if !$0 { model.playbackError = nil } })) {
            Button("好", role: .cancel) { model.playbackError = nil }
        } message: {
            Text(model.playbackError ?? "")
        }
    }

    private func hoverEffect(for id: UUID) -> CGFloat {
        guard let pointerY, let frame = rowFrames[id] else { return 0 }
        let linear = max(0, 1 - abs(pointerY - frame.midY) / 100)
        return linear * linear * (3 - 2 * linear)
    }

    private func songName(_ track: Track, emphasis: CGFloat, color: Color?) -> some View {
        Text(displayName(for: track))
            .font(.system(size: defaultFontSize + (hoverFontSize - defaultFontSize) * emphasis, weight: .medium))
            .foregroundStyle(color ?? Color(hex: defaultTextHex))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
            .offset(x: (onRight ? -24 : 24) * emphasis)
            .animation(.linear(duration: 0.1), value: color)
    }

    private func displayName(for track: Track) -> String {
        var parts: [String] = []
        if showArtist { parts.append(cleanDisplayComponent(track.artist, year: nil)) }
        if showTitle { parts.append(cleanDisplayComponent(track.title, year: track.year)) }
        return parts.isEmpty ? cleanDisplayComponent(track.title, year: track.year) : parts.joined(separator: "丨")
    }

    private func cleanDisplayComponent(_ component: String, year: String?) -> String {
        var value = component.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(
            of: #"\.(?:mp3|m4a|aac|alac|wav|aiff|aif|flac|ape|wv|ogg|opus|ncm)$"#,
            with: "",
            options: .caseInsensitive
        )
        let yearPattern = year.map { NSRegularExpression.escapedPattern(for: $0) } ?? #"(?:19|20)\d{2}"#
        value = value.replacingOccurrences(
            of: #"\s*[-–—_.]?[\(\[（]?"# + yearPattern + #"[\)\]）]?\s*$"#,
            with: "",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func spriteButton(sourceRect: NSRect, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SVGSpriteCrop(image: iconSprite, sourceRect: sourceRect, scaleOverride: 9.0 / 72.0)
                .frame(width: sourceRect.width * 9.0 / 72.0, height: SegmentedProgress.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: sourceRect.width * 9.0 / 72.0, height: SegmentedProgress.height)
        .disabled(model.tracks.isEmpty || model.isLoading)
    }

    private var iconSprite: NSImage {
        let resource = Bundle.module.url(forResource: "slide-player", withExtension: "svg", subdirectory: "Resources")!
        let source = (try? String(contentsOf: resource, encoding: .utf8)) ?? ""
        let color = model.isPlaying ? playingButtonHex : pausedButtonHex
        let svg = source.replacingOccurrences(of: "#556775", with: "#\(color.trimmingCharacters(in: CharacterSet(charactersIn: "#")))")
        return NSImage(data: Data(svg.utf8)) ?? NSImage(contentsOf: resource)!
    }
}

private struct SongRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SVGSpriteCrop: View {
    let image: NSImage
    let sourceRect: NSRect
    var scaleOverride: CGFloat? = nil

    var body: some View {
        GeometryReader { proxy in
            let scale = scaleOverride ?? min(proxy.size.width / sourceRect.width, proxy.size.height / sourceRect.height)
            let cropWidth = sourceRect.width * scale
            let cropHeight = sourceRect.height * scale
            Image(nsImage: image)
                .resizable()
                .frame(width: 281.55 * scale, height: 220.89 * scale)
                .offset(x: -sourceRect.minX * scale, y: -sourceRect.minY * scale)
                .frame(width: cropWidth, height: cropHeight, alignment: .topLeading)
                .clipped()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct SegmentedProgress: View {
    static let width: CGFloat = 120
    static let height: CGFloat = 9
    var value: Double
    var playedHex = "273043"
    var unplayedHex = "556775"
    var onSeek: ((Double) -> Void)? = nil
    var body: some View {
        GeometryReader { proxy in
            let count = 20
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule().fill(Double(index) / Double(count) < value ? Color(hex: playedHex) : Color(hex: unplayedHex).opacity(0.9))
                        .frame(width: (proxy.size.width - CGFloat(count - 1) * 2) / CGFloat(count))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard proxy.size.width > 0 else { return }
                onSeek?(min(max(gesture.location.x / proxy.size.width, 0), 1))
            })
        }
        .frame(width: Self.width, height: Self.height)
    }
}

extension Color {
    init(hex: String) {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = Int(normalized, radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}
